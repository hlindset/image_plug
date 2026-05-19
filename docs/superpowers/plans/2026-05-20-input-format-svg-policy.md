# Input Format and SVG Policy Implementation Plan

> **For worker agents:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to execute this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved source-format and SVG policy. It classifies decoded libvips loader families, rejects SVG and unknown decoded inputs, accepts named raster source families, and chooses JPEG or PNG for source-only automatic output after transforms.

**Architecture:** Keep source-family classification inside the request boundary. Keep output selection inside the output boundary, and imgproxy URL terminology under the imgproxy parser/docs. The request runner keeps cache lookup before fetch. It resolves modern or source-round-trip automatic output before transforms, then resolves source-only fallback after generic transform execution using final `has_alpha?` metadata.

**Tech Stack:** Elixir, Plug, ExUnit, Image 0.67, Vix/libvips, Boundary, Vale.

---

## File Structure

- Create `lib/image_plug/request/source_format.ex`
  - Owns decoded `vips-loader` and `heif-compression` mapping.
  - Returns source-family atoms or `{:unsupported_source_format, family}`.
  - Doesn't depend on parser or output boundaries.
- Update `lib/image_plug/request/processor.ex`
  - Uses `ImagePlug.Request.SourceFormat.from_image/1`.
  - Validates source family before `max_input_pixels`.
  - Stores the broader source-family atom in `%Decoded{}`.
- Update `lib/image_plug/request/processor/decoded.ex`
  - Expands the `source_format` type.
- Update `lib/image_plug/response/sender.ex`
  - Routes `{:unsupported_source_format, family}` to the existing 415 unsupported image response.
- Update `lib/image_plug/output/policy.ex`
  - Adds source-only pending automatic output selection.
  - Keeps product-neutral output formats only: AVIF, WebP, JPEG, PNG.
  - Resolves pending source-only output from a final `has_alpha?` boolean.
- Update `lib/image_plug/request/runner.ex`
  - Carries source-only pending automatic output through transform execution.
  - Calls `Image.has_alpha?/1` only after final transform state exists.
  - Keeps automatic response headers, including `Vary: Accept`.
- Update `test/image_plug/processor_test.exs`
  - Adds decoded source validation tests and SVG/input-limit ordering.
- Create `test/image_plug/request/source_format_test.exs`
  - Tests loader-prefix mapping without requiring optional runtime libraries.
- Update `test/image_plug/output_policy_test.exs`
  - Tests source-only pending fallback and final alpha resolution.
- Update `test/image_plug/request_runner_test.exs`
  - Tests source-only automatic fallback, cache ordering, cache write headers, and alpha cases.
- Update `test/image_plug/imgproxy_wire_conformance_test.exs`
  - Adds wire-level SVG rejection before cache write.
- Update `test/parser/imgproxy_test.exs`
  - Renames `@extension` tests and assertions to output-extension terminology.
- Update `docs/imgproxy_path_api.md`
  - Describes `@extension` as requested output, not source format.
- Update `docs/imgproxy_support_matrix.md`
  - Lists accepted input families and unsupported SVG/GIF/ICO/BMP/PDF/PSD/RAW/video for this slice.

## Task 1: Source Format Classifier

**Files:**
- Create: `lib/image_plug/request/source_format.ex`
- Create: `test/image_plug/request/source_format_test.exs`

- [ ] **Step 1: Write the failing source-format mapping tests**

Create `test/image_plug/request/source_format_test.exs`:

