defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompare do
  @moduledoc """
  Pure pixel-comparison primitives for the imgproxy differential conformance
  harness. Operates on decoded `Vix.Vips.Image` structs. Each band is read once
  to a raw row-major buffer (`write_to_binary/1`) and indexed in the BEAM, so a
  full-frame comparison costs two FFI reads instead of per-pixel FFI calls.
  """

  alias Vix.Vips.Image, as: VipsImage

  @spec dims(VipsImage.t()) :: {pos_integer(), pos_integer()}
  def dims(image), do: {Image.width(image), Image.height(image)}

  @spec same_dims?(VipsImage.t(), VipsImage.t()) :: boolean()
  def same_dims?(a, b), do: dims(a) == dims(b)

  @doc """
  Count of band-bytes whose absolute delta exceeds `threshold` (band-byte counting
  upper-bounds pixel outliers — the stricter choice). Raises `ArgumentError` if the
  two images differ in dimensions or band layout.
  """
  @spec outliers(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: non_neg_integer()
  def outliers(a, b, threshold) do
    unless same_dims?(a, b) do
      raise ArgumentError, "dimension mismatch: #{inspect(dims(a))} vs #{inspect(dims(b))}"
    end

    {:ok, ab} = VipsImage.write_to_binary(a)
    {:ok, bb} = VipsImage.write_to_binary(b)

    unless byte_size(ab) == byte_size(bb) do
      raise ArgumentError, "band layout mismatch: #{byte_size(ab)} vs #{byte_size(bb)}"
    end

    count_outliers(ab, bb, threshold, 0)
  end

  @doc """
  Mean absolute per-channel delta over the `{left, top, width, height}` region.
  """
  @spec region_mean_delta(
          VipsImage.t(),
          VipsImage.t(),
          {integer(), integer(), pos_integer(), pos_integer()}
        ) :: float()
  def region_mean_delta(a, b, {left, top, width, height}) do
    {:ok, ra} = Image.crop(a, left, top, width, height)
    {:ok, rb} = Image.crop(b, left, top, width, height)
    {:ok, ab} = VipsImage.write_to_binary(ra)
    {:ok, bb} = VipsImage.write_to_binary(rb)
    {sum, n} = sum_abs_delta(ab, bb, 0, 0)
    if n == 0, do: 0.0, else: sum / n
  end

  # Counts band-bytes (not pixels) whose absolute delta exceeds the threshold.
  # Band-byte counting upper-bounds pixel outliers — the stricter choice — and
  # avoids needing the band count here.
  defp count_outliers(<<>>, <<>>, _t, acc), do: acc

  defp count_outliers(<<av, arest::binary>>, <<bv, brest::binary>>, t, acc) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(arest, brest, t, acc)
  end

  defp sum_abs_delta(<<>>, <<>>, sum, n), do: {sum, n}

  defp sum_abs_delta(<<av, arest::binary>>, <<bv, brest::binary>>, sum, n) do
    sum_abs_delta(arest, brest, sum + abs(av - bv), n + 1)
  end
end
