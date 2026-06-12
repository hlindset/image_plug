defmodule ImagePipe.Format.Detector do
  @moduledoc false

  @type detected() ::
          :jpeg
          | :png
          | :webp
          | :gif
          | :bmp
          | :ico
          | :svg
          | :tiff
          | :heif
          | :avif
          | :jpeg_xl
          | :jpeg2000
          | :unknown

  # A signature is a list of (byte | :any); :any matches any single byte.
  # First matching signature across the ordered table wins. Signatures are
  # mutually exclusive across formats, so order is for determinism only.
  @ftyp_prefix [:any, :any, :any, :any, ?f, ?t, ?y, ?p]
  @heif_brands [~c"heic", ~c"heix", ~c"hevc", ~c"heim", ~c"heis", ~c"hevm", ~c"hevs", ~c"mif1"]

  @magic [
    {:png, [[0x89, ?P, ?N, ?G, 0x0D, 0x0A, 0x1A, 0x0A]]},
    {:jpeg, [[0xFF, 0xD8]]},
    {:gif, [[?G, ?I, ?F, ?8, :any, ?a]]},
    {:bmp, [[?B, ?M]]},
    {:ico, [[0x00, 0x00, 0x01, 0x00]]},
    {:webp, [[?R, ?I, ?F, ?F, :any, :any, :any, :any, ?W, ?E, ?B, ?P]]},
    {:jpeg_xl,
     [
       [0xFF, 0x0A],
       [0x00, 0x00, 0x00, 0x0C, ?J, ?X, ?L, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
     ]},
    {:jpeg2000,
     [
       [0x00, 0x00, 0x00, 0x0C, ?j, ?P, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A],
       [0xFF, 0x4F, 0xFF, 0x51]
     ]},
    {:avif, [@ftyp_prefix ++ ~c"avif"]},
    {:heif, Enum.map(@heif_brands, &(@ftyp_prefix ++ &1))},
    {:tiff, [[?I, ?I, 0x2A, 0x00], [?M, ?M, 0x00, 0x2A]]}
  ]

  @doc """
  Classify the source image format from a bounded header peek.

  Magic-byte detection first (first match wins); if no signature matches, a
  lightweight SVG structural scan; otherwise `:unknown`. Detection is advisory
  for gating and authoritative-where-confident — never a full decode.
  """
  @spec detect(binary()) :: detected()
  def detect(peek) when is_binary(peek) do
    case match_magic(peek) do
      nil -> if svg?(peek), do: :svg, else: :unknown
      format -> format
    end
  end

  defp match_magic(peek) do
    Enum.find_value(@magic, fn {format, signatures} ->
      if Enum.any?(signatures, &signature_match?(peek, &1)), do: format
    end)
  end

  defp signature_match?(peek, signature) do
    byte_size(peek) >= length(signature) and prefix_match?(peek, signature)
  end

  defp prefix_match?(_peek, []), do: true

  defp prefix_match?(<<byte, rest::binary>>, [expected | tail]) do
    (expected == :any or expected == byte) and prefix_match?(rest, tail)
  end

  # SVG structural scan — added in Task 2.
  defp svg?(_peek), do: false
end