```elixir
defmodule ImagePlug.Request.SourceFormatTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.SourceFormat

  describe "classify_loader/2" do
    test "maps standard raster loader prefixes" do
      assert SourceFormat.classify_loader("jpegload_buffer", fn _ -> :error end) == {:ok, :jpeg}
      assert SourceFormat.classify_loader("pngload_buffer", fn _ -> :error end) == {:ok, :png}
      assert SourceFormat.classify_loader("webpload_buffer", fn _ -> :error end) == {:ok, :webp}
      assert SourceFormat.classify_loader("tiffload_buffer", fn _ -> :error end) == {:ok, :tiff}
      assert SourceFormat.classify_loader("jp2kload_buffer", fn _ -> :error end) == {:ok, :jpeg2000}
      assert SourceFormat.classify_loader("jxlload_buffer", fn _ -> :error end) == {:ok, :jpeg_xl}
    end

    test "distinguishes AVIF from other HEIF-family inputs" do
      assert SourceFormat.classify_loader("heifload_buffer", fn
               "heif-compression" -> {:ok, "av1"}
               _key -> :error
             end) == {:ok, :avif}

      assert SourceFormat.classify_loader("heifload_buffer", fn
               "heif-compression" -> {:ok, "hevc"}
               _key -> :error
             end) == {:ok, :heif}

      assert SourceFormat.classify_loader("heifload_buffer", fn _key -> :error end) ==
               {:ok, :heif}
    end

    test "rejects SVG and unknown loader families" do
      assert SourceFormat.classify_loader("svgload_buffer", fn _ -> :error end) ==
               {:error, {:unsupported_source_format, :svg}}

      assert SourceFormat.classify_loader("magickload_buffer", fn _ -> :error end) ==
               {:error, {:unsupported_source_format, :unknown}}

      assert SourceFormat.classify_loader(nil, fn _ -> :error end) ==
               {:error, {:unsupported_source_format, :unknown}}
    end
  end

end
```

- [ ] **Step 2: Run the new test and verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_format_test.exs
```

Expected: FAIL with `ImagePlug.Request.SourceFormat` undefined.

- [ ] **Step 3: Add the classifier module**

Create `lib/image_plug/request/source_format.ex`:

```elixir
defmodule ImagePlug.Request.SourceFormat do
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage

  @type source_format() ::
          :avif
          | :webp
          | :jpeg
          | :png
          | :heif
          | :tiff
          | :jpeg2000
          | :jpeg_xl

  @type unsupported_family() :: :svg | :unknown
  @type error() :: {:unsupported_source_format, unsupported_family()}

  @spec from_image(VipsImage.t()) :: {:ok, source_format()} | {:error, error()}
  def from_image(%VipsImage{} = image) do
    case VipsImage.header_value(image, "vips-loader") do
      {:ok, loader} when is_binary(loader) ->
        classify_loader(loader, &header_value(image, &1))

      {:ok, _loader} ->
        {:error, {:unsupported_source_format, :unknown}}

      {:error, _reason} ->
        {:error, {:unsupported_source_format, :unknown}}
    end
  end

  @spec classify_loader(term(), (String.t() -> {:ok, term()} | :error | {:error, term()})) ::
          {:ok, source_format()} | {:error, error()}
  def classify_loader("jpegload" <> _suffix, _metadata), do: {:ok, :jpeg}
  def classify_loader("pngload" <> _suffix, _metadata), do: {:ok, :png}
  def classify_loader("webpload" <> _suffix, _metadata), do: {:ok, :webp}
  def classify_loader("tiffload" <> _suffix, _metadata), do: {:ok, :tiff}
  def classify_loader("jp2kload" <> _suffix, _metadata), do: {:ok, :jpeg2000}
  def classify_loader("jxlload" <> _suffix, _metadata), do: {:ok, :jpeg_xl}
  def classify_loader("svgload" <> _suffix, _metadata), do: {:error, {:unsupported_source_format, :svg}}

  def classify_loader("heifload" <> _suffix, metadata),
    do: heif_source_format(metadata)

  def classify_loader(_loader, _metadata), do: {:error, {:unsupported_source_format, :unknown}}

  defp heif_source_format(metadata) do
    case metadata.("heif-compression") do
      {:ok, "av1"} -> {:ok, :avif}
      _missing_or_other -> {:ok, :heif}
    end
  end

  defp header_value(%VipsImage{} = image, key) do
    case VipsImage.header_value(image, key) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end
end
```

- [ ] **Step 4: Run the new source-format tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_format_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_format.ex test/image_plug/request/source_format_test.exs
mise exec -- git commit -m "Add decoded source format classifier"
```

## Task 2: Processor Validation and 415 Error Routing

**Files:**
- Update: `lib/image_plug/request/processor.ex`
- Update: `lib/image_plug/request/processor/decoded.ex`
- Update: `lib/image_plug/response/sender.ex`
- Update: `test/image_plug/processor_test.exs`
- Update: `test/image_plug/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add processor tests for source-family validation**

In `test/image_plug/processor_test.exs`, add this module reference near the existing module references:

```elixir
  alias Vix.Vips.Image, as: VipsImage
