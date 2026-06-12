# Up-front Source Format Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect the source image format from a bounded magic-byte/structural header peek before libvips opens the bytes, gating unsupported formats up front and becoming authoritative for the format where magic is confident.

**Architecture:** A new pure module `ImagePipe.Format.Detector` classifies the format from the first ≤32KB of the source (magic-byte table + a lightweight SVG structural scan). `ImagePipe.Request.Processor.decode_validate_source_response/3` peeks those bytes, detects, **gates** gif/bmp/ico/svg before the libvips open, and resolves `source_format` authoritatively for the six unambiguous formats — delegating the avif-vs-heif codec split and the `:unknown` case to the existing libvips `SourceFormat.from_image/1` (the libvips header is opened anyway for dimensions). libvips stays the validator. The detected format surfaces in telemetry.

**Tech Stack:** Elixir, Vix/libvips (`Vix.Vips.Image`), the `image` library, `Boundary`, ExUnit, StreamData, `:telemetry`.

**Reference spec:** `docs/superpowers/specs/2026-06-12-source-format-detection-design.md`
**Ground truth:** imgproxy `imagetype` package at `/Users/hlindset/src/imgproxy/imagetype/`.

---

## File Structure

- **Create** `lib/image_pipe/format/detector.ex` — pure format classifier: magic table, wildcard matcher, SVG structural scan. One responsibility: bytes → detected format atom.
- **Create** `test/image_pipe/format/detector_test.exs` — detector unit + property tests.
- **Modify** `lib/image_pipe/format.ex` — add `exports: [Detector]` to the `Boundary` declaration.
- **Modify** `lib/image_pipe/request/processor.ex` — peek + detect + gate + resolve in `decode_validate_source_response/3`; new private helpers; telemetry metadata; `decoded()` type.
- **Modify** `lib/image_pipe/request/source_format.ex` — widen the `unsupported_family()` type.
- **Modify** `test/image_pipe/processor_test.exs` — rework the two SVG tests to assert reject-before-open; add gif reject + authoritative-resolution + avif-codec tests.
- **Modify** `lib/image_pipe/telemetry/logger.ex` — render the detected format on the source fetch/decode line.
- **Modify** `test/image_pipe/telemetry/logger_test.exs` — assert the rendered line.
- **Modify** `docs/telemetry.md` — document the new stop-metadata fields.
- **Modify** `docs/imgproxy_support_matrix.md` — input-format-detection preamble + divergences.

**Tooling note:** every `mix` command runs through mise: `mise exec -- mix ...`. If the worktree is fresh, first run `mise trust` and `mise exec -- mix deps.get` (see project memory on fresh-worktree mise trust).

---

## Task 1: Detector — magic-byte table + wildcard matcher

**Files:**
- Create: `lib/image_pipe/format/detector.ex`
- Test: `test/image_pipe/format/detector_test.exs`

- [ ] **Step 1: Write the failing tests for magic detection**

Create `test/image_pipe/format/detector_test.exs`:

