defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompare do
  @moduledoc """
  Pure pixel-comparison primitives for the imgproxy differential conformance
  harness. Operates on decoded `Vix.Vips.Image` structs. Each band is read once
  to a raw row-major buffer (`write_to_binary/1`) and indexed in the BEAM, so a
  full-frame comparison costs two FFI reads instead of per-pixel FFI calls.
  """

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @spec dims(VipsImage.t()) :: {pos_integer(), pos_integer()}
  def dims(image), do: {Image.width(image), Image.height(image)}

  @doc """
  Largest per-band **spatial** range (`max − min` over the pixels of a band), in
  8-bit-equivalent levels (0.0..255.0). A discrimination signal: a near-zero value
  means the image is spatially flat — a placement/crop error would move the window
  within a uniform field and produce identical pixels, so the fixture cannot detect
  it (e.g. the marker dead-region crops).

  Uses per-band stats deliberately: a spatially uniform `[200,180,60]` fill has a
  *band-byte* range of 140 (the cross-channel gamut) yet zero spatial variation, so
  band-byte range would mis-rate it as discriminating. `vips_stats` row 0 is the
  combined cross-band row (ignored); rows `1..bands` are per band, columns
  `0=min, 1=max`. Normalized by the band format max so 8- and 16-bit fixtures are
  comparable.
  """
  @spec spatial_contrast(VipsImage.t()) :: float()
  def spatial_contrast(image) do
    {:ok, stats} = Operation.stats(image)
    {:ok, bin} = VipsImage.write_to_binary(stats)
    vals = for <<v::native-float-64 <- bin>>, do: v

    max_band_range =
      1..Image.bands(image)
      |> Enum.map(fn band -> Enum.at(vals, band * 10 + 1) - Enum.at(vals, band * 10) end)
      |> Enum.max()

    max_band_range / format_max(image) * 255.0
  end

  defp format_max(image) do
    case VipsImage.format(image) do
      :VIPS_FORMAT_USHORT -> 65_535.0
      :VIPS_FORMAT_SHORT -> 32_767.0
      :VIPS_FORMAT_UINT -> 4_294_967_295.0
      _ -> 255.0
    end
  end

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

  @default_thresholds [2, 16, 32]

  @doc """
  Single-pass triage summary for a live-vs-fixture comparison: dims, band layout,
  the maximum absolute band-byte delta, and a band-byte count over each threshold.

  Returns a map:

      %{
        dims: {dims(a), dims(b)},
        bands: {bands(a), bands(b)},
        comparable: boolean(),
        max_delta: non_neg_integer() | nil,
        over: %{threshold => count}
      }

  `max_delta` is the key skew-vs-structural signal: a diffuse libvips-version
  resampling seam stays low (tens of levels), while a placement/crop shift
  misaligns high-contrast edges toward ~255. When the two images differ in
  dimensions or band layout they cannot be compared band-for-band (a band-count
  divergence is itself a finding — see #220), so `comparable` is `false`,
  `max_delta` is `nil`, and `over` is empty; `dims`/`bands` are still reported.
  """
  @spec diagnose(VipsImage.t(), VipsImage.t(), [non_neg_integer()]) :: map()
  def diagnose(a, b, thresholds \\ @default_thresholds) do
    da = dims(a)
    db = dims(b)
    ba = Image.bands(a)
    bb = Image.bands(b)
    comparable = da == db and ba == bb
    base = %{dims: {da, db}, bands: {ba, bb}, comparable: comparable}

    if comparable do
      {:ok, abin} = VipsImage.write_to_binary(a)
      {:ok, bbin} = VipsImage.write_to_binary(b)
      {max_delta, over} = scan(abin, bbin, thresholds, 0, Map.new(thresholds, &{&1, 0}))
      Map.merge(base, %{max_delta: max_delta, over: over})
    else
      Map.merge(base, %{max_delta: nil, over: %{}})
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

  # One pass over both raw buffers, tracking the max delta and per-threshold counts.
  defp scan(<<>>, <<>>, _thresholds, max_delta, counts), do: {max_delta, counts}

  defp scan(<<av, arest::binary>>, <<bv, brest::binary>>, thresholds, max_delta, counts) do
    delta = abs(av - bv)

    counts =
      Enum.reduce(thresholds, counts, fn t, acc ->
        if delta > t, do: Map.update!(acc, t, &(&1 + 1)), else: acc
      end)

    scan(arest, brest, thresholds, max(max_delta, delta), counts)
  end
end
