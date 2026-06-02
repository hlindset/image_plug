defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access and load options for semantic Plan operations.

  Decode planning reduces a source-fetch-free Plan operation chain to either
  sequential or random image access, and optionally a format-specific load
  shrink/scale option for large downscales.

  The planner is a pure function: it does not read image metadata itself.
  The caller (Request.Processor) reads the header dims and source format and
  passes them in.
  """

  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.NormalizeColorProfile
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.Sharpen

  @type access_requirement() :: :sequential | :random | :neutral
  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @spec open_options(
          [ImagePipe.Plan.Pipeline.operation()],
          source_format(),
          {pos_integer(), pos_integer()},
          boolean()
        ) ::
          keyword()
  def open_options(chain, source_format, {src_w, src_h}, exif_quarter_turn? \\ false)
      when is_list(chain) and is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and
             is_boolean(exif_quarter_turn?) do
    {shrink_w, shrink_h} = shrink_axes({src_w, src_h}, chain, exif_quarter_turn?)
    base = [access: access(chain), fail_on: :error]
    load_shrink = compute_load_shrink(chain, shrink_w, shrink_h)
    append_load_option(base, source_format, load_shrink)
  end

  # The resize target is expressed against the *displayed* axes. When the chain
  # auto-orients a source whose EXIF orientation implies a 90°/270° turn, the
  # displayed axes are the stored axes swapped, so we compute the shrink against
  # the swapped axes to avoid picking a factor for the wrong axis. The swap is
  # gated on an AutoOrient operation actually being present — EXIF metadata alone
  # never rotates pixels in this pipeline; only the AutoOrient step does. When the
  # chain does not auto-orient, the stored axes are what the caller sees, so they
  # are used as-is.
  defp shrink_axes({w, h}, chain, true) do
    if Enum.any?(chain, &match?(%AutoOrient{}, &1)), do: {h, w}, else: {w, h}
  end

  defp shrink_axes(dims, _chain, false), do: dims

  # --- Access selection (unchanged) ---

  defp access([]), do: :random

  defp access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(%PlanResize{mode: mode} = operation) when mode in [:fit, :stretch],
    do: resize_access_requirement(operation)

  defp access_requirement(%PlanResize{mode: mode}) when mode in [:cover, :auto], do: :random
  defp access_requirement(%CropGuided{}), do: :random
  defp access_requirement(%CropRegion{}), do: :random
  defp access_requirement(%Canvas{}), do: :random
  defp access_requirement(%Padding{}), do: :random
  defp access_requirement(%Background{}), do: :random
  defp access_requirement(%AutoOrient{}), do: :sequential
  defp access_requirement(%Rotate{}), do: :random
  defp access_requirement(%Flip{}), do: :random
  defp access_requirement(%Blur{}), do: :random
  defp access_requirement(%Sharpen{}), do: :random
  defp access_requirement(%Pixelate{}), do: :random
  defp access_requirement(%Monochrome{}), do: :random
  defp access_requirement(%Duotone{}), do: :random
  defp access_requirement(%Brightness{}), do: :random
  defp access_requirement(%Contrast{}), do: :random
  defp access_requirement(%Saturation{}), do: :random
  defp access_requirement(%NormalizeColorProfile{}), do: :neutral

  defp resize_access_requirement(%PlanResize{
         width: width,
         height: height,
         min_width: nil,
         min_height: nil
       }) do
    case requested_resize_dimension?(width) or requested_resize_dimension?(height) do
      true -> :sequential
      false -> :random
    end
  end

  defp resize_access_requirement(%PlanResize{}), do: :random

  defp requested_resize_dimension?({:px, value}) when is_integer(value) and value > 0, do: true
  defp requested_resize_dimension?(_dimension), do: false

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end

  # --- Shrink/scale computation ---

  # The load shrink must never decode the image *below* the residual resize's
  # target on either axis — otherwise that resize would upscale a shrunk image and
  # produce a softer result than the full-decode path. We therefore compute the
  # shrink against the residual resize's *effective* target, which `dpr` and `zoom`
  # inflate, and we decline to shrink in the two cases where the safe factor cannot
  # be derived cheaply from the resize alone:
  #
  #   - a crop earlier in the chain (it reduces the pixels feeding the resize, so a
  #     shrink sized against the full source would over-shrink the cropped region);
  #   - `min_width`/`min_height` (they enlarge the result to a floor, interacting
  #     with aspect ratio in ways that are not a simple per-axis multiplier).
  #
  # Declining to shrink is always safe — it forgoes the memory win, never quality.
  defp compute_load_shrink(chain, src_w, src_h) do
    if crop_precedes_resize?(chain) do
      1.0
    else
      first_resize_load_shrink(chain, src_w, src_h)
    end
  end

  defp first_resize_load_shrink(chain, src_w, src_h) do
    case Enum.find(chain, &match?(%PlanResize{}, &1)) do
      nil -> 1.0
      resize -> resize_load_shrink(resize, src_w, src_h)
    end
  end

  # A crop reaching the chain before the first resize. A cover/auto resize that
  # crops *after* resizing is a single `%PlanResize{}` and is not matched here.
  defp crop_precedes_resize?(chain) do
    Enum.reduce_while(chain, false, fn
      %CropGuided{}, _acc -> {:halt, true}
      %CropRegion{}, _acc -> {:halt, true}
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