```elixir
defmodule ImagePipe.Format.DetectorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Format.Detector

  describe "detect/1 magic bytes" do
    test "PNG signature" do
      assert Detector.detect(<<0x89, "PNG\r\n\x1a\n", "rest...">>) == :png
    end

    test "JPEG SOI" do
      assert Detector.detect(<<0xFF, 0xD8, 0xFF, 0xE0>>) == :jpeg
    end

    test "GIF87a and GIF89a" do
      assert Detector.detect(<<"GIF87a", 1, 0, 1, 0>>) == :gif
      assert Detector.detect(<<"GIF89a", 1, 0, 1, 0>>) == :gif
    end

    test "BMP" do
      assert Detector.detect(<<"BM", 0, 0, 0, 0>>) == :bmp
    end

    test "ICO" do
      assert Detector.detect(<<0x00, 0x00, 0x01, 0x00, 1, 0>>) == :ico
    end

    test "WebP RIFF/WEBP with arbitrary size bytes" do
      assert Detector.detect(<<"RIFF", 0xAA, 0xBB, 0xCC, 0xDD, "WEBP", "VP8 ">>) == :webp
    end

    test "JXL codestream and container" do
      assert Detector.detect(<<0xFF, 0x0A, 0, 0>>) == :jpeg_xl

      assert Detector.detect(<<0x00, 0x00, 0x00, 0x0C, "JXL ", 0x0D, 0x0A, 0x87, 0x0A>>) ==
               :jpeg_xl
    end

    test "JPEG 2000 signature box and J2K codestream" do
      assert Detector.detect(<<0x00, 0x00, 0x00, 0x0C, "jP  ", 0x0D, 0x0A, 0x87, 0x0A>>) ==
               :jpeg2000

      assert Detector.detect(<<0xFF, 0x4F, 0xFF, 0x51, 0, 0>>) == :jpeg2000
    end

    test "AVIF ftyp brand with arbitrary box size" do
      assert Detector.detect(<<0, 0, 0, 0x20, "ftypavif", "more">>) == :avif
    end

    test "every HEIC ftyp brand" do
      for brand <- ["heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1"] do
        assert Detector.detect(<<0, 0, 0, 0x20, "ftyp", brand::binary, "more">>) == :heif
      end
    end

    test "TIFF little-endian and big-endian" do
      assert Detector.detect(<<"II", 0x2A, 0x00, 0, 0>>) == :tiff
      assert Detector.detect(<<"MM", 0x00, 0x2A, 0, 0>>) == :tiff
    end

    test "unrecognized and truncated inputs are :unknown" do
      assert Detector.detect(<<"not an image at all">>) == :unknown
      assert Detector.detect(<<0xFF>>) == :unknown
      assert Detector.detect(<<>>) == :unknown
    end

    test "a truncated ftyp box with no brand is :unknown (matcher is total over short input)" do
      assert Detector.detect(<<0, 0, 0, 0x20, "ftyp">>) == :unknown
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/format/detector_test.exs`
Expected: FAIL — `ImagePipe.Format.Detector.detect/1 is undefined (module ImagePipe.Format.Detector is not available)`.

- [ ] **Step 3: Implement the detector with the magic table (SVG stubbed to :unknown)**

Create `lib/image_pipe/format/detector.ex`:

```elixir
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/format/detector_test.exs`
Expected: PASS (all magic tests green).