```

Add these helpers near the existing private helpers:

```elixir
  defp svg_supported? do
    case VipsImage.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end

  defp svg_body(width, height) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}">
      <rect width="#{width}" height="#{height}" fill="red"/>
    </svg>
    """
  end
```

Add these tests:

```elixir
  test "decode_validate_source_response rejects SVG after decode" do
    unless svg_supported?(), do: flunk("SVG loader unavailable")

    source_response = %Response{stream: [svg_body(20, 20)]}

    assert {:error, {:unsupported_source_format, :svg}} =
             Processor.decode_validate_source_response(source_response, plan(), opts())
  end

  test "unsupported decoded source format is reported before input pixel limits" do
    unless svg_supported?(), do: flunk("SVG loader unavailable")

    source_response = %Response{stream: [svg_body(2000, 2000)]}

    assert {:error, {:unsupported_source_format, :svg}} =
             Processor.decode_validate_source_response(
               source_response,
               plan(),
               Keyword.put(opts(), :max_input_pixels, 1)
             )
  end
```

Keep these as explicit failures if the SVG loader is missing. These tests verify the chosen SVG policy. If CI doesn't provide SVG loader support, fix the CI libvips feature set instead of turning the tests into silent passes.

- [ ] **Step 2: Add wire-level SVG rejection test**

In `test/image_plug/imgproxy_wire_conformance_test.exs`, add this source adapter near the other nested test modules:

```elixir
  defmodule SvgOriginImage do
    def call(conn, opts) do
      send(Keyword.fetch!(opts, :test_pid), :origin_fetch)

      body = """
      <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
        <rect width="20" height="20" fill="red"/>
      </svg>
      """

      conn
      |> put_resp_content_type("image/svg+xml")
      |> Plug.Conn.send_resp(200, body)
    end
  end
```

Add this helper near the private helpers at the bottom of the file:

```elixir
  defp svg_supported? do
    case Vix.Vips.Image.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end
```

Add this test:

```elixir
  test "decoded SVG input returns unsupported image response and does not write cache" do
    unless svg_supported?(), do: flunk("SVG loader unavailable")

    conn =
      call_imgproxy(
        "/_/plain/images/vector.svg",
        Keyword.merge(@default_opts,
          cache: {CacheProbe, result: :miss},
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {SvgOriginImage, test_pid: self()}]}
          ]
        )
      )

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
    assert_received :cache_lookup
    assert_received :origin_fetch
    refute_received {:cache_put, _key, _entry}
  end

  test "explicit output requests still reject decoded SVG input" do
    unless svg_supported?(), do: flunk("SVG loader unavailable")

    for path <- ["/_/f:png/plain/images/vector.svg", "/_/plain/images/vector.svg@png"] do
      conn =
        call_imgproxy(
          path,
          Keyword.merge(@default_opts,
            cache: {CacheProbe, result: :miss},
            sources: [
              path:
                {RootHTTPAdapter,
                 root_url: "http://origin.test",
                 req_options: [plug: {SvgOriginImage, test_pid: self()}]}
            ]
          )
        )

      assert conn.status == 415
      assert conn.resp_body == "source response is not a supported image"
      assert get_resp_header(conn, "vary") == []
      assert_received :cache_lookup
      assert_received :origin_fetch
      refute_received {:cache_put, _key, _entry}
    end
  end
```

- [ ] **Step 3: Run the focused tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: at least one FAIL because SVG isn't rejected as `{:unsupported_source_format, :svg}` yet.

- [ ] **Step 4: Wire source-format validation into the processor**

In `lib/image_plug/request/processor.ex`, replace the `VipsImage` module reference with `SourceFormat`:

```elixir
  alias ImagePlug.Request.SourceFormat
```

Update the type:

```elixir
  @type source_format() :: SourceFormat.source_format()
```

Update `decode_validate_source_response/3` so source-family validation runs before the pixel limit:

```elixir
  def decode_validate_source_response(%Source.Response{} = source_response, %Plan{} = plan, opts) do
    decode_options = DecodePlanner.open_options(first_pipeline_operations(plan))

    with {:ok, image} <-
           decode_source_response(source_response, decode_options, opts)
           |> wrap_decode_error(),
         {:ok, source_format} <- SourceFormat.from_image(image),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
      {:ok,
       %Decoded{
         decode_options: decode_options,
         image: image,
         source_format: source_format
       }}
    end
  end
```

Update the existing `"decode_validate_source_response returns input limit errors"` test in `test/image_plug/processor_test.exs` so it decodes a real fixture with loader metadata instead of using `DecodeValidImageOpen`:

```elixir
  test "decode_validate_source_response returns input limit errors" do
    {:ok, operation} = resize_fit(120, :auto)

    plan = %Plan{
      plan()
      | pipelines: [
          %Pipeline{operations: [operation]}
        ]
    }

    source_response = %Response{stream: [File.read!("priv/static/images/beach.jpg")]}

    assert {:error, {:input_limit, {:too_many_input_pixels, pixel_count, 1}}} =
             Processor.decode_validate_source_response(
               source_response,
               plan,
               Keyword.put(opts(), :max_input_pixels, 1)
             )

    assert pixel_count > 1
  end
```

Delete these private functions from `lib/image_plug/request/processor.ex`:

```elixir
  defp source_format(image) do
    case VipsImage.header_value(image, "vips-loader") do
      {:ok, loader} when is_binary(loader) -> loader_format(loader)
      {:error, _reason} -> nil
    end
  end

  defp loader_format("jpegload" <> _suffix), do: :jpeg
  defp loader_format("pngload" <> _suffix), do: :png
  defp loader_format("webpload" <> _suffix), do: :webp
  defp loader_format("heifload" <> _suffix), do: :avif
  defp loader_format(_loader), do: nil
```

- [ ] **Step 5: Update decoded source type**

In `lib/image_plug/request/processor/decoded.ex`, add the module reference and type:

```elixir
  alias ImagePlug.Request.SourceFormat
```

Change the struct type to:

```elixir
  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          source_format: SourceFormat.source_format()
        }
```

- [ ] **Step 6: Route unsupported source format to 415**

In `lib/image_plug/response/sender.ex`, add this clause before the generic processing-error clauses:

```elixir
  defp handle_processing_error(conn, {:unsupported_source_format, _family}, response_headers),
    do: send_decode_error(conn, :unsupported_source_format, response_headers)
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_format_test.exs test/image_plug/processor_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_format.ex lib/image_plug/request/processor.ex lib/image_plug/request/processor/decoded.ex lib/image_plug/response/sender.ex test/image_plug/processor_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
mise exec -- git commit -m "Reject unsupported decoded source formats"
```

## Task 3: Output Policy Pending Source-Only Fallback

**Files:**
- Update: `lib/image_plug/output/policy.ex`
- Update: `test/image_plug/output_policy_test.exs`

- [ ] **Step 1: Add output policy tests**

In `test/image_plug/output_policy_test.exs`, extend `"resolve_source_format/2"` with:

```elixir
    test "keeps source format fallback for source families that are output formats" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_source_format(policy, :webp) == {:selected, :webp, :source}
      assert Policy.resolve_source_format(policy, :avif) == {:selected, :avif, :source}
    end

    test "defers source-only fallback until final alpha metadata is known" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      for source_format <- [:heif, :tiff, :jpeg2000, :jpeg_xl] do
        assert Policy.resolve_source_format(policy, source_format) == {:needs_final_image_alpha, :source}
      end
    end
```

Add a new describe block:

```elixir
  describe "resolve_final_image_alpha/2" do
    test "uses PNG when final image has alpha and JPEG otherwise" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{}
      }

      assert Policy.resolve_final_image_alpha(policy, true) ==
               {:ok,
                %Resolved{
                  format: :png,
                  quality: :default,
                  representation_headers: [{"vary", "Accept"}]
                }}

      assert Policy.resolve_final_image_alpha(policy, false) ==
               {:ok,
                %Resolved{
                  format: :jpeg,
                  quality: :default,
                  representation_headers: [{"vary", "Accept"}]
                }}
    end

    test "applies format-specific quality to alpha fallback selections" do
      policy = %Policy{
        mode: :source,
        modern_candidates: [],
        headers: [{"vary", "Accept"}],
        quality: :default,
        format_qualities: %{jpeg: {:quality, 82}, png: {:quality, 70}}
      }

      assert {:ok, %Resolved{format: :jpeg, quality: {:quality, 82}}} =
               Policy.resolve_final_image_alpha(policy, false)

      assert {:ok, %Resolved{format: :png, quality: {:quality, 70}}} =
               Policy.resolve_final_image_alpha(policy, true)
    end
  end
```

- [ ] **Step 2: Run output policy tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_plug/output_policy_test.exs
```

Expected: FAIL because `resolve_final_image_alpha/2` and pending source-only fallback don't exist.

- [ ] **Step 3: Update output policy types and source-only resolution**

In `lib/image_plug/output/policy.ex`, add the broader source input type:

```elixir
  @type source_format() ::
          format()
          | :heif
          | :tiff
          | :jpeg2000
          | :jpeg_xl
```

Change `resolve/2` spec to:

```elixir
  @spec resolve(t(), source_format() | nil) ::
          {:ok, Resolved.t()}
          | {:error, :source_format_required}
          | {:needs_final_image_alpha, :source}
          | {:needs_encoded_evaluation}
```

Change `resolve_source_format/2` spec to:

```elixir
  @spec resolve_source_format(t(), source_format() | nil) ::
          {:selected, format(), :source}
          | {:needs_final_image_alpha, :source}
          | {:error, :source_format_required}
```

Replace `resolve_source_format/2` with:

```elixir
  def resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    cond do
      output_format?(source_format) ->
        {:selected, source_format, :source}

      source_only_format?(source_format) ->
        {:needs_final_image_alpha, :source}

      true ->
        {:error, :source_format_required}
    end
  end
```

Add:

```elixir
  @spec resolve_final_image_alpha(t(), boolean()) :: {:ok, Resolved.t()}
  def resolve_final_image_alpha(%__MODULE__{} = policy, true),
    do: {:ok, resolved(policy, :png)}

  def resolve_final_image_alpha(%__MODULE__{} = policy, false),
    do: {:ok, resolved(policy, :jpeg)}
```

Add these private helpers near `accept_header/1`:

```elixir
  defp output_format?(format) do
    case Format.mime_type(format) do
      {:ok, _mime_type} -> true
      :error -> false
    end
  end

  defp source_only_format?(format), do: format in [:heif, :tiff, :jpeg2000, :jpeg_xl]
```

- [ ] **Step 4: Update `resolve/2` to pass through pending fallback**

In `lib/image_plug/output/policy.ex`, change the `:needs_source_format` branch in `resolve/2` to:

```elixir
      :needs_source_format ->
        case resolve_source_format(policy, source_format) do
          {:selected, format, _reason} -> {:ok, resolved(policy, format)}
          {:needs_final_image_alpha, _reason} = pending -> pending
          {:error, _reason} = error -> error
        end
```

- [ ] **Step 5: Run output policy tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_policy_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/output/policy.ex test/image_plug/output_policy_test.exs
mise exec -- git commit -m "Defer source-only automatic output fallback"
```

## Task 4: Runner Integration for Final Alpha Fallback

**Files:**
- Update: `lib/image_plug/request/runner.ex`
- Update: `test/image_plug/request_runner_test.exs`

- [ ] **Step 1: Add source-only test adapter and fixture helpers**

In `test/image_plug/request_runner_test.exs`, add the `VipsImage` module reference:

```elixir
  alias Vix.Vips.Image, as: VipsImage
```

Add this source adapter near the other nested modules:

```elixir
  defmodule SourceBytes do
    @behaviour ImagePlug.Source

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePlug.Source
    def fetch(_resolved, opts, _runtime_opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :source_fetch})
        :error -> :ok
      end

      {:ok, %SourceResponse{stream: [Keyword.fetch!(opts, :body)]}}
    end
  end
```

Add these helpers:

```elixir
  defp require_tiff_support! do
    with {:ok, loaders} <- VipsImage.supported_loader_suffixes(),
         {:ok, savers} <- VipsImage.supported_saver_suffixes(),
         true <- ".tiff" in loaders and ".tiff" in savers do
      :ok
    else
      _reason -> raise ExUnit.AssertionError, message: "TIFF load/save support unavailable"
    end
  end

  defp tiff_body(color, opts \\ []) do
    require_tiff_support!()

    image =
      20
      |> Image.new!(20, Keyword.merge([color: color], opts))

    Image.write!(image, :memory, suffix: ".tiff")
  end

  defp background_operation(alpha) do
    assert {:ok, color} = Operation.color(255, 255, 255, alpha)
    assert {:ok, operation} = Operation.background(color)
    operation
  end
```

- [ ] **Step 2: Add runner tests for source-only fallback and cache**

In `test/image_plug/request_runner_test.exs`, add:

```elixir
  test "automatic output for source-only opaque input falls back to JPEG after transforms" do
    body = tiff_body(:white)

    assert {:ok,
            {:image, %State{},
             %Resolved{format: :jpeg, representation_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: body}}
             )
  end

  test "automatic output for source-only alpha input falls back to PNG after transforms" do
    body = tiff_body([255, 0, 0, 128], bands: 4)

    assert {:ok,
            {:image, %State{},
             %Resolved{format: :png, representation_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: body}}
             )
  end

  test "opaque background transform removes alpha before source-only fallback" do
    body = tiff_body([255, 0, 0, 128], bands: 4)

    assert {:ok,
            {:image, %State{} = state,
             %Resolved{format: :jpeg, representation_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
                 conn(:get, "/_/bg:fff/plain/images/source.tiff"),
                 plan(
                   output: %Output{mode: :automatic},
                   pipelines: [%Pipeline{operations: [background_operation({:ratio, 1, 1})]}]
                 ),
               resolved_source(),
               sources: %{path: {SourceBytes, body: body}}
             )

    refute Image.has_alpha?(state.image)
  end

  test "modern Accept candidate still wins for source-only input before final alpha fallback" do
    body = tiff_body(:white)

    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/webp")

    assert {:ok,
            {:image, %State{},
             %Resolved{format: :webp, representation_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: body}}
             )
  end

  test "source-only automatic fallback cache miss writes successful entry with Vary" do
    body = tiff_body(:white)
    ref = make_ref()

    assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg", headers: [{"vary", "Accept"}]},
                  %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceBytes, body: body, test_pid: self(), test_ref: ref}},
               test_pid: self(),
               test_ref: ref
             )

    assert_receive {:runner_event, ^ref, {:cache_lookup, key}}
    assert_receive {:runner_event, ^ref, :source_fetch}
    assert_receive {:runner_event, ^ref, {:cache_put, ^key}}
    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
  end

  test "source-only alpha fallback cache miss writes PNG entry with Vary" do
    body = tiff_body([255, 0, 0, 128], bands: 4)
    ref = make_ref()

    assert {:ok, {:cache_entry, %Entry{content_type: "image/png", headers: [{"vary", "Accept"}]},
                  %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceBytes, body: body, test_pid: self(), test_ref: ref}},
               test_pid: self(),
               test_ref: ref
             )

    assert_receive {:runner_event, ^ref, {:cache_lookup, key}}
    assert_receive {:runner_event, ^ref, :source_fetch}
    assert_receive {:runner_event, ^ref, {:cache_put, ^key}}
    assert_received {:cache_put, ^key, %Entry{content_type: "image/png"}, _opts}
  end

  test "source-only automatic cache hit returns without fetching source" do
    entry = %Entry{
      body: "cached png",
      content_type: "image/png",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheHit, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )
  end
```

- [ ] **Step 3: Run runner tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: FAIL because runner treats source-only automatic output as `:source_format_required`.

- [ ] **Step 4: Update runner output resolution types and metadata**

In `lib/image_plug/request/runner.ex`, update `output_stop_metadata/2` to handle pending fallback:

```elixir
  defp output_stop_metadata({:needs_final_image_alpha, _reason}, %Output{}),
    do: %{result: :ok, output_format: :pending_final_image_alpha}
```

- [ ] **Step 5: Add pending fallback processing branch**

In `lib/image_plug/request/runner.ex`, update `resolve_source_format_automatic/4`:

```elixir
  defp resolve_source_format_automatic(%Decoded{} = decoded, plan, opts, policy) do
    case resolve_output(policy, decoded.source_format, plan.output, opts) do
      {:ok, %Resolved{} = resolved_output} ->
        process_decoded_source_with_output(decoded, plan, opts, resolved_output)

      {:needs_final_image_alpha, _reason} ->
        process_decoded_source_with_final_alpha_output(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
```

Add this function below `process_decoded_source_with_output/4`:

```elixir
  defp process_decoded_source_with_final_alpha_output(decoded, plan, opts, policy) do
    case Processor.process_decoded_source(decoded, plan, opts) do
      {:ok, %State{} = final_state} ->
        has_alpha? = Image.has_alpha?(final_state.image)

        case resolve_final_image_alpha_output(policy, has_alpha?, plan.output, opts) do
          {:ok, %Resolved{} = resolved_output} ->
            {:ok, final_state, resolved_output, resolved_output.representation_headers}
        end

      {:error, reason} ->
        {:error, reason, policy.headers}
    end
  end
```

Add this telemetry wrapper near `resolve_output/4`:

```elixir
  defp resolve_final_image_alpha_output(policy, has_alpha?, %Output{} = output, opts) do
    Telemetry.span(opts, [:output, :negotiate], output_plan_metadata(output), fn ->
      result = Policy.resolve_final_image_alpha(policy, has_alpha?)

      {result, output_stop_metadata(result, output)}
    end)
  end
```

- [ ] **Step 6: Run runner tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: PASS.

- [ ] **Step 7: Run focused policy and processor tests together**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_format_test.exs test/image_plug/output_policy_test.exs test/image_plug/processor_test.exs test/image_plug/request_runner_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/request/runner.ex test/image_plug/request_runner_test.exs
mise exec -- git commit -m "Resolve source-only automatic output after transforms"
```

## Task 5: Imgproxy Extension Terminology and Wire Contracts

**Files:**
- Update: `lib/image_plug/parser/imgproxy.ex`
- Update: `lib/image_plug/parser/imgproxy/path.ex`
- Update: `lib/image_plug/parser/imgproxy/format.ex`
- Update: `test/parser/imgproxy/path_test.exs`
- Update: `test/parser/imgproxy_test.exs`
- Update: `docs/imgproxy_path_api.md`
- Update: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Rename parser test terminology from source extension to output extension**

In `test/parser/imgproxy_test.exs`, rename these test names:

```elixir
  test "plain source @extension selects explicit output format" do
```

```elixir
  test "dangling raw @ leaves output automatic when no explicit output extension exists" do
```

```elixir
  test "rejects multiple raw @ output extension separators" do
```

```elixir
  test "rejects unknown output extensions as parser errors" do
```

```elixir
  test "rejects best output extension as an unsupported output semantic" do
```

Change the repeated-`@` assertion in `test/parser/imgproxy_test.exs`:

```elixir
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png"), []) ==
             {:error, {:multiple_output_extension_separators, "images/cat.jpg@webp@png"}}
```

Change the matching assertion in `test/parser/imgproxy/path_test.exs`:

```elixir
    assert Path.parse_plain_source(["cat.jpg@webp@png"]) ==
             {:error, {:multiple_output_extension_separators, "cat.jpg@webp@png"}}
```

- [ ] **Step 2: Rename parser implementation terminology**

In `lib/image_plug/parser/imgproxy/path.ex`, change the repeated separator error:

```elixir
      _parts ->
        {:error, {:multiple_output_extension_separators, encoded}}
```

Also rename private variable names in this file from `source_format` to `output_extension_format` where they refer to `@extension` output selection:

```elixir
  defp decode_source_path(source, output_extension_format) do
    with :ok <- validate_percent_encoded_segments(source) do
      {:ok, source, output_extension_format}
    end
  end
```

In `lib/image_plug/parser/imgproxy.ex`, rename local variables from `source_format` to `output_extension_format` in the `parse/2` and `parsed_request/4` path:

```elixir
         {:ok, source_path, output_extension_format} <- Path.parse_plain_source(raw_source_path) do
      parsed_request(
        signature,
        source_path,
        output_extension_format,
        request_options
      )
```

```elixir
  defp parsed_request(
         signature,
         source_path,
         output_extension_format,
         request_options
       ) do
    output_format = output_extension_format || request_options.output.format
```

In `lib/image_plug/parser/imgproxy/format.ex`, rename module attributes to output terminology:

```elixir
  @output_extension_names ~w(webp avif jpeg jpg png best)

  @output_extension_formats %{
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "jpg" => :jpeg,
    "png" => :png,
    "best" => :best
  }

  def parse(value) do
    case Map.fetch(@output_extension_formats, value) do
      {:ok, parsed_value} -> {:ok, parsed_value}
      :error -> {:error, {:invalid_format, value, @output_extension_names}}
    end
  end
```

- [ ] **Step 3: Update imgproxy path API docs**

In `docs/imgproxy_path_api.md`, keep the existing behavior but replace source-format wording with output-format wording:

```markdown
`plain` starts the source path. Add `@extension` to the end of the source path
to request an explicit output format and bypass `Accept` negotiation. The suffix
does not declare the source image format; ImagePlug still detects the source
family from decoded image metadata.
```

Replace the table label:

```markdown
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`/`jpg`, `png` |
```

Replace the conflict sentence near the output section:

```markdown
If a request includes both an option format and source-path `@extension`,
`@extension` wins because the imgproxy parser treats it as the final requested
output format.
```

- [ ] **Step 4: Update support matrix docs**

In `docs/imgproxy_support_matrix.md`, replace the `@extension` row with:

```markdown
| Plain source `@extension` | Supported | Requests explicit output format and bypasses `Accept` negotiation. It does not declare source format. |
```

Add a source input policy row or short section near the existing source-related rows:

```markdown
### Source input formats

ImagePlug detects source family after libvips decodes the input. Accepted source
families in this slice are JPEG, PNG, WebP, AVIF, non-AVIF HEIF/HEIC, TIFF,
JPEG 2000, and JPEG XL when the deployed libvips build can read them.

SVG, GIF, ICO, BMP, PDF, PSD, RAW, and video inputs are unsupported in this
slice. SVG is rejected after decode identifies an SVG loader and before
transforms or output encoding.
```

- [ ] **Step 5: Run parser and docs checks**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs
mise exec -- vale docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/path.ex lib/image_plug/parser/imgproxy/format.ex test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "Clarify imgproxy output extension terminology"
```

## Task 6: Full Verification and Cleanup

**Files:**
- Review all modified files.

- [ ] **Step 1: Run formatter**

Run:

```bash
mise exec -- mix format
```

Expected: command exits 0. If it changes files, inspect the diff before committing.

- [ ] **Step 2: Run focused behavior tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_format_test.exs test/image_plug/processor_test.exs test/image_plug/output_policy_test.exs test/image_plug/request_runner_test.exs test/image_plug/imgproxy_wire_conformance_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs
```

Expected: PASS.

- [ ] **Step 3: Run full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 4: Run compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [ ] **Step 5: Run Vale on changed docs**

Run:

```bash
mise exec -- vale docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md docs/superpowers/specs/2026-05-19-input-format-svg-policy-design.md docs/superpowers/plans/2026-05-20-input-format-svg-policy.md
```

Expected: PASS.

- [ ] **Step 6: Inspect final diff for boundary and scope**

Run:

```bash
mise exec -- git diff --stat HEAD
mise exec -- git diff HEAD -- lib/image_plug/request lib/image_plug/output lib/image_plug/response test docs
```

Confirm:

- Product-neutral request and output modules contain no new imgproxy option names.
- `ImagePlug.Request` doesn't depend on parser modules or concrete transform operation modules.
- `ImagePlug.Output.Policy` doesn't receive image values or transform state.
- Cache lookup remains before source fetch.
- The implementation adds no runtime output write-capability probing.
- The implementation adds no SVG passthrough, sanitizer, or pre-decode sniffing.

- [ ] **Step 7: Commit verification cleanup**

If formatting or documentation verification changed files, run:

```bash
mise exec -- git add lib test docs
mise exec -- git commit -m "Polish input format policy implementation"
```

If no files changed, don't create an empty commit.

## Self-Review

**Spec coverage:** The plan covers decoded loader mapping, SVG rejection after decode, validation before pixel limits, accepted raster families, source-only JPEG/PNG fallback after transforms, cache/Vary behavior, imgproxy `@extension` terminology, and documentation updates. It excludes pre-decode sniffing, SVG passthrough/sanitization/rasterization, output write-capability probing, origin metadata propagation, and issue #50 HTTP negotiation semantics.

**Placeholder scan:** The plan contains no `TBD`, no deferred implementation steps, and no generic "add tests" instructions without concrete examples. Explicit test gates handle SVG and TIFF runtime library variability. The plan doesn't require optional JP2/JXL fixture tests. Direct classifier tests cover those loader prefixes.

**Type consistency:** Source-family atoms are consistent across `SourceFormat`, `%Decoded{}`, `Output.Policy`, and tests. Output format atoms remain `:avif | :webp | :jpeg | :png`. Pending source-only output uses `{:needs_final_image_alpha, :source}` in policy and runner.
