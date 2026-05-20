# Imgproxy Base64 Source URL Implementation Plan

> **For automated workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ImagePlug issue #82 by accepting Imgproxy Base64URL source URLs while keeping decoded source semantics identical to existing plain sources.

**Architecture:** Decode Base64URL source syntax only inside `ImagePlug.Parser.Imgproxy.Path`, then pass the decoded string through the existing Imgproxy source translator. `ImagePlug.Plan`, cache key material, transform modules, request runtime, and source adapters continue to see the same decoded source structs they see for `/plain/` requests.

**Tech Stack:** Elixir, ExUnit, Plug Test, ImagePlug Imgproxy parser, existing ImagePlug cache/source test probes, Markdown docs, Vale.

---

## Reviewed Inputs

- Design doc: `docs/designs/2026-05-20-imgproxy-base64-source-url-design.md`
- GitHub issue: #82, "Support imgproxy base64-encoded source URLs"
- Local upstream references:
  - `/Users/hlindset/src/image_plug/local/imgproxy-docs/usage/processing.mdx`
  - `/Users/hlindset/src/image_plug/local/imgproxy-docs/configuration/options.mdx`
  - `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/url.go`
  - `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/url_options.go`

## Scope Boundaries

Build:

- `/<signature>/<options>/<encoded-source>[.<extension>]`
- chunked encoded source paths that join chunks with `""`
- URL-safe Base64 input with or without padding
- encoded `.webp`, `.avif`, `.jpg`, `.jpeg`, `.png`, `.best` suffix parsing
- decoded path, local, HTTP, HTTPS, S3, and configured custom scheme source translation through existing code
- signature verification before Base64 decoding
- parser and planner failure before source identity resolution, cache lookup, or source fetch

Don't build:

- encrypted `/enc/<encrypted-source>[.<extension>]`
- `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`
- `IMGPROXY_BASE_URL`
- `IMGPROXY_URL_REPLACEMENTS`
- new source kinds in `ImagePlug.Plan`
- cache key schema bumps or encoded source fields
- transform, request runtime, response, or source adapter changes

Deliberate ImagePlug deviations from upstream imgproxy:

- ImagePlug keeps existing no-argument option support for leading `-`, `ar`,
  `auto_rotate`, `fl`, `flip`, bare `preset`, and bare `pr` before encoded
  sources. Upstream imgproxy treats the first segment without the argument
  separator as the source.
- ImagePlug preserves current `plain` marker precedence so option errors before
  `plain` still come from `Options.parse/2`.
- ImagePlug rejects decoded bytes that aren't valid UTF-8. Upstream converts the
  decoded bytes to a Go string; ImagePlug's source parser uses Elixir string and
  URI functions, so invalid UTF-8 is a parser safety failure.

## File Map

- Change `lib/image_plug/parser/imgproxy/path.ex`
  - Add parser-local source kind detection for `:plain` and `:encoded`.
  - Add Base64URL decoding and encoded `.extension` parsing.
  - Keep URI escape validation for plain sources unchanged.
  - Keep encoded source errors free of decoded source URLs.

- Change `lib/image_plug/parser/imgproxy.ex`
  - Thread the source kind from source splitting into source parsing after the
    full parser tests fail.
  - Continue building `%ImagePlug.Parser.Imgproxy.ParsedRequest{source_kind: :plain}`.
  - Keep signature verification before options and source parsing.

- Change `test/parser/imgproxy/path_test.exs`
  - Update existing source-splitting expectations to include `source_kind`.
  - Add focused path parser tests for encoded splitting, decoding, errors, suffixes, `/enc/`, chunking, padding, no-argument options, pipeline separators, and option-error preservation.

- Change `test/parser/imgproxy_test.exs`
  - Add full parser tests for decoded path, HTTP, HTTPS, S3, custom schemes, unsupported schemes, encoded `.extension` precedence, `.best`, trailing `.`, and signed encoded-source parsing.

- Change `test/image_plug/cache/key_test.exs`
  - Add a cache-key equivalence test proving encoded request spelling is absent from key data when source identity and canonical plan fields match.

- Change `test/image_plug/imgproxy_wire_conformance_test.exs`
  - Add real `ImagePlug.call/2` tests for successful encoded requests, cache reuse across plain/encoded/chunked/padded spellings, explicit encoded `.webp`, malformed encoded source safety, and unsupported decoded scheme safety.

- Change `docs/imgproxy_path_api.md`
  - Document encoded source URL shape, `.extension`, signing-before-decoding, Base64URL as reversible path encoding, and excluded preprocessing features.

- Change `docs/imgproxy_support_matrix.md`
  - Mark Base64 encoded source URL as partial support with explicit exclusions.
  - Keep encrypted `/enc/`, filename suffix mode, base URL, and URL replacements missing.

---

## Task 1: Path Parser Tests for Encoded Source Syntax

**Files:**
- Change: `test/parser/imgproxy/path_test.exs`

- [ ] **Step 1: Update existing source-splitting expectations**