- [ ] **Step 5: Verify no warnings**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/format/detector.ex test/image_pipe/format/detector_test.exs
git commit -m "feat(format): magic-byte source format detector (#170)"
```

---

## Task 2: Detector — SVG structural scan

**Files:**
- Modify: `lib/image_pipe/format/detector.ex`
- Test: `test/image_pipe/format/detector_test.exs`

- [ ] **Step 1: Write the failing SVG tests**

Add a new `describe` block to `test/image_pipe/format/detector_test.exs`:

```elixir
  describe "detect/1 SVG structural scan" do
    test "bare svg root" do
      assert Detector.detect(~s(<svg xmlns="http://www.w3.org/2000/svg"></svg>)) == :svg
    end

    test "leading whitespace" do
      assert Detector.detect("\n\t  <svg></svg>") == :svg
    end

    test "UTF-8 BOM" do
      assert Detector.detect(<<0xEF, 0xBB, 0xBF, "<svg></svg>">>) == :svg
    end

    test "XML declaration before root" do
      assert Detector.detect(~s(<?xml version="1.0" encoding="UTF-8"?>\n<svg/>)) == :svg
    end

    test "comment before root" do
      assert Detector.detect("<!-- a comment with > inside -->\n<svg/>") == :svg
    end

    test "DOCTYPE with internal subset containing >" do
      doctype = ~s(<!DOCTYPE svg [ <!ENTITY x "a > b"> ]>)
      assert Detector.detect(doctype <> "<svg/>") == :svg
    end

    test "namespace-prefixed root" do
      assert Detector.detect(~s(<svg:svg xmlns:svg="http://www.w3.org/2000/svg"/>)) == :svg
    end

    test "self-closing root" do
      assert Detector.detect("<svg/>") == :svg
    end

    test "non-svg XML is :unknown" do
      assert Detector.detect(~s(<?xml version="1.0"?><html><body/></html>)) == :unknown
      assert Detector.detect("<rss><channel/></rss>") == :unknown
    end

    test "an element whose name merely starts with svg is not svg" do
      assert Detector.detect("<svgfoo></svgfoo>") == :unknown
    end

    test "plain text is :unknown" do
      assert Detector.detect("hello world, not markup") == :unknown
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/format/detector_test.exs`
Expected: FAIL — the SVG cases return `:unknown` (svg? is stubbed to `false`).

- [ ] **Step 3: Implement the SVG structural scan**

In `lib/image_pipe/format/detector.ex`, replace the stub `defp svg?(_peek), do: false` with:

```elixir
  # --- SVG structural scan ---
  #
  # Bounded, not a full XML parser. Skip a UTF-8 BOM, leading whitespace, and the
  # XML prolog (declarations / comments / DOCTYPE incl. a `[ ... ]` internal
  # subset), then test for an `<svg>` root element (optionally namespace-prefixed).
  # Biases toward catching real SVGs so libvips' svgload never parses attacker
  # XML; punts to a non-match (=> :unknown) on anything ambiguous. A non-match is
  # harmless: it falls through to libvips, which still rejects SVG.

  defp svg?(peek) do
    peek
    |> strip_bom()
    |> skip_prolog()
    |> svg_root?()
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(bin), do: bin

  defp skip_prolog(bin) do
    case skip_ws(bin) do
      <<"<?", rest::binary>> -> rest |> skip_after("?>") |> skip_prolog()
      <<"<!--", rest::binary>> -> rest |> skip_after("-->") |> skip_prolog()
      <<"<!", rest::binary>> -> rest |> skip_doctype() |> skip_prolog()
      other -> other
    end
  end

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\r, ?\n], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  # The suffix after the first occurrence of `terminator`, or "" if it is not
  # present within the peek (treated as "not enough data" => not SVG).
  defp skip_after(bin, terminator) do
    case :binary.split(bin, terminator) do
      [_before, rest] -> rest
      [_whole] -> ""
    end
  end

  # Positioned just after "<!". Skip to the matching top-level ">", stepping over
  # a "[ ... ]" internal subset (which may itself contain ">").
  defp skip_doctype(<<>>), do: ""
  defp skip_doctype(<<?>, rest::binary>>), do: rest
  defp skip_doctype(<<?[, rest::binary>>), do: rest |> skip_after("]") |> skip_doctype()
  defp skip_doctype(<<_c, rest::binary>>), do: skip_doctype(rest)

  defp svg_root?(<<?<, rest::binary>>), do: local_name(read_name(rest)) == "svg"
  defp svg_root?(_bin), do: false

  # Read an element name up to a name terminator (whitespace, ">", "/", or EOF).
  defp read_name(bin), do: read_name(bin, [])

  defp read_name(<<c, _rest::binary>> = bin, acc) when c in [?\s, ?\t, ?\r, ?\n, ?>, ?/],
    do: {finish_name(acc), bin}

  defp read_name(<<c, rest::binary>>, acc), do: read_name(rest, [c | acc])
  defp read_name(<<>>, acc), do: {finish_name(acc), <<>>}

  defp finish_name(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Strip an optional `prefix:` so a namespace-prefixed root resolves to its local
  # name (imgproxy matches on `Name.Local() == "svg"`).
  defp local_name({name, _rest}) do
    case :binary.split(name, ":") do
      [_prefix, local] -> local
      [local] -> local
    end
  end
```

- [ ] **Step 4: Run to verify the SVG tests pass**

Run: `mise exec -- mix test test/image_pipe/format/detector_test.exs`
Expected: PASS (magic + SVG).

- [ ] **Step 5: Verify no warnings**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/format/detector.ex test/image_pipe/format/detector_test.exs
git commit -m "feat(format): SVG structural scan in the detector (#170)"
```

---

## Task 3: Detector — property tests

**Files:**
- Test: `test/image_pipe/format/detector_test.exs`

- [ ] **Step 1: Write the property tests**

Add to `test/image_pipe/format/detector_test.exs` — add `use ExUnitProperties` under the existing `use ExUnit.Case` line, then a new describe block:

```elixir
  describe "detect/1 properties" do
    @confident_prefixes %{
      png: <<0x89, "PNG\r\n\x1a\n">>,
      jpeg: <<0xFF, 0xD8, 0xFF>>,
      gif: <<"GIF89a">>,
      webp: <<"RIFF", 0, 0, 0, 0, "WEBP">>,
      avif: <<0, 0, 0, 0x20, "ftypavif">>,
      jpeg2000: <<0, 0, 0, 0x0C, "jP  ", 0x0D, 0x0A, 0x87, 0x0A>>,
      tiff: <<"II", 0x2A, 0x00>>
    }

    property "a confident prefix is stable under arbitrary appended bytes" do
      prefixes = Map.to_list(@confident_prefixes)

      check all {format, prefix} <- member_of(prefixes),
                suffix <- binary() do
        assert Detector.detect(prefix <> suffix) == format
      end
    end

    property "detection over a 32KB peek equals detection over the full input" do
      prefixes = Map.values(@confident_prefixes)

      check all prefix <- member_of(prefixes),
                tail <- binary(min_length: 0, max_length: 4_096) do
        full = prefix <> tail
        peek = binary_part(full, 0, min(byte_size(full), 32 * 1024))
        assert Detector.detect(peek) == Detector.detect(full)
      end
    end
  end
```

- [ ] **Step 2: Run to verify they pass**

Run: `mise exec -- mix test test/image_pipe/format/detector_test.exs`
Expected: PASS. (If `member_of/1` or `binary/0` are unresolved, confirm `use ExUnitProperties` was added — it imports StreamData generators.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/format/detector_test.exs
git commit -m "test(format): prefix-stability and peek-vs-full properties (#170)"
```

---

## Task 4: Processor — peek, gate, authoritative resolve

**Files:**
- Modify: `lib/image_pipe/format.ex`
- Modify: `lib/image_pipe/request/source_format.ex:8`
- Modify: `lib/image_pipe/request/processor.ex`
- Test: `test/image_pipe/processor_test.exs`

- [ ] **Step 1: Rework the SVG tests and add the new processor tests (failing)**

In `test/image_pipe/processor_test.exs`, **replace** the test `"decode_validate_source_response rejects SVG after decode"` and the test `"unsupported decoded source format is reported before input pixel limits"` with the following four tests (the new SVG tests no longer guard on `svg_supported?/0` — detection is libvips-independent, which is the point):

```elixir
  test "rejects an SVG source before the libvips open" do
    test_pid = self()

    recording_loader = fn binary, vips_opts ->
      send(test_pid, {:buffer_opened, binary})
      VipsImage.new_from_buffer(binary, vips_opts)
    end

    response = %Response{stream: [svg_body(20, 20)]}

    assert {:error, {:unsupported_source_format, :svg}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :buffer_loader, recording_loader)
             )

    refute_received {:buffer_opened, _binary}
  end

  test "rejects a GIF source before the libvips open" do
    test_pid = self()

    recording_loader = fn binary, vips_opts ->
      send(test_pid, {:buffer_opened, binary})
      VipsImage.new_from_buffer(binary, vips_opts)
    end

    response = %Response{stream: [<<"GIF89a", 1, 0, 1, 0>>]}

    assert {:error, {:unsupported_source_format, :gif}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :buffer_loader, recording_loader)
             )

    refute_received {:buffer_opened, _binary}
  end

  test "rejects a path-sourced GIF before the libvips open" do
    path =
      Path.join(System.tmp_dir!(), "detect_#{System.unique_integer([:positive])}.gif")

    File.write!(path, <<"GIF89a", 1, 0, 1, 0>>)
    on_exit(fn -> File.rm(path) end)

    response = %Response{path: path}

    assert {:error, {:unsupported_source_format, :gif}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, RecordingPathOpen)
             )

    refute_received {:opened_input, _path}
  end

  test "a path that cannot be read fails as a decode error before the open" do
    response = %Response{path: "/nonexistent/detector/source.bin"}

    assert {:error, {:decode, {:peek_failed, _reason}}} =
             Processor.decode_validate_source_response(response, plan(), opts())
  end

  test "an unsupported source format is rejected before the input pixel limit" do
    response = %Response{stream: [svg_body(10_000, 10_000)]}

    assert {:error, {:unsupported_source_format, :svg}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :max_input_pixels, 1)
             )
  end

  test "a JPEG source resolves its format authoritatively from magic bytes" do
    response = %Response{stream: [File.read!("priv/static/images/beach.jpg")]}

    assert {:ok, decoded} =
             Processor.decode_validate_source_response(response, plan(), opts())

    assert decoded.source_format == :jpeg
    assert decoded.source_format_resolution == :detected
  end

  test "an AVIF source takes its codec from libvips (resolution :libvips_codec)" do
    if avif_supported?() do
      avif =
        "priv/static/images/beach.jpg"
        |> Image.thumbnail!(16)
        |> Image.write!(:memory, suffix: ".avif")

      response = %Response{stream: [avif]}

      assert {:ok, decoded} =
               Processor.decode_validate_source_response(response, plan(), opts())

      assert decoded.source_format == :avif
      assert decoded.source_format_resolution == :libvips_codec
    end
  end
