defmodule ImagePipe.Output.Clamp do
  @moduledoc false
  # Generic, product-neutral uniform downscale of a realized image so it fits a
  # maximum dimension. Used by the producer with the output encoder's per-format
  # limit (`ImagePipe.Output.Encoder.encoder_limit/1`) so encoding cannot fail.
  # Knows nothing about formats or hosts: it takes a raw `max_dimension`. #165
  # widens this to also accept a `max_pixels` budget.
  #
  # Reads/resizes the image via the `image` library directly (no Transform or
  # Telemetry dependency, per the Output boundary). Resize is lazy; measuring
  # width/height reads libvips header fields (O(1), no pixel realization).

  alias Vix.Vips.Image, as: VixImage

  @type clamp_info :: %{
          scale: float(),
          source_dimensions: {pos_integer(), pos_integer()},
          dimensions: {pos_integer(), pos_integer()},
          max_dimension: pos_integer()
        }

  @spec clamp(VixImage.t(), pos_integer() | :infinity, keyword()) ::
          {:ok, VixImage.t(), clamp_info() | nil}
          | {:error, {:encode, Exception.t(), list()}}
  def clamp(%VixImage{} = image, :infinity, _opts), do: {:ok, image, nil}

  def clamp(%VixImage{} = image, max_dimension, opts) when is_integer(max_dimension) do
    w = Image.width(image)
    h = Image.height(image)
    longest = max(w, h)

    if longest <= max_dimension do
      {:ok, image, nil}
    else
      image_module = Keyword.get(opts, :image_module, Image)
      scale = max_dimension / longest

      with {:ok, resized} <- resize(image_module, image, scale),
           {:ok, resized} <- enforce_limit(image_module, image, resized, max_dimension) do
        rw = Image.width(resized)
        rh = Image.height(resized)

        {:ok, resized,
         %{
           # Derived from the realized result so it stays consistent with
           # `dimensions` even on the defensive corrective path.
           scale: rw / w,
           source_dimensions: {w, h},
           dimensions: {rw, rh},
           max_dimension: max_dimension
         }}
      end
    end
  end

  # Defensive ≤-limit guarantee: `scale = limit/longest` lands the longest axis
  # on `limit`, but if a libvips rounding quirk overshoots we re-resize the
  # ORIGINAL by a slightly smaller (`limit - 0.5`) factor so the corrected
  # longest axis lands at or below the limit. In practice this never fires.
  defp enforce_limit(image_module, original, resized, max_dimension) do
    realized = max(Image.width(resized), Image.height(resized))

    if realized <= max_dimension do
      {:ok, resized}
    else
      longest = max(Image.width(original), Image.height(original))
      # floor-bias: subtract a hair so round() cannot bump back to the overshoot
      corrected = (max_dimension - 0.5) / longest
      resize(image_module, original, corrected)
    end
  end

  defp resize(image_module, image, scale) do
    case image_module.resize(image, scale, vertical_scale: scale) do
      {:ok, resized} -> {:ok, resized}
      {:error, reason} -> {:error, encode_error(reason)}
    end
  end

  defp encode_error(reason) do
    {:encode, RuntimeError.exception("clamp resize failed: #{inspect(reason)}"), []}
  end
end
