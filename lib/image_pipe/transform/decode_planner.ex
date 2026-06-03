defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode load options for semantic Plan operations.

  Decode is always opened with `:sequential` access. Random access is provided
  per-op by `ImagePipe.Transform.Chain` when individual operations require it.

  The planner also computes a format-specific load shrink/scale option for
  large downscales.

  The planner is a pure function: it does not read image metadata itself.
  The caller (Request.Processor) reads the header dims and source format and
  passes them in.
  """

  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate

  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @spec open_options(
          [ImagePipe.Plan.Pipeline.operation()],
          source_format(),
          {pos_integer(), pos_integer()},
          boolean(),
          boolean()
        ) ::
          keyword()
  def open_options(
        chain,
        source_format,
        {src_w, src_h},
        exif_quarter_turn? \\ false,
        auto_rotate? \\ false
      )
      when is_list(chain) and is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and
             is_boolean(exif_quarter_turn?) and is_boolean(auto_rotate?) do
    {shrink_w, shrink_h} = shrink_axes({src_w, src_h}, auto_rotate? and exif_quarter_turn?)
    base = [access: :sequential, fail_on: :error]
    load_shrink = compute_load_shrink(chain, shrink_w, shrink_h)
    append_load_option(base, source_format, load_shrink)
  end

  # The resize target is expressed against the *displayed* axes. When auto_rotate is
  # enabled and the EXIF orientation implies a 90°/270° turn, the displayed axes are
  # the stored axes swapped, so we compute the shrink against the swapped axes to
  # avoid picking a factor for the wrong axis.
  defp shrink_axes({w, h}, true), do: {h, w}
  defp shrink_axes(dims, false), do: dims

  # --- Shrink/scale computation ---

  # The load shrink must never decode the image *below* the residual resize's
  # target on either axis — otherwise that resize would upscale a shrunk image and
  # produce a softer result than the full-decode path. We therefore compute the
  # shrink against the residual resize's *effective* target, which `dpr` and `zoom`
  # inflate.
  #
  # A crop reaching the chain before the resize is allowed through (imgproxy
  # parity, #151): the crop reduces the pixels feeding the resize, so the shrink is
  # sized against the *cropped* extent — `min(crop_dim, src_dim)` per axis, mirroring
  # imgproxy's `widthToScale = MinNonZero(CropWidth, SrcWidth)` (prepare.go:275-278)
  # — never the full source, which would over-shrink the cropped region. The crop's
  # absolute pixel dims and gravity offsets are rescaled by the realized shrink at
  # execution time (PlanExecutor); relative (ratio/percent/focus-point) crops shrink
  # in place and need no coordinate rescale.
  #
  # We still decline to shrink in the cases where it is not provably safe:
  #
  #   - a quarter-turn rotate earlier in the chain (it swaps the axes the residual
  #     resize sizes against; declining keeps the exact stored original dims valid
  #     without per-op bookkeeping — orientation is deferred and flushed after the
  #     resize, so stored dims stay valid until the residual resize runs);
  #   - `min_width`/`min_height` (they enlarge the result to a floor, interacting
  #     with aspect ratio in ways that are not a simple per-axis multiplier).
  #
  # Declining to shrink is always safe — it forgoes the memory win, never quality.
  defp compute_load_shrink(chain, src_w, src_h) do
    if shrink_blocked_before_resize?(chain) do
      1.0
    else
      first_resize_load_shrink(chain, src_w, src_h)
    end
  end

  # The shrink is driven by the first resize sized against the extent that actually
  # feeds it: a preceding crop narrows that extent (per axis) to the cropped size.
  defp first_resize_load_shrink(chain, src_w, src_h) do
    {crop_w, crop_h} = crop_extent_before_resize(chain, src_w, src_h)

    case Enum.find(chain, &match?(%PlanResize{}, &1)) do
      nil -> 1.0
      resize -> resize_load_shrink(resize, crop_w, crop_h)
    end
  end

  # The extent feeding the first resize, per axis: the cropped dimension when a
  # crop precedes the resize, else the full source dimension. Mirrors imgproxy's
  # `widthToScale = MinNonZero(CropWidth, SrcWidth)` (prepare.go:275-276). Absolute
  # pixel crops clamp to the source; relative crops scale the source; `:full_axis`
  # leaves the axis at full source extent.
  defp crop_extent_before_resize(chain, src_w, src_h) do
    Enum.reduce_while(chain, {src_w, src_h}, fn
      %CropGuided{width: cw, height: ch}, _acc ->
        {:halt, {crop_axis_extent(cw, src_w), crop_axis_extent(ch, src_h)}}

      %CropRegion{width: cw, height: ch}, _acc ->
        {:halt, {crop_axis_extent(cw, src_w), crop_axis_extent(ch, src_h)}}

      %PlanResize{}, acc ->
        {:halt, acc}

      _operation, acc ->
        {:cont, acc}
    end)
  end

  defp crop_axis_extent(:full_axis, src), do: src
  defp crop_axis_extent({:px, n}, src) when n > 0, do: min(n, src)

  defp crop_axis_extent({:ratio, num, den}, src) when num > 0 and den > 0,
    do: min(src, max(1, round(src * num / den)))

  # A quarter-turn rotate reaching the chain before the first resize. A crop no
  # longer blocks (#151); a cover/auto resize that crops *after* resizing is a
  # single `%PlanResize{}` and is not matched here; a 180° rotate does not swap
  # axes and does not block.
  defp shrink_blocked_before_resize?(chain) do
    Enum.reduce_while(chain, false, fn
      %Rotate{angle: angle}, _acc when angle in [90, 270] -> {:halt, true}
      %PlanResize{}, _acc -> {:halt, false}
      _operation, acc -> {:cont, acc}
    end)
  end

  defp resize_load_shrink(%PlanResize{min_width: mw, min_height: mh}, _src_w, _src_h)
       when not is_nil(mw) or not is_nil(mh),
       do: 1.0

  defp resize_load_shrink(%PlanResize{width: {:px, w}, height: {:px, h}} = resize, src_w, src_h)
       when w > 0 and h > 0 do
    min(src_w / target_extent(w, resize, :x), src_h / target_extent(h, resize, :y))
  end

  defp resize_load_shrink(%PlanResize{width: {:px, w}} = resize, src_w, _src_h) when w > 0 do
    src_w / target_extent(w, resize, :x)
  end

  defp resize_load_shrink(%PlanResize{height: {:px, h}} = resize, _src_w, src_h) when h > 0 do
    src_h / target_extent(h, resize, :y)
  end

  defp resize_load_shrink(_resize, _src_w, _src_h), do: 1.0

  # The residual resize inflates the requested pixel extent by `dpr` (both axes)
  # and `zoom` (per axis). Using the requested (uninflated-by-clamping) dpr is the
  # safe direction: if the resize later clamps dpr down to fit the source, the real
  # target is smaller, so this only ever under-shrinks.
  defp target_extent(dim, %PlanResize{dpr: {:ratio, n, d}, zoom_x: zoom_x}, :x),
    do: dim * (n / d) * zoom_x

  defp target_extent(dim, %PlanResize{dpr: {:ratio, n, d}, zoom_y: zoom_y}, :y),
    do: dim * (n / d) * zoom_y

  # Append the format-appropriate load option when load_shrink > 1.
  defp append_load_option(base, :jpeg, load_shrink) do
    n = jpeg_shrink_n(load_shrink)
    if n >= 2, do: base ++ [shrink: n], else: base
  end

  defp append_load_option(base, format, load_shrink) when format in [:webp] do
    if load_shrink > 1.0, do: base ++ [scale: 1.0 / load_shrink], else: base
  end

  defp append_load_option(base, _format, _load_shrink), do: base

  # JPEG block-level IDCT shrink factors: largest power-of-2 in {1,2,4,8} ≤ load_shrink.
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 8, do: 8
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 4, do: 4
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 2, do: 2
  defp jpeg_shrink_n(_), do: 1
end