```

Add this helper next to `svg_supported?/0`:

```elixir
  defp avif_supported? do
    with {:ok, loaders} <- VipsImage.supported_loader_suffixes(),
         {:ok, savers} <- VipsImage.supported_saver_suffixes() do
      ".avif" in loaders and ".avif" in savers
    else
      _other -> false
    end
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: FAIL — the GIF/SVG rejects still hit the loader (no gate yet), and `decoded.source_format_resolution` is undefined.

- [ ] **Step 3: Add the `Format` boundary export**

In `lib/image_pipe/format.ex`, change the `Boundary` declaration:

```elixir
  use Boundary,
    top_level?: true,
    deps: [],
    exports: [Detector]
```

- [ ] **Step 4: Widen the unsupported-family type**

In `lib/image_pipe/request/source_format.ex`, change line 8:

```elixir
  @type unsupported_family() :: :gif | :bmp | :ico | :svg | :unknown
```

- [ ] **Step 5: Wire peek + detect + gate + resolve into the processor**

In `lib/image_pipe/request/processor.ex`:

(a) Add the alias near the top (after `alias ImagePipe.Error`):

```elixir
  alias ImagePipe.Format.Detector
```

(b) Add module attributes after the `@type decoded()` block:

```elixir
  @peek_bytes 32 * 1024
  @reject_families [:gif, :bmp, :ico, :svg]
  @authoritative_formats [:jpeg, :png, :webp, :tiff, :jpeg2000, :jpeg_xl]
```