Change the existing `Path.split_source/1` assertions to include `:plain`:

```elixir
assert Path.split_source(["w:100", "plain", "images", "cat.jpg"]) ==
         {:ok, ["w:100"], :plain, ["images", "cat.jpg"]}

assert Path.split_source(["plain", "images", "cat.jpg"]) ==
         {:ok, [], :plain, ["images", "cat.jpg"]}

assert Path.split_source(["plain", "plain", "cat.jpg"]) ==
         {:ok, [], :plain, ["plain", "cat.jpg"]}
```

- [ ] **Step 2: Add encoded source helper functions at the bottom of `PathTest`**

Add these helpers before the final `end`:

```elixir
defp encoded_source(source, opts \\ []) do
  padding = Keyword.get(opts, :padding, false)
  Base.url_encode64(source, padding: padding)
end

defp chunked(value, first_size) do
  first = binary_part(value, 0, first_size)
  second = binary_part(value, first_size, byte_size(value) - first_size)
  [first, second]
end
```

- [ ] **Step 3: Add encoded source-splitting tests**

Append this `describe` block after the existing source-splitting block:

```elixir
describe "split_source with encoded sources" do
  test "splits option segments from encoded source segments" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.split_source(["w:100", "h:200", encoded]) ==
             {:ok, ["w:100", "h:200"], :encoded, [encoded]}
  end

  test "splits chunked encoded source segments" do
    encoded = encoded_source("http://example.com/images/cat.jpg")
    [first, second] = chunked(encoded, 12)

    assert Path.split_source(["rs:fit:300:400", first, second]) ==
             {:ok, ["rs:fit:300:400"], :encoded, [first, second]}
  end

  test "uses the first plain marker before encoded-source detection" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.split_source(["w:100", "plain", encoded]) ==
             {:ok, ["w:100"], :plain, [encoded]}
  end

  test "plain marker takes precedence over encoded-source detection" do
    encoded = encoded_source("images/cat.jpg")
    [first, second] = chunked(encoded, 8)

    assert Path.split_source(["w:100", first, "plain", second]) ==
             {:ok, ["w:100", first], :plain, [second]}
  end

  test "keeps no-argument options before encoded sources" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.split_source(["ar", "fl", encoded]) ==
             {:ok, ["ar", "fl"], :encoded, [encoded]}
  end

  test "keeps pipeline separators before encoded sources" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.split_source(["w:100", "-", "h:200", encoded]) ==
             {:ok, ["w:100", "-", "h:200"], :encoded, [encoded]}
  end

  test "keeps bare preset names as options so Options.parse returns the existing error" do
    assert Path.split_source(["preset", encoded_source("images/cat.jpg")]) ==
             {:ok, ["preset"], :encoded, [encoded_source("images/cat.jpg")]}

    assert Path.split_source(["pr", encoded_source("images/cat.jpg")]) ==
             {:ok, ["pr"], :encoded, [encoded_source("images/cat.jpg")]}
  end

  test "rejects encrypted source marker only when first raw source segment is exactly enc" do
    assert Path.split_source(["enc", "payload"]) == {:error, {:unsupported_source_kind, "enc"}}

    assert Path.split_source(["encA"]) == {:ok, [], :encoded, ["encA"]}
  end

  test "preserves existing missing source errors" do
    assert Path.split_source(["w:100", "h:200"]) == {:error, :missing_source_kind}

    assert Path.split_source(["w:100", "plain"]) ==
             {:error, {:missing_source_identifier, "plain"}}
  end
end
```

- [ ] **Step 4: Add source parsing tests for encoded decoding and suffixes**

Append this `describe` block after the existing `describe "parse_plain_source"` block:

