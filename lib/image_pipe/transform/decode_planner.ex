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
  @type source_format() :: :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @spec open_options([ImagePipe.Plan.Pipeline.operation()], source_format(), {pos_integer(), pos_integer()}) ::
          keyword()
  def open_options(chain, source_format, {src_w, src_h})
      when is_list(chain) and is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 do
    base = [access: access(chain), fail_on: :error]
    load_shrink = compute_load_shrink(chain, src_w, src_h)
    append_load_option(base, source_format, load_shrink)
  end

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

  # Find the first PlanResize in the chain (regardless of mode).
  defp find_first_resize(chain), do: Enum.find(chain, &match?(%PlanResize{}, &1))

  defp compute_load_shrink(chain, src_w, src_h) do
    case find_first_resize(chain) do
      nil -> 1.0
      resize -> resize_load_shrink(resize, src_w, src_h)
    end
  end

  defp resize_load_shrink(%PlanResize{width: {:px, w}, height: {:px, h}}, src_w, src_h)
       when w > 0 and h > 0 do
    min(src_w / w, src_h / h)
  end

  defp resize_load_shrink(%PlanResize{width: {:px, w}}, src_w, _src_h) when w > 0 do
    src_w / w
  end

  defp resize_load_shrink(%PlanResize{height: {:px, h}}, _src_w, src_h) when h > 0 do
    src_h / h
  end

  defp resize_load_shrink(_resize, _src_w, _src_h), do: 1.0

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