(c) Extend `@type decoded()` with two fields, `optional(...)` to match the sibling
fields (`original_dims`/`achieved_shrink`/`source_dimensions`) and the `Map.get`
access used in the stop metadata:

```elixir
          optional(:detected_source_format) => Detector.detected(),
          optional(:source_format_resolution) => :detected | :libvips_codec | :libvips_fallback,
```

(d) Replace the body of `decode_validate_source_response/3` (keep the `@spec`) with:

```elixir
  def decode_validate_source_response(%Source.Response{} = source_response, %Plan{} = plan, opts) do
    operations = first_pipeline_operations(plan)

    with {:ok, input} <- seekable_input(source_response),
         {:ok, peek} <- peek_bytes(input) |> wrap_decode_error(),
         detected = Detector.detect(peek),
         :ok <- gate_detected(detected),
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         {:ok, source_format, resolution} <- resolve_source_format(detected, header_image),
         original_dims = {Image.width(header_image), Image.height(header_image)},
         :ok <- validate_original_pixels(original_dims, opts) |> wrap_input_limit_error(),
         decode_options =
           DecodePlanner.open_options(
             operations,
             source_format,
             original_dims,
             exif_quarter_turn?(header_image),
             plan.auto_rotate
           ),
         {:ok, image} <-
           open_seekable_input(input, decode_options, opts)
           |> wrap_decode_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format,
         detected_source_format: detected,
         source_format_resolution: resolution,
         source_dimensions: shrink_source_dimensions(decode_options, original_dims),
         original_dims: original_dims,
         achieved_shrink: compute_achieved_shrink(original_dims, image)
       }}
    end
  end
```

(e) Add the new private helpers (place them next to `seekable_input/1`):

```elixir
  # The bounded header peek that feeds format detection. For a drained buffer this
  # is a zero-copy sub-binary; for a path it reads at most @peek_bytes without
  # consuming or seeking the independent libvips open (so the seekable-decode path
  # is untouched).
  defp peek_bytes({:buffer, binary}) when is_binary(binary),
    do: {:ok, binary_part(binary, 0, min(byte_size(binary), @peek_bytes))}

  defp peek_bytes({:path, path}) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        result = :file.read(device, @peek_bytes)
        File.close(device)

        case result do
          {:ok, data} -> {:ok, data}
          :eof -> {:ok, ""}
          {:error, reason} -> {:error, {:peek_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:peek_failed, reason}}
    end
  end
```