```elixir
describe "parse_source with encoded sources" do
  test "decodes unpadded URL-safe Base64 source" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.parse_source(:encoded, [encoded]) ==
             {:ok, "images/cat.jpg", nil}
  end

  test "decodes padded URL-safe Base64 source by trimming trailing padding" do
    encoded = encoded_source("images/cat.jpg", padding: true)

    assert Path.parse_source(:encoded, [encoded]) ==
             {:ok, "images/cat.jpg", nil}
  end

  test "joins encoded chunks without slashes" do
    encoded = encoded_source("http://example.com/images/cat.jpg")
    [first, second] = chunked(encoded, 12)

    assert Path.parse_source(:encoded, [first, second]) ==
             {:ok, "http://example.com/images/cat.jpg", nil}
  end

  test "parses encoded output extension suffixes" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.parse_source(:encoded, [encoded <> ".webp"]) ==
             {:ok, "images/cat.jpg", :webp}

    assert Path.parse_source(:encoded, [encoded <> ".avif"]) ==
             {:ok, "images/cat.jpg", :avif}

    assert Path.parse_source(:encoded, [encoded <> ".jpg"]) ==
             {:ok, "images/cat.jpg", :jpeg}

    assert Path.parse_source(:encoded, [encoded <> ".jpeg"]) ==
             {:ok, "images/cat.jpg", :jpeg}

    assert Path.parse_source(:encoded, [encoded <> ".png"]) ==
             {:ok, "images/cat.jpg", :png}

    assert Path.parse_source(:encoded, [encoded <> ".best"]) ==
             {:ok, "images/cat.jpg", :best}
  end

  test "allows a trailing encoded output separator without an extension" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.parse_source(:encoded, [encoded <> "."]) ==
             {:ok, "images/cat.jpg", nil}
  end

  test "rejects empty encoded source identifiers" do
    assert Path.parse_source(:encoded, [""]) ==
             {:error, {:missing_source_identifier, "encoded"}}

    assert Path.parse_source(:encoded, [".webp"]) ==
             {:error, {:missing_source_identifier, "encoded"}}
  end

  test "rejects invalid encoded source alphabet and length" do
    assert Path.parse_source(:encoded, ["not+base64"]) ==
             {:error, {:invalid_encoded_source, :base64}}

    assert Path.parse_source(:encoded, ["abcde"]) ==
             {:error, {:invalid_encoded_source, :base64}}
  end

  test "treats slash only as an encoded chunk separator" do
    assert Path.parse_source(:encoded, ["a", "+", "b"]) ==
             {:error, {:invalid_encoded_source, :base64}}
  end

  test "rejects decoded bytes that are not UTF-8" do
    encoded = Base.url_encode64(<<255>>, padding: false)

    assert Path.parse_source(:encoded, [encoded]) ==
             {:error, {:invalid_encoded_source, :utf8}}
  end

  test "rejects repeated encoded output extension separators" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.parse_source(:encoded, [encoded <> ".webp.png"]) ==
             {:error, {:multiple_output_extension_separators, encoded <> ".webp.png"}}
  end

  test "rejects unknown encoded output format suffixes" do
    encoded = encoded_source("images/cat.jpg")

    assert Path.parse_source(:encoded, [encoded <> ".gif"]) ==
             {:error, {:invalid_format, "gif", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end
end
```

- [ ] **Step 5: Run path parser tests and confirm they fail for missing API**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/path_test.exs
```

Expected:

- FAIL because `Path.split_source/1` still returns three-tuple results.
- FAIL because `Path.parse_source/2` doesn't exist yet.

Don't change implementation before you observe this failure.

---

## Task 2: Add Parser-Local Encoded Source Detection and Decoding

**Files:**
- Change: `lib/image_plug/parser/imgproxy/path.ex`
- Test: `test/parser/imgproxy/path_test.exs`

- [ ] **Step 1: Update `ImagePlug.Parser.Imgproxy.Path` module imports and source classifiers**

At the top of `lib/image_plug/parser/imgproxy/path.ex`, keep the `Format` module import and add `OptionGrammar`:

```elixir
alias ImagePlug.Parser.Imgproxy.Format
alias ImagePlug.Parser.Imgproxy.OptionGrammar
```

Below the module import lines, add:

```elixir
@no_arg_option_segments ~w(- ar auto_rotate fl flip preset pr)
```

- [ ] **Step 2: Replace `split_source/1` and `parse_plain_source/1` with source-aware functions**

Replace the current `split_source/1` and `parse_plain_source/1` definitions with:

```elixir
def split_source(path_info) do
  case Enum.split_while(path_info, &(&1 != "plain")) do
    {_options, ["plain"]} ->
      {:error, {:missing_source_identifier, "plain"}}

    {options, ["plain" | source_path]} ->
      {:ok, options, :plain, source_path}

    {_options, []} ->
      split_encoded_source(path_info)
  end
end

def parse_source(:plain, source_path), do: parse_plain_source(source_path)
def parse_source(:encoded, source_path), do: parse_encoded_source(source_path)

def parse_plain_source(source_path) do
  encoded = Enum.join(source_path, "/")

  case String.split(encoded, "@") do
    [""] ->
      {:error, {:missing_source_identifier, "plain"}}

    [source] ->
      decode_source_path(source, nil)

    ["", _extension] ->
      {:error, {:missing_source_identifier, "plain"}}

    [source, ""] ->
      decode_source_path(source, nil)

    [source, extension] ->
      case Format.parse(extension) do
        {:ok, format} -> decode_source_path(source, format)
        {:error, _reason} = error -> error
      end

    _parts ->
      {:error, {:multiple_output_extension_separators, encoded}}
  end
end
```

Keep the existing plain-source parser public for the direct tests. New call sites should use source parsing through `Path.parse_source/2`.

- [ ] **Step 3: Add encoded split helpers inside `ImagePlug.Parser.Imgproxy.Path`**

Add these private functions below `parse_plain_source/1`:

```elixir
defp split_encoded_source(path_info) do
  case split_encoded_source(path_info, []) do
    {:ok, _options, []} ->
      {:error, :missing_source_kind}

    {:ok, _options, ["enc" | _source_segments]} ->
      {:error, {:unsupported_source_kind, "enc"}}

    {:ok, options, source_segments} ->
      {:ok, options, :encoded, source_segments}

    {:error, _reason} = error ->
      error
  end
