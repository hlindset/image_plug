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
  Fraction (0.0..1.0) of band-bytes whose absolute delta exceeds `threshold` — a
  whole-frame divergence metric. Raises on dimension/band-layout mismatch.
  """
  @spec fraction_over(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: float()
  def fraction_over(a, b, threshold) do
    {:ok, ab} = VipsImage.write_to_binary(a)

    case byte_size(ab) do
      0 -> 0.0
      total -> outliers(a, b, threshold) / total
    end
  end

  # Counts band-bytes (not pixels) whose absolute delta exceeds the threshold.
  # Band-byte counting upper-bounds pixel outliers — the stricter choice — and
  # avoids needing the band count here.
  defp count_outliers(<<>>, <<>>, _t, acc), do: acc

  defp count_outliers(<<av, arest::binary>>, <<bv, brest::binary>>, t, acc) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(arest, brest, t, acc)
  end
end