> Disposition note: a peek read failure is returned untagged and routed through
> `wrap_decode_error/1` (the `with` clause above), yielding `{:decode,
> {:peek_failed, reason}}` → 415. This is a deliberate, conscious choice: it
> preserves today's behavior, where an unreadable path reaches `Image.open` and
> already surfaces as a decode error → 415. We do **not** retag it as a source
> error, to avoid changing the observable status for the same input.

```elixir

  # Reject known-unsupported formats before libvips touches the bytes. The error
  # shape matches SourceFormat's, which the response sender already handles.
  defp gate_detected(detected) when detected in @reject_families,
    do: {:error, {:unsupported_source_format, detected}}

  defp gate_detected(_detected), do: :ok

  # Authoritative where magic is confident; libvips supplies the avif-vs-heif codec
  # split and the :unknown fallback (the header is opened anyway, and libvips stays
  # the validator).
  defp resolve_source_format(detected, _header_image) when detected in @authoritative_formats,
    do: {:ok, detected, :detected}

  defp resolve_source_format(detected, header_image) when detected in [:avif, :heif] do
    case SourceFormat.from_image(header_image) do
      {:ok, source_format} -> {:ok, source_format, :libvips_codec}
      {:error, _reason} -> {:ok, detected, :libvips_codec}
    end
  end

  defp resolve_source_format(:unknown, header_image) do
    case SourceFormat.from_image(header_image) do
      {:ok, source_format} -> {:ok, source_format, :libvips_fallback}
      {:error, _reason} = error -> error
    end
  end
```

- [ ] **Step 6: Run the processor tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS (gif/svg rejected before open; jpeg authoritative; avif codec — or no-op if avif unsupported locally).

- [ ] **Step 7: Verify compile + boundaries are clean**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean — in particular no `Boundary` violation for `ImagePipe.Request` referencing `ImagePipe.Format.Detector` (the export added in Step 3).

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/format.ex lib/image_pipe/request/source_format.ex \
        lib/image_pipe/request/processor.ex test/image_pipe/processor_test.exs
git commit -m "feat(request): detect + gate source format before libvips open (#170)"
```

---

## Task 5: Telemetry metadata + default Logger

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (stop metadata)
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Test: `test/image_pipe/telemetry/logger_test.exs`
- Modify: `docs/telemetry.md`

- [ ] **Step 1: Write the failing Logger test**

Add to `test/image_pipe/telemetry/logger_test.exs`:

```elixir
  test "renders the detected source format and resolution on the fetch_decode span" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(3, :millisecond, :native)},
          %{result: :ok, detected_source_format: :jpeg, source_format_resolution: :detected}
        )
      end)

    assert log =~ "source fetch_decode: ok (detected jpeg via detected)"
  end

  test "renders the detected format on an unsupported-format reject" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch_decode, :stop],
          %{duration: System.convert_time_unit(1, :millisecond, :native)},
          %{result: :processing_error, error: :unsupported_source_format, detected_source_format: :svg}
        )
      end)

    assert log =~ "source fetch_decode: processing_error (detected svg)"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: FAIL — the generic clause renders `source fetch_decode: ok` with no detected-format suffix.

- [ ] **Step 3: Add the Logger message clause**

In `lib/image_pipe/telemetry/logger.ex`, add a `message/3` clause **before** the generic `defp message(suffix, _m, meta)` clause (≈ line 221):

```elixir
  defp message([:source, :fetch_decode | _], _m, meta) do
    case meta[:detected_source_format] do
      nil ->
        "image_pipe source fetch_decode: #{outcome(meta)}"

      detected ->
        "image_pipe source fetch_decode: #{outcome(meta)} (detected #{detected}#{resolution_note(meta)})"
    end
  end
```

And add a small helper next to the other message helpers:

```elixir
  defp resolution_note(meta) do
    case meta[:source_format_resolution] do
      nil -> ""
      resolution -> " via #{resolution}"
    end
  end
```