end

defp split_encoded_source([], options), do: {:ok, Enum.reverse(options), []}

defp split_encoded_source([segment | segments], options) do
  case classify_pre_source_segment(segment) do
    :option ->
      split_encoded_source(segments, [segment | options])

    :source_start ->
      {:ok, Enum.reverse(options), [segment | segments]}

    {:error, _reason} = error ->
      error
  end
end

defp classify_pre_source_segment(segment) when segment in @no_arg_option_segments,
  do: :option

defp classify_pre_source_segment(segment) do
  cond do
    String.contains?(segment, ":") ->
      :option

    option_name?(segment) ->
      :option

    true ->
      :source_start
  end
end

defp option_name?(segment) do
  case OptionGrammar.parse(segment) do
    {:ok, _parsed} -> true
    {:error, {:invalid_option_segment, ^segment}} -> true
    {:error, _reason} -> false
  end
end
```

This uses `OptionGrammar.parse/1` only for classification. The real option result still comes from `Options.parse/2` after splitting, so existing option errors remain owned by `Options`.

- [ ] **Step 4: Add encoded parse helpers inside `ImagePlug.Parser.Imgproxy.Path`**

Add these private functions below the split helpers:

```elixir
defp parse_encoded_source(source_path) do
  encoded = Enum.join(source_path, "")

  case String.split(encoded, ".") do
    [""] ->
      {:error, {:missing_source_identifier, "encoded"}}

    [source] ->
      decode_encoded_source(source, nil)

    ["", _extension] ->
      {:error, {:missing_source_identifier, "encoded"}}

    [source, ""] ->
      decode_encoded_source(source, nil)

    [source, extension] ->
      case Format.parse(extension) do
        {:ok, format} -> decode_encoded_source(source, format)
        {:error, _reason} = error -> error
      end

    _parts ->
      {:error, {:multiple_output_extension_separators, encoded}}
  end
end

defp decode_encoded_source(source, source_format) do
  source
  |> String.trim_trailing("=")
  |> Base.url_decode64(padding: false)
  |> case do
    {:ok, decoded} -> validate_decoded_source(decoded, source_format)
    :error -> {:error, {:invalid_encoded_source, :base64}}
  end
end

defp validate_decoded_source(decoded, source_format) do
  case String.valid?(decoded) do
    true -> {:ok, decoded, source_format}
    false -> {:error, {:invalid_encoded_source, :utf8}}
  end
end
```

- [ ] **Step 5: Run path parser tests and confirm they pass**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/path_test.exs
```

Expected: PASS.

- [ ] **Step 6: Run the existing full Imgproxy parser tests and confirm the integration failure**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs
```

Expected: FAIL because `ImagePlug.Parser.Imgproxy.parse_request/2` still expects the old three-element `Path.split_source/1` success tuple. This confirms the next task owns full parser integration.

- [ ] **Step 7: Commit parser path implementation**

Run:

```bash
mise exec -- git add lib/image_plug/parser/imgproxy/path.ex test/parser/imgproxy/path_test.exs
mise exec -- git commit -m "feat: parse imgproxy base64 source paths"
```

---

## Task 3: Full Imgproxy Parser Tests for Decoded Source Translation

**Files:**
- Change: `lib/image_plug/parser/imgproxy.ex`
- Change: `test/parser/imgproxy_test.exs`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Add parser test helpers**

Add these helpers near the existing helper functions at the bottom of `test/parser/imgproxy_test.exs`:

```elixir
defp encoded_source(source, opts \\ []) do
  padding = Keyword.get(opts, :padding, false)
  Base.url_encode64(source, padding: padding)
end

defp signed_request_path(signed_path) do
  key = Base.decode16!("746573742d6b6579", case: :lower)
  salt = Base.decode16!("746573742d73616c74", case: :lower)

  signature =
    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> Base.url_encode64(padding: false)

  "/" <> signature <> signed_path