> Level note: we deliberately do **not** escalate `level_for/3` for rejects or `:libvips_fallback`. An unsupported source format is a normal client-error outcome (→ 415), and the fallback is normal operation, not a server degradation — both stay at the base level and are surfaced in the message only.

- [ ] **Step 4: Run to verify the Logger tests pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS.

- [ ] **Step 5: Add the metadata to the processor stop metadata**

In `lib/image_pipe/request/processor.ex`, update `fetch_decode_stop_metadata/1`:

(a) In the success clause map (the `%{result: :ok, ...}`), add the two fields:

```elixir
      loaded_dims: {Image.width(image), Image.height(image)},
      detected_source_format: Map.get(decoded, :detected_source_format),
      source_format_resolution: Map.get(decoded, :source_format_resolution)
```

(b) Add a specific error clause **before** the generic `fetch_decode_stop_metadata({:error, error})` clause:

```elixir
  defp fetch_decode_stop_metadata({:error, {:unsupported_source_format, family} = error}),
    do: %{result: :processing_error, error: Error.tag(error), detected_source_format: family}
```

- [ ] **Step 6: Run the focused processor + logger tests**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/telemetry/logger_test.exs`
Expected: PASS.

- [ ] **Step 7: Update `docs/telemetry.md`**

In the `### Source fetch + decode` section, under "Success stop metadata", add:

```markdown
- `:detected_source_format` — the format the up-front detector returned from the
  header peek (`:jpeg`, `:png`, …, or `:unknown`). Product-neutral, non-sensitive.
- `:source_format_resolution` — how the final `source_format` was decided:
  `:detected` (authoritative magic), `:libvips_codec` (ISOBMFF avif-vs-heif split
  from libvips), or `:libvips_fallback` (detector returned `:unknown`; libvips
  classified).
```

And in the error/outcome notes for `[:source, :fetch_decode]` (near line 356), add:

```markdown
- An unsupported-format reject (gif/bmp/ico/svg, rejected before the libvips open)
  reports `:result` `:processing_error` and carries `:detected_source_format` set
  to the rejected family, so an observer sees why the request was rejected.
```

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/request/processor.ex lib/image_pipe/telemetry/logger.ex \
        test/image_pipe/telemetry/logger_test.exs docs/telemetry.md
git commit -m "feat(telemetry): surface detected source format on fetch_decode (#170)"
```

---

## Task 6: imgproxy support matrix doc

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Add the input-format-detection note**

In `docs/imgproxy_support_matrix.md`, in the **Processing pipeline conformance** section (the stage axis), add a new subsection documenting detection as input-conditioning preamble and the deliberate divergences. Insert after the pipeline diagram / preamble discussion:

```markdown
### Input format detection (source preamble)

Before the per-frame pipeline, ImagePipe detects the source format from a bounded
≤32KB header peek (magic bytes + a lightweight SVG structural scan), mirroring
imgproxy's `imagetype` package. This is input conditioning, not a `Plan`
operation — like decode access mode and shrink-on-load planning, it is sourced
from the bytes, which no operation struct can see. It gates unsupported formats
(gif/bmp/ico/svg) before libvips opens the bytes and is authoritative for the
format where magic is confident.

**Diverges from imgproxy's `imagetype`:**

- **`:unknown` → libvips fallback.** imgproxy hard-rejects `Unknown`; ImagePipe
  falls back to its existing libvips classification, staying as capable as the
  libvips build. Detection is an authoritative-where-confident gate, not a hard
  allowlist.
- **No ct/ext hints → no RAW-vs-TIFF skip.** imgproxy's TIFF detector skips
  itself when the (content-type/extension) hint is in its RAW list — so on its
  real download path, which always passes those hints, a RAW file sharing TIFF
  magic yields `Unknown` (→ reject). ImagePipe does not wire content-type/extension,
  so the same RAW file detects as `:tiff` (its current behavior). Deferred with
  the dimension-sniffing follow-on (#264).
- **SVG: root-only vs match-anywhere.** imgproxy's XML tokenizer classifies SVG
  when an `<svg>` start element appears *anywhere* in the prolog-led token stream;
  ImagePipe's lightweight scan matches only the **root** element. A non-root
  `<svg>` (e.g. wrapped in another root element) that imgproxy would call `svg`
  falls to `:unknown` here → libvips `svgload`, which still rejects it — so no
  wrong-accept, only a label difference on an already-rejected input.
- **JP2 detection added.** ImagePipe detects JPEG 2000 (signature box + J2K
  codestream); imgproxy's `imagetype` has no JP2 detector. Unmatched JP2 variants
  fall to `:unknown` → libvips `jp2kload`.
- **Vocabulary maps to ImagePipe atoms** (`:heif` not `heic`, `:jpeg_xl` not
  `jxl`, `:jpeg2000`); the avif-vs-heif codec split is taken from libvips, which
  is more precise than `ftyp`-brand sniffing for generic-brand AVIF.
```

- [ ] **Step 2: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): document input format detection stage + divergences (#170)"
```

---

## Task 7: Full gate

**Files:** none (verification only)

- [ ] **Step 1: Run the Elixir precommit gate**

Run: `mise run precommit`
(This runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.)
Expected: all green. If `mix format` reports changes, run `mise exec -- mix format`, re-run the gate, and amend the relevant commit.

> If `mix format --check-formatted` fails repo-wide with an unrelated `.credo.exs`
> symlink error, `rm` the dangling untracked `.credo.exs` symlink in the worktree
> (see project memory) and re-run.

- [ ] **Step 2: Commit any formatting fixups**

```bash
git add -A
git commit -m "chore: format + lint fixups (#170)" || true
```

---

## Self-Review (run before handing off to execution)

**Spec coverage** — every spec section maps to a task:

- Detector module + magic table + wildcard matcher → Task 1.
- SVG structural scan (BOM, prolog, DOCTYPE internal subset, prefixed root) → Task 2.
- Confidence properties (prefix-stable, peek-vs-full) → Task 3.
- Placement, peek, gate-before-open, authoritative/codec/fallback resolve, `SourceFormat` kept as `:unknown` fallback, widened error family, `Format` export → Task 4.
- Telemetry surfacing (both fields, reject path, Logger render, no level escalation) + docs/telemetry.md → Task 5.
- imgproxy support-matrix stage note + four divergences → Task 6.
- Precommit gate → Task 7.

**Out of scope (correctly absent):** dimension/EXIF sniffing (#264), ct/ext wiring, streaming early-abort (#263). No new source images / `SourceInventory` changes — reject bodies are synthetic magic-prefixed blobs.

**Documented coverage gap — `:unknown` → `:libvips_fallback` success branch.** The
detector's magic table covers 100% of ImagePipe's *supported* source formats, so
the only way `resolve_source_format(:unknown, …)` can return `{:ok, fmt, :libvips_fallback}`
is an exotic container variant that libvips classifies as supported but our magic
misses (e.g. a JP2/JXL container our two signatures don't cover) — impractical to
fixture without a brittle hand-built file. The `:unknown` **error** sub-path
(libvips also can't classify → `{:error, {:unsupported_source_format, _}}`) preserves
prior behavior and is exercised by the existing unknown-input handling. We
deliberately accept the gap on the rare `:libvips_fallback` *success* branch rather
than commit a fragile fixture; if a real exotic-variant fixture appears later, add
the assertion then. The branch itself is trivial (delegates to the unchanged
`SourceFormat.from_image/1`).

**Type consistency check:**

- `Detector.detect/1 :: binary() -> detected()` used in `decode_validate_source_response/3` and the `decoded()` type — names match (`detected_source_format`, `source_format_resolution`).
- `resolve_source_format/2 :: -> {:ok, source_format, resolution} | {:error, term()}` — matched by the `{:ok, source_format, resolution} <-` clause; `resolution ∈ :detected | :libvips_codec | :libvips_fallback` consistent across the `decoded()` type, the stop metadata, and the Logger.
- `gate_detected/1` and the stop-metadata reject clause both use `{:unsupported_source_format, family}`; `family ∈ @reject_families`; `SourceFormat.unsupported_family()` widened to the same set.
- `@reject_families` and `@authoritative_formats` together with `{:avif, :heif}` and `:unknown` cover every `Detector.detected()` value — no unhandled atom reaches `resolve_source_format/2` (rejects are gated earlier; the six authoritative + avif/heif + unknown is the full remainder).

**Placeholder scan:** no TBD/TODO; every code step shows complete code; every command has an expected result.