end
```

- [ ] **Step 2: Add full parser tests for decoded source types**

Add this block near the existing plain source tests:

```elixir
describe "Base64 encoded source URLs" do
  test "decoded path source becomes a path plan source" do
    encoded = encoded_source("images/cat.jpg")

    assert {:ok, %Plan{source: %Source.Path{segments: ["images", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/_/#{encoded}"), [])
  end

  test "decoded HTTP URL with query becomes a URL plan source" do
    encoded = encoded_source("http://example.com/images/cat.jpg?size=large")

    assert {:ok, %Plan{source: source}} = Imgproxy.parse(conn(:get, "/_/#{encoded}"), [])

    assert source == %Source.URL{
             scheme: :http,
             host: "example.com",
             port: 80,
             path: ["images", "cat.jpg"],
             query: "size=large"
           }
  end

  test "decoded HTTPS URL becomes a URL plan source" do
    encoded = encoded_source("https://example.com/images/cat.jpg")

    assert {:ok, %Plan{source: source}} = Imgproxy.parse(conn(:get, "/_/#{encoded}"), [])

    assert source == %Source.URL{
             scheme: :https,
             host: "example.com",
             port: 443,
             path: ["images", "cat.jpg"],
             query: nil
           }
  end

  test "decoded S3 URL with query revision becomes an object plan source" do
    encoded = encoded_source("s3://bucket/images/cat.jpg?rev1")

    assert {:ok, %Plan{source: source}} = Imgproxy.parse(conn(:get, "/_/#{encoded}"), [])

    assert source == %Source.Object{
             adapter: :s3,
             scope: "bucket",
             key: "images/cat.jpg",
             revision: "rev1"
           }
  end

  test "decoded custom scheme reaches the configured source scheme translator" do
    encoded = encoded_source("foobar://asset/cat.jpg")

    assert {:ok, %Plan{source: source}} =
             Imgproxy.parse(conn(:get, "/_/#{encoded}"),
               imgproxy: [source_schemes: %{"foobar" => {FoobarTranslator, []}}]
             )

    assert source == %Source.Object{
             adapter: :foobar,
             scope: "scope",
             key: "foobar://asset/cat.jpg",
             revision: "r1"
           }

    assert_received {:translate, "foobar://asset/cat.jpg", []}
  end

  test "unsupported decoded source schemes return source scheme error before runtime" do
    encoded = encoded_source("ftp://example.com/cat.jpg")

    assert Imgproxy.parse(conn(:get, "/_/#{encoded}"), []) ==
             {:error, {:unsupported_source_scheme, "ftp"}}
  end
end
```

- [ ] **Step 3: Add full parser test for option-error preservation**

Add this test inside the same `describe "Base64 encoded source URLs"` block:

```elixir
test "plain marker keeps option parser errors before source parsing" do
  assert Imgproxy.parse(conn(:get, "/_/raw/plain/images/cat.jpg"), []) ==
           {:error, {:unknown_option, "raw"}}

  assert Imgproxy.parse(conn(:get, "/_/unknown/plain/images/cat.jpg"), []) ==
           {:error, {:unknown_option, "unknown"}}

  assert Imgproxy.parse(conn(:get, "/_/w:nope/plain/images/cat.jpg"), []) ==
           {:error, {:invalid_non_negative_integer, "nope"}}
end
```

- [ ] **Step 4: Add full parser tests for encoded output suffix behavior**

Add these tests inside the same `describe "Base64 encoded source URLs"` block:

```elixir
test "encoded output suffix overrides format option" do
  encoded = encoded_source("images/cat.jpg")

  assert_output_mode("/_/f:jpeg/#{encoded}.webp", {:explicit, :webp})
end

test "encoded trailing output separator leaves output format automatic" do
  encoded = encoded_source("images/cat.jpg")

  assert_output_mode("/_/#{encoded}.", :automatic)
end

test "encoded best suffix reaches the same planner behavior as plain best suffix" do
  encoded = encoded_source("images/cat.jpg")

  assert Imgproxy.parse(conn(:get, "/_/#{encoded}.best"), []) ==
           {:error, {:unsupported_output_format, :best}}
end
```

- [ ] **Step 5: Add signed encoded-source parser test**

Add this test inside the same `describe "Base64 encoded source URLs"` block:

```elixir
test "signed encoded-source request verifies before decoding and parses correctly" do
  encoded = encoded_source("images/cat.jpg")
  signed_path = "/w:300/#{encoded}.webp"

  assert {:ok, %Plan{source: %Source.Path{segments: ["images", "cat.jpg"]}, output: output}} =
           Imgproxy.parse(conn(:get, signed_request_path(signed_path)), signed_parser_opts())

  assert output.mode == {:explicit, :webp}
end

test "invalid signature fails before malformed encoded source is decoded" do
  assert Imgproxy.parse(conn(:get, "/unsafe/not+base64"), signed_parser_opts()) ==
           {:error, :invalid_signature}
end
```

- [ ] **Step 6: Run full parser tests and confirm they fail before integration**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs
```

Expected: FAIL because `ImagePlug.Parser.Imgproxy.parse_request/2` still expects the old `Path.split_source/1` return shape and still calls `Path.parse_plain_source/1` directly.

- [ ] **Step 7: Update `ImagePlug.Parser.Imgproxy.parse_request/2`**

In `lib/image_plug/parser/imgproxy.ex`, change the parser flow from:

```elixir
{:ok, option_segments, raw_source_path} <- Path.split_source(path_info),
{:ok, request_options} <- Options.parse(option_segments, preset_config(opts)),
{:ok, source_path, source_format} <- Path.parse_plain_source(raw_source_path) do
```

to:

```elixir
{:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
{:ok, request_options} <- Options.parse(option_segments, preset_config(opts)),
{:ok, source_path, source_format} <- Path.parse_source(source_kind, raw_source_path) do
```

Keep `parsed_request/4` unchanged so it sets `source_kind: :plain`.

- [ ] **Step 8: Run full parser tests and confirm they pass**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs
```

Expected: PASS.

- [ ] **Step 9: Commit full parser integration tests and implementation**

Run:

```bash
mise exec -- git add lib/image_plug/parser/imgproxy.ex test/parser/imgproxy_test.exs
mise exec -- git commit -m "feat: translate imgproxy encoded sources"
```

---

## Task 4: Cache-Key Equivalence Test

**Files:**
- Change: `test/image_plug/cache/key_test.exs`
- Test: `test/image_plug/cache/key_test.exs`

- [ ] **Step 1: Add encoded source helper**

Add this helper near the existing helper functions in `test/image_plug/cache/key_test.exs`:

```elixir
defp encoded_source(source) do
  Base.url_encode64(source, padding: false)
end
```

- [ ] **Step 2: Add cache-key equivalence test**

Add this test near the existing request URL and source identity cache-key tests:

```elixir
test "imgproxy encoded source spelling does not enter cache key data" do
  encoded = encoded_source("images/cat.jpg")

  plain_conn = conn(:get, "/sig-one/plain/images/cat.jpg")
  encoded_conn = conn(:get, "/sig-two/#{encoded}")

  assert {:ok, plain_plan} = Imgproxy.parse(plain_conn, [])
  assert {:ok, encoded_plan} = Imgproxy.parse(encoded_conn, [])

  identity = [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

  plain_key = build_key!(plain_conn, plain_plan, identity)
  encoded_key = build_key!(encoded_conn, encoded_plan, identity)

  assert plain_plan == encoded_plan
  assert plain_key.hash == encoded_key.hash
  assert plain_key.data == encoded_key.data
  refute inspect(encoded_key.data) =~ encoded
end
```

- [ ] **Step 3: Run the cache key test file**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs
```

Expected: PASS.

- [ ] **Step 4: Commit cache-key coverage**

Run:

```bash
mise exec -- git add test/image_plug/cache/key_test.exs
mise exec -- git commit -m "test: prove encoded sources share cache key data"
```

---

## Task 5: Wire Conformance Tests for Runtime Behavior and Safety

**Files:**
- Change: `test/image_plug/imgproxy_wire_conformance_test.exs`
- Test: `test/image_plug/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add encoded source helpers**

Add these helpers near the existing helper functions in `test/image_plug/imgproxy_wire_conformance_test.exs`:

```elixir
defp encoded_source(source, opts \\ []) do
  padding = Keyword.get(opts, :padding, false)
  Base.url_encode64(source, padding: padding)
end

defp chunked_encoded_source(source) do
  encoded = encoded_source(source)
  first_size = div(byte_size(encoded), 2)
  first = binary_part(encoded, 0, first_size)
  second = binary_part(encoded, first_size, byte_size(encoded) - first_size)
  first <> "/" <> second
end

def handle_telemetry_event(event, measurements, metadata, test_pid) do
  send(test_pid, {:telemetry_event, event, measurements, metadata})
end

defp attach_source_resolve_telemetry do
  handler_id = {__MODULE__, self(), :source_resolve}

  :telemetry.attach_many(
    handler_id,
    [
      [:image_plug, :source, :resolve, :start],
      [:image_plug, :source, :resolve, :stop],
      [:image_plug, :source, :resolve, :exception]
    ],
    &__MODULE__.handle_telemetry_event/4,
    self()
  )

  on_exit(fn -> :telemetry.detach(handler_id) end)
end
```

- [ ] **Step 2: Add successful encoded path request test**

Add this test near the existing representative wire tests:

```elixir
test "encoded path source succeeds through a real Plug request" do
  encoded = encoded_source("images/beach.jpg")

  conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}", @default_opts)

  assert conn.status == 200
  assert content_type(conn) == ["image/jpeg"]
  assert dimensions(conn) == {120, 90}
  assert byte_size(conn.resp_body) > 0
end
```

- [ ] **Step 3: Add cache reuse tests for matching spellings**

Add these tests near the existing filesystem cache tests:

```elixir
test "plain and matching encoded source requests share the same filesystem cache entry" do
  {opts, cache_root} = cached_opts()

  try do
    plain_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

    assert plain_conn.status == 200
    assert_received :origin_fetch

    encoded = encoded_source("images/beach.jpg")
    encoded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}", opts)

    assert encoded_conn.status == 200
    assert encoded_conn.resp_body == plain_conn.resp_body
    refute_received :origin_fetch
  after
    File.rm_rf!(cache_root)
  end
end

test "whole chunked and padded encoded source spellings share the same filesystem cache entry" do
  {opts, cache_root} = cached_opts()

  try do
    whole = encoded_source("images/beach.jpg")
    chunked = chunked_encoded_source("images/beach.jpg")
    padded = encoded_source("images/beach.jpg", padding: true)

    first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{whole}", opts)

    assert first_conn.status == 200
    assert_received :origin_fetch

    chunked_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{chunked}", opts)

    assert chunked_conn.status == 200
    assert chunked_conn.resp_body == first_conn.resp_body
    refute_received :origin_fetch

    padded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{padded}", opts)

    assert padded_conn.status == 200
    assert padded_conn.resp_body == first_conn.resp_body
    refute_received :origin_fetch
  after
    File.rm_rf!(cache_root)
  end
end
```

- [ ] **Step 4: Add explicit encoded `.webp` wire behavior test**

Add this test near the existing output negotiation tests:

```elixir
test "encoded output suffix bypasses Accept negotiation and does not set Vary" do
  encoded = encoded_source("images/beach.jpg")

  conn = call_imgproxy("/_/f:jpeg/#{encoded}.webp", @default_opts, "image/avif,image/webp")

  assert conn.status == 200
  assert content_type(conn) == ["image/webp"]
  assert get_resp_header(conn, "vary") == []
  assert byte_size(conn.resp_body) > 0
end
```

- [ ] **Step 5: Add malformed encoded source safety test**

Add this test near the existing "invalid signatures, paths, options, and expiry stop before cache and origin access" test:

```elixir
test "malformed encoded source stops before cache lookup and origin fetch" do
  attach_source_resolve_telemetry()

  opts =
    Keyword.merge(@default_opts,
      cache: {CacheProbe, []},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      ]
    )

  for path <- ["/_/not+base64", "/_/#{Base.url_encode64(<<255>>, padding: false)}"] do
    conn = call_imgproxy(path, opts)

    assert conn.status == 400
    refute_received {:telemetry_event, [:image_plug, :source, :resolve, :start], _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end
end
```

- [ ] **Step 6: Add unsupported decoded scheme safety test**

Add this test near the malformed encoded source safety test:

```elixir
test "unsupported decoded source scheme stops before cache lookup and origin fetch" do
  attach_source_resolve_telemetry()

  encoded = encoded_source("ftp://example.com/cat.jpg")

  opts =
    Keyword.merge(@default_opts,
      cache: {CacheProbe, []},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      ]
    )

  conn = call_imgproxy("/_/#{encoded}", opts)

  assert conn.status == 400
  refute_received {:telemetry_event, [:image_plug, :source, :resolve, :start], _, _}
  refute_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry}
  refute_received :origin_fetch
end
```

- [ ] **Step 7: Run wire conformance tests**

Run:

```bash
mise exec -- mix test test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit wire conformance coverage**

Run:

```bash
mise exec -- git add test/image_plug/imgproxy_wire_conformance_test.exs
mise exec -- git commit -m "test: cover encoded source wire behavior"
```

---

## Task 6: Documentation Updates

**Files:**
- Change: `docs/imgproxy_path_api.md`
- Change: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update `docs/imgproxy_path_api.md` path shape**

Replace the current path shape block:

```markdown
    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]
```

with:

```markdown
    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]
    /<signature>/option[:arg...]/option[:arg...]/<base64-url>[.<extension>]
```

- [ ] **Step 2: Add encoded source behavior text after the `plain` paragraph**

Add this text after the paragraph that begins with "`plain` starts the source path":

```markdown
Without `plain`, ImagePlug treats the remaining path segments as an Imgproxy
Base64URL source value. It joins those segments without `/`, trims trailing
`=`, decodes URL-safe Base64, and passes the decoded string through the same
source translation used by plain sources. A decoded `images/cat.jpg`,
`local:///images/cat.jpg`, `https://example.com/cat.jpg`, `s3://bucket/key`, or
configured custom scheme produces the same `ImagePlug.Plan` source as the
matching plain request.

Encoded sources use `.extension`, not `@extension`, for explicit output format
selection:

    /_/aW1hZ2VzL2NhdC5qcGc.webp

Base64URL is only path encoding. It is reversible; treat it as routing syntax,
not a secrecy boundary. The received request path can still appear in request
logs wherever the host application logs paths.
```

- [ ] **Step 3: Add signing and unsupported preprocessing notes**

Add this text in the same path shape section, after the Base64URL paragraph:

```markdown
Signature verification uses the received fixed path before Base64 decoding. For
signed URLs, sign the encoded path and suffix exactly as sent after Imgproxy
`fixPath` normalization.

ImagePlug doesn't support encrypted `/enc/<encrypted-source>[.<extension>]`
source URLs. It also doesn't build Imgproxy source preprocessing controlled
by `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`, `IMGPROXY_BASE_URL`, or
`IMGPROXY_URL_REPLACEMENTS`. Requests for encrypted sources, malformed
Base64URL values, and unsupported decoded source schemes fail before source
identity resolution, cache lookup, or source fetch.
```

- [ ] **Step 4: Update `docs/imgproxy_support_matrix.md` support entries**

In the source URL support table, replace the row:

```markdown
| Base64 encoded source URL | Missing | No encoded source parsing. ImagePlug supports plain HTTP and HTTPS source URLs through `/plain/`. |
```

with:

```markdown
| Base64 encoded source URL | Partial | ImagePlug supports Imgproxy encoded source syntax and `.extension` output suffixes. It doesn't support filename suffix mode, base URL prefixing, or URL replacements. |
```

Keep these rows as Missing if present:

```markdown
| Encrypted source URL via `/enc/` | Missing | Not implemented. |
| `IMGPROXY_BASE64_URL_INCLUDES_FILENAME` | Missing | Not implemented. |
| `IMGPROXY_BASE_URL` | Missing | Not implemented. |
| `IMGPROXY_URL_REPLACEMENTS` | Missing | Not implemented. |
```

If the current table wording differs, preserve the existing row style but keep the same support statuses and exclusions.

In the `URL rewriting and encoded-source filename behavior` section, update the
status bullets so the section says:

```markdown
- ⚠️ Base64 encoded source URLs
- ⭕ `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`
- ⭕ `IMGPROXY_BASE_URL`
- ⭕ `IMGPROXY_URL_REPLACEMENTS`
```

Add a short note under that list:

```markdown
ImagePlug supports encoded source syntax and encoded `.extension` output
suffixes. It doesn't support filename suffix mode, base URL prefixing, or URL
replacements.
```

Keep encrypted `/enc/` source URL documented as missing wherever the support
matrix represents encrypted sources.

- [ ] **Step 5: Update output suffix notes**

Where `docs/imgproxy_support_matrix.md` or `docs/imgproxy_path_api.md` describes `@extension`, add that plain sources use `@extension` and encoded sources use `.extension`.

- [ ] **Step 6: Run Vale for changed docs**

Run:

```bash
mise exec -- vale docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
```

Expected: PASS.

- [ ] **Step 7: Commit docs**

Run:

```bash
mise exec -- git add docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "docs: document imgproxy encoded source URLs"
```

---

## Task 7: Focused Regression and Boundary Verification

**Files:**
- No file changes expected.
- Verify: parser tests, cache-key tests, wire tests, docs, formatting, compile, lint.

- [ ] **Step 1: Run the focused parser and wire tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/path_test.exs test/parser/imgproxy_test.exs test/image_plug/cache/key_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 3: Run formatting check**

Run:

```bash
mise exec -- mix format --check-formatted
```

Expected: PASS.

- [ ] **Step 4: Run warnings-as-errors compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [ ] **Step 5: Run Credo**

Run:

```bash
mise exec -- mix credo --strict
```

Expected: PASS.

- [ ] **Step 6: Run Vale for all changed docs**

Run:

```bash
mise exec -- vale docs/designs/2026-05-20-imgproxy-base64-source-url-design.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
```

Expected: PASS.

- [ ] **Step 7: Run focused architecture boundary tests**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

- [ ] **Step 8: Inspect boundaries manually before final commit**

Run:

```bash
mise exec -- rg -n "encoded_source|Base64|base64|parse_source|invalid_encoded_source|unsupported_source_kind" lib test docs
```

Expected:

- Encoded source implementation references appear only under `lib/image_plug/parser/imgproxy/`.
- Tests and docs contain the expected coverage.
- No encoded source fields appear in `ImagePlug.Plan`, cache key implementation, transform modules, request runtime, response modules, or source adapters.

- [ ] **Step 9: Commit any verification fixes**

If verification required fixes, commit only the changed implementation, test, or docs files:

```bash
mise exec -- git add lib/image_plug/parser/imgproxy/path.ex lib/image_plug/parser/imgproxy.ex test/parser/imgproxy/path_test.exs test/parser/imgproxy_test.exs test/image_plug/cache/key_test.exs test/image_plug/imgproxy_wire_conformance_test.exs docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "fix: align encoded source support with review"
```

If no files changed after verification, don't create an empty commit.

---

## Acceptance Criteria

- Encoded source syntax lives only in `ImagePlug.Parser.Imgproxy`.
- `%ImagePlug.Plan{}` and source structs match the same `/plain/` requests.
- Cache keys use decoded source identity and canonical plan fields, not encoded request spelling.
- Malformed Base64URL and unsupported decoded schemes return `400` before source identity resolution, cache lookup, or source fetch.
- Signature verification runs on the fixed signed path before Base64 decoding.
- Encoded `.extension` explicit output behavior matches plain `@extension` precedence.
- `Options.parse/2` still returns existing option errors for `/raw/plain/...`, `/unknown/plain/...`, `/w:nope/plain/...`, bare `preset`, and bare `pr`.
- `/enc/`, filename suffix mode, base URL prefixing, and URL replacements remain unsupported and documented out of scope.
- Focused tests, full tests, compile, Credo, format check, and Vale pass.

## Final Verification Commands

Run these before marking issue #82 implemented:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix test test/parser/imgproxy/path_test.exs test/parser/imgproxy_test.exs test/image_plug/cache/key_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
mise exec -- mix test
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo --strict
mise exec -- vale docs/designs/2026-05-20-imgproxy-base64-source-url-design.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
```
