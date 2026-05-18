# Product-Neutral Source Adapters Implementation Plan

<!-- vale Vale.Spelling = NO -->
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
<!-- vale Vale.Spelling = YES -->

**Goal:** Replace the current origin-only request path with source adapters for path, HTTP, HTTPS, file, and S3 sources while preserving validation, cache, fetch, and decode ordering.

**Architecture:** Parsers produce typed `ImagePlug.Plan.Source.*` structs. `ImagePlug.Source` validates configured adapters at init time, resolves a plan source into deterministic cache identity before cache lookup, and fetches a wrapped byte stream only on cache miss or cache skip. Request, cache, output, response, and transform code use the source boundary and don't know product-specific adapter details.

**Tech Stack:** Elixir 1.17, Plug, Req, Req SigV4, NimbleOptions, Boundary, ExUnit, StreamData, Vale.

---

## File Structure

Create:

- `lib/image_plug/plan/source.ex` defines the shared source type union.
- `lib/image_plug/plan/source/path.ex` defines root-relative path sources.
- `lib/image_plug/plan/source/url.ex` defines absolute HTTP and HTTPS URL sources.
- `lib/image_plug/plan/source/object.ex` defines product-neutral object-store sources.
- `lib/image_plug/plan/source/reference.ex` defines the deferred immutable reference source shape.
- `lib/image_plug/source.ex` defines the source behaviour, registry, adapter dispatch, telemetry spans, and stream wrapper.
- `lib/image_plug/source/resolved.ex` defines resolved source identity, cache policy, and fetch payload.
- `lib/image_plug/source/response.ex` defines source byte stream responses.
- `lib/image_plug/source/stream_error.ex` defines the sanitized exception raised by wrapped source streams during deferred stream failures.
- `lib/image_plug/source/http.ex` implements the HTTP and HTTPS adapter.
- `lib/image_plug/source/file.ex` implements the local file adapter.
- `lib/image_plug/source/s3.ex` implements the S3-compatible object adapter.
- `lib/image_plug/source/s3/credentials.ex` defines S3 credential provider validation and dispatch.
- `lib/image_plug/parser/imgproxy/source.ex` translates decoded imgproxy plain source strings into `Plan.Source` structs.
- `lib/image_plug/parser/imgproxy/source_scheme.ex` defines the custom imgproxy source scheme translator behaviour.
- `test/image_plug/plan/source_test.exs` covers source structs and plan shape validation.
- `test/image_plug/source_test.exs` covers registry dispatch, option validation, resolved identity validation, cache skip, stream wrapping, and custom adapters.
- `test/image_plug/source/http_test.exs` covers HTTP adapter resolution and streaming.
- `test/image_plug/source/file_test.exs` covers file adapter resolution and streaming.
- `test/image_plug/source/s3_test.exs` covers S3 adapter resolution, per-bucket config, credential provider timing, and request signing options.
- `test/parser/imgproxy/source_test.exs` covers imgproxy source translation and custom scheme translators.
- `test/support/image_plug/source_test/custom_adapter.ex` provides a source adapter test double.
- `test/support/image_plug/source_test/foobar_translator.ex` provides a reusable imgproxy custom source scheme translator.
- `test/support/image_plug/source_test/invalid_adapter.ex` provides malformed callback returns.
- `test/support/image_plug/source_test/invalid_identity_adapter.ex` provides invalid resolved identity coverage.
- `test/support/image_plug/source_test/valid_adapter.ex` provides a reusable valid source adapter for request flow tests.
- `test/support/image_plug/source_test/raising_adapter.ex` provides source adapter exception coverage.
- `test/support/image_plug/source_test/stream_with_cleanup.ex` provides stream cleanup assertions.
- `test/support/image_plug/source_test/credential_provider.ex` provides S3 credential provider test doubles.

Modify:

- `lib/image_plug.ex` to validate source config during init, resolve sources after plan validation, and route source errors.
- `lib/image_plug/plan.ex` to export source structs and validate typed source shapes.
- `lib/image_plug/request/options.ex` to validate `:sources`; `:root_url` is removed once request flow uses source adapters.
- `lib/image_plug/request/runner.ex` to receive `ImagePlug.Source.Resolved`, honor `cache: :skip`, and pass resolved identity into cache key construction.
- `lib/image_plug/request/processor.ex` to fetch through `ImagePlug.Source` and move decoded source state off `ImagePlug.Origin`.
- `lib/image_plug/cache.ex` and `lib/image_plug/cache/key.ex` to build keys from primitive resolved source identity instead of origin identity.
- `lib/image_plug/parser/imgproxy.ex`, `lib/image_plug/parser/imgproxy/path.ex`, and `lib/image_plug/parser/imgproxy/plan_builder.ex` to split source format suffixes before source translation and add custom scheme config.
- `lib/image_plug/response/sender.ex` to send source errors using the same status/body behavior as current origin errors unless a narrower existing response path fits.
- `lib/image_plug/telemetry.ex` only if a small helper is needed to sanitize source span metadata.
- `mix.exs` docs grouping to replace origin internals with source internals.
- `test/image_plug/architecture_boundary_test.exs` to replace origin boundary assertions with source boundary assertions.
- Existing origin, request, cache, parser, telemetry, and wire tests where their assertions name origin identity or old `{:plain, path}` source tuples.

Delete after replacement:

- `lib/image_plug/origin.ex`
- `lib/image_plug/origin/identity.ex`
- `lib/image_plug/origin/decoded.ex`
- `test/image_plug/origin_test.exs`

Don't create:

- Any `ImagePlug.Runtime.*` module.
- Adapters for GCS, Azure Blob Storage, Swift, or `Reference` fetching.
- A file-path fast path into the decoder.

---

## Task 1: Plan Source Structs

**Files:**

- Create: `lib/image_plug/plan/source.ex`
- Create: `lib/image_plug/plan/source/path.ex`
- Create: `lib/image_plug/plan/source/url.ex`
- Create: `lib/image_plug/plan/source/object.ex`
- Create: `lib/image_plug/plan/source/reference.ex`
- Modify: `lib/image_plug/plan.ex`
- Test: `test/image_plug/plan/source_test.exs`
- Test: `test/image_plug/plan_test.exs`

- [ ] **Step 1: Write failing source struct tests**

Add `test/image_plug/plan/source_test.exs`:

```elixir
defmodule ImagePlug.Plan.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source

  test "path source accepts normalized relative segments" do
    source = %Source.Path{segments: ["images", "cat.jpg"]}

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  test "path source rejects traversal and absolute-looking segments" do
    for segments <- [
          [".", "cat.jpg"],
          ["..", "cat.jpg"],
          ["images", ".."],
          ["/images", "cat.jpg"],
          ["images/cat.jpg"],
          ["images\\..\\secret.jpg"]
        ] do
      source = %Source.Path{segments: segments}

      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "url source accepts http and https with primitive path and query fields" do
    https = %Source.URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: "v=1"
    }

    http = %Source.URL{
      scheme: :http,
      host: "assets.example.com",
      port: 8080,
      path: [],
      query: nil
    }

    assert {:ok, %Plan{source: ^https}} = Plan.validate_shape(plan(https))
    assert {:ok, %Plan{source: ^http}} = Plan.validate_shape(plan(http))
  end

  test "url source rejects unsupported schemes and malformed hosts" do
    for source <- [
          %Source.URL{scheme: :ftp, host: "assets.example.com", path: [], query: nil},
          %Source.URL{scheme: :https, host: "", path: [], query: nil},
          %Source.URL{scheme: :https, host: nil, path: [], query: nil},
          %Source.URL{scheme: :https, host: "assets.example.com", port: 0, path: [], query: nil},
          %Source.URL{scheme: :https, host: "assets.example.com", path: ["images/cat.jpg"], query: nil}
        ] do
      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "object source accepts product-neutral object identity fields" do
    source = %Source.Object{
      adapter: :s3,
      scope: "bucket",
      key: "images/cat.jpg",
      revision: "abc"
    }

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  test "object source rejects malformed adapter scope key and revision fields" do
    for source <- [
          %Source.Object{adapter: "s3", scope: "bucket", key: "images/cat.jpg"},
          %Source.Object{adapter: :s3, scope: "", key: "images/cat.jpg"},
          %Source.Object{adapter: :s3, scope: "bucket", key: ""},
          %Source.Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: :abc}
        ] do
      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "reference source validates immutable identifier shape but fetch support is deferred" do
    source = %Source.Reference{adapter: :catalog, id: "asset_123", revision: "sha256", metadata: [variant: "original"]}

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  defp plan(source) do
    %Plan{
      source: source,
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: :automatic}
    }
  end
end
```

Update the existing `test/image_plug/plan_test.exs` setup to use `%Source.Path{}` instead of `{:plain, ...}` for default sources.

- [ ] **Step 2: Run failing tests**

Run:

```bash
mise exec -- mix test test/image_plug/plan/source_test.exs test/image_plug/plan_test.exs
```

Expected: failures for missing `ImagePlug.Plan.Source.*` modules and old `Plan.validate_shape/1` rejecting source structs.

- [ ] **Step 3: Add source structs and plan validation**

Create source modules with enforced keys:

```elixir
defmodule ImagePlug.Plan.Source do
  @moduledoc """
  Product-neutral source identifiers produced by parsers.
  """

  alias ImagePlug.Plan.Source

  @type t :: Source.Path.t() | Source.URL.t() | Source.Object.t() | Source.Reference.t()
end
```

```elixir
defmodule ImagePlug.Plan.Source.Path do
  @moduledoc """
  Root-relative path source.
  """

  @enforce_keys [:segments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{segments: [String.t()]}
end
```

```elixir
defmodule ImagePlug.Plan.Source.URL do
  @moduledoc """
  Absolute HTTP and HTTPS source.
  """

  @enforce_keys [:scheme, :host, :path]
  defstruct [:scheme, :host, :port, :path, :query]

  @type t :: %__MODULE__{
          scheme: :http | :https,
          host: String.t(),
          port: :inet.port_number() | nil,
          path: [String.t()],
          query: String.t() | nil
        }
end
```

```elixir
defmodule ImagePlug.Plan.Source.Object do
  @moduledoc """
  Product-neutral bucket or container object source.
  """

  @enforce_keys [:adapter, :scope, :key]
  defstruct [:adapter, :scope, :key, :revision]

  @type t :: %__MODULE__{
          adapter: atom(),
          scope: String.t(),
          key: String.t(),
          revision: String.t() | nil
        }
end
```

```elixir
defmodule ImagePlug.Plan.Source.Reference do
  @moduledoc """
  Immutable external source reference.

  Fetching references is intentionally deferred; this struct exists so parsers
  and custom translators can target the planned shape.
  """

  @enforce_keys [:adapter, :id]
  defstruct [:adapter, :id, :revision, metadata: []]

  @type t :: %__MODULE__{
          adapter: atom(),
          id: String.t(),
          revision: String.t() | nil,
          metadata: keyword()
        }
end
```

Modify `ImagePlug.Plan`:

```elixir
alias ImagePlug.Plan.Operation
alias ImagePlug.Plan.Output
alias ImagePlug.Plan.Pipeline
alias ImagePlug.Plan.Response
alias ImagePlug.Plan.Source

use Boundary,
  top_level?: true,
  deps: [],
  exports: [
    Pipeline,
    Orientation,
    Output,
    Response,
    Color,
    Source,
    Source.Path,
    Source.URL,
    Source.Object,
    Source.Reference,
    Operation,
    Operation.Background,
    Operation.CropGuided,
    Operation.CropRegion,
    Operation.Canvas,
    Operation.Padding,
    Operation.Resize
  ]
```

Update the source type and `validate_source/1` clauses:

```elixir
@type t :: %__MODULE__{
        source: ImagePlug.Plan.Source.t(),
        pipelines: [ImagePlug.Plan.Pipeline.t()],
        output: ImagePlug.Plan.Output.t(),
        expires: non_neg_integer(),
        cachebuster: String.t() | nil,
        response: Response.t()
      }

defp validate_source(%Source.Path{segments: segments} = source) do
  if valid_path_segments?(segments), do: :ok, else: {:error, {:unsupported_source, source}}
end

defp validate_source(%Source.URL{} = source) do
  if valid_url_source?(source), do: :ok, else: {:error, {:unsupported_source, source}}
end

defp validate_source(%Source.Object{} = source) do
  if valid_object_source?(source), do: :ok, else: {:error, {:unsupported_source, source}}
end

defp validate_source(%Source.Reference{} = source) do
  if valid_reference_source?(source), do: :ok, else: {:error, {:unsupported_source, source}}
end

defp validate_source(source), do: {:error, {:unsupported_source, source}}
```

Add private validation helpers using pattern matching and `Enum.all?/2`. Reject `.`, `..`, empty path segments, slash-bearing segments, absolute-looking segments, and backslash traversal in path and URL path sources.

- [ ] **Step 4: Run source tests**

Run:

```bash
mise exec -- mix test test/image_plug/plan/source_test.exs test/image_plug/plan_test.exs
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
mise exec -- git add lib/image_plug/plan.ex lib/image_plug/plan/source.ex lib/image_plug/plan/source/path.ex lib/image_plug/plan/source/url.ex lib/image_plug/plan/source/object.ex lib/image_plug/plan/source/reference.ex test/image_plug/plan/source_test.exs test/image_plug/plan_test.exs
mise exec -- git commit -m "Add product-neutral plan source structs"
```

---

## Task 2: Source Registry And Stream Wrapper

**Files:**

- Create: `lib/image_plug/source.ex`
- Create: `lib/image_plug/source/resolved.ex`
- Create: `lib/image_plug/source/response.ex`
- Create: `test/image_plug/source_test.exs`
- Create: `test/support/image_plug/source_test/custom_adapter.ex`
- Create: `test/support/image_plug/source_test/invalid_adapter.ex`
- Create: `test/support/image_plug/source_test/invalid_identity_adapter.ex`
- Create: `test/support/image_plug/source_test/raising_adapter.ex`
- Create: `test/support/image_plug/source_test/stream_with_cleanup.ex`
- Modify: `lib/image_plug/request/options.ex`

- [ ] **Step 1: Write failing registry and wrapper tests**

Create `test/support/image_plug/source_test/custom_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.CustomAdapter do
  @moduledoc false

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  @behaviour Source

  @impl Source
  def validate_options(opts) do
    send(self(), {:validate_options, opts})
    {:ok, Keyword.put(opts, :validated, true)}
  end

  @impl Source
  def resolve(source, opts, runtime_opts) do
    send(self(), {:resolve, source, opts, runtime_opts})

    {:ok,
     %Resolved{
       adapter: Keyword.fetch!(opts, :adapter),
       source_kind: :path,
       identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: {:source, source}
     }}
  end

  @impl Source
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    send(self(), {:fetch, resolved, opts, runtime_opts})
    {:ok, %Response{stream: ["image", " bytes"]}}
  end
end
```

Create `test/support/image_plug/source_test/invalid_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.InvalidAdapter do
  @moduledoc false

  def validate_options(_opts), do: {:ok, []}
  def resolve(_source, _opts, _runtime_opts), do: {:ok, :not_resolved}
  def fetch(_resolved, _opts, _runtime_opts), do: {:ok, :not_response}
end
```

Create `test/support/image_plug/source_test/invalid_identity_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.InvalidIdentityAdapter do
  @moduledoc false

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved

  @behaviour Source

  @impl Source
  def validate_options(opts), do: {:ok, opts}

  @impl Source
  def resolve(_source, _opts, _runtime_opts) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: [kind: :path, client: self()],
       cache: :skip,
       fetch: :bad_identity
     }}
  end

  @impl Source
  def fetch(_resolved, _opts, _runtime_opts) do
    raise "invalid identity must fail before fetch"
  end
end
```

Create `test/support/image_plug/source_test/raising_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.RaisingAdapter do
  @moduledoc false

  def validate_options(opts), do: {:ok, opts}
  def resolve(_source, _opts, _runtime_opts), do: raise("raw resolve failure")
  def fetch(_resolved, _opts, _runtime_opts), do: raise("raw fetch failure")
end
```

Create `test/support/image_plug/source_test/stream_with_cleanup.ex`:

```elixir
defmodule ImagePlug.SourceTest.StreamWithCleanup do
  @moduledoc false

  def stream(test_pid, chunks) do
    Stream.resource(
      fn -> chunks end,
      fn
        [] -> {:halt, []}
        [chunk | rest] -> {[chunk], rest}
      end,
      fn _state -> send(test_pid, :stream_closed) end
    )
  end

  def raising_stream do
    Stream.resource(
      fn -> :raise end,
      fn :raise -> raise "raw stream failure" end,
      fn _state -> :ok end
    )
  end
end
```

Create `test/image_plug/source_test.exs`:

```elixir
defmodule ImagePlug.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.SourceTest.CustomAdapter
  alias ImagePlug.SourceTest.InvalidAdapter
  alias ImagePlug.SourceTest.InvalidIdentityAdapter
  alias ImagePlug.SourceTest.RaisingAdapter
  alias ImagePlug.SourceTest.StreamWithCleanup

  test "validate_config calls adapter validation during init-time option normalization" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path, label: "root"}
               ]
             )

    assert_receive {:validate_options, [adapter: :path, label: "root"]}
    assert opts[:sources][:path] == {CustomAdapter, [adapter: :path, label: "root", validated: true]}
  end

  test "resolve dispatches by source shape and configured adapter key" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path}
               ]
             )

    source = %Path{segments: ["images", "cat.jpg"]}

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, request_id: "r1")
    assert resolved.adapter == :path
    assert resolved.source_kind == :path
    assert resolved.identity == [kind: :path, root: "test", path: ["images", "cat.jpg"]]
    assert resolved.cache == :normal

    assert_receive {:resolve, ^source, adapter_opts, [request_id: "r1"]}
    assert adapter_opts[:validated]
  end

  test "missing configured adapter fails before cache or fetch" do
    assert {:ok, opts} = Source.validate_config(sources: [])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :missing_adapter}}
  end

  test "malformed adapter callback results become source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "resolved identity must be primitive before cache or fetch can see it" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidIdentityAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "fetch dispatches through resolved adapter and wraps binary stream chunks" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {CustomAdapter, adapter: :path}])
    assert {:ok, resolved} = Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, opts, max_body_bytes: 20)

    assert Enum.to_list(response.stream) == ["image", " bytes"]
    assert_receive {:fetch, ^resolved, adapter_opts, [max_body_bytes: 20]}
    assert adapter_opts[:validated]
  end

  test "wrapped streams reject non-binary chunks" do
    response = %Response{stream: ["ok", :bad]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :invalid_stream_chunk
  end

  test "wrapped streams enforce max body bytes" do
    response = %Response{stream: ["123", "456"]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 5)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :body_too_large
  end

  test "wrapped streams keep adapter cleanup in enumerable termination path" do
    response = %Response{stream: StreamWithCleanup.stream(self(), ["123", "456"])}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    assert Enum.take(wrapped.stream, 1) == ["123"]
    assert_receive :stream_closed
  end

  test "wrapped streams sanitize upstream enumerable exceptions" do
    response = %Response{stream: StreamWithCleanup.raising_stream()}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :stream_exception
  end

  test "resolve and fetch catch adapter exceptions as sanitized source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {RaisingAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :adapter_exception}}

    resolved = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      cache: :normal,
      fetch: :raise
    }

    assert Source.fetch(resolved, opts, []) == {:error, {:source, :adapter_exception}}
  end
end
```

- [ ] **Step 2: Run failing source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected: failures for missing `ImagePlug.Source`, `ImagePlug.Source.Resolved`, and `ImagePlug.Source.Response`.

- [ ] **Step 3: Implement source registry and wrapper**

Create `ImagePlug.Source.Resolved`:

```elixir
defmodule ImagePlug.Source.Resolved do
  @moduledoc false

  @enforce_keys [:adapter, :source_kind, :identity, :cache, :fetch]
  defstruct @enforce_keys

  @type cache_policy :: :normal | :skip

  @type t :: %__MODULE__{
          adapter: atom(),
          source_kind: :path | :url | :object | :reference,
          identity: term(),
          cache: cache_policy(),
          fetch: term()
        }
end
```

Create `ImagePlug.Source.Response`:

```elixir
defmodule ImagePlug.Source.Response do
  @moduledoc false

  @enforce_keys [:stream]
  defstruct @enforce_keys

  @type t :: %__MODULE__{stream: Enumerable.t()}
end
```

Create `ImagePlug.Source.StreamError`:

```elixir
defmodule ImagePlug.Source.StreamError do
  @moduledoc false

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom()}

  def message(%__MODULE__{reason: reason}), do: "source stream failed: #{reason}"
end
```

Create `ImagePlug.Source` with:

```elixir
use Boundary,
  top_level?: true,
  deps: [ImagePlug.Plan, ImagePlug.Telemetry],
  exports: [
    Resolved,
    Response,
    StreamError,
    HTTP,
    File,
    S3
  ]

@callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}
@callback resolve(ImagePlug.Plan.Source.t(), keyword(), keyword()) ::
            {:ok, ImagePlug.Source.Resolved.t()} | {:error, error()}
@callback fetch(ImagePlug.Source.Resolved.t(), keyword(), keyword()) ::
            {:ok, ImagePlug.Source.Response.t()} | {:error, error()}

@type error :: {:source, atom() | tuple()}
```

Implement:

- `validate_config/1` accepts `sources: keyword()`, validates `{module, keyword()}` adapter entries, calls adapter `validate_options/1`, and returns opts with `:sources` as a map keyed by adapter atom.
- `resolve/3` dispatches `%Source.Path{}` to `:path`, `%Source.URL{scheme: :http}` to `:http`, `%Source.URL{scheme: :https}` to `:https`, `%Source.Object{adapter: adapter}` to that adapter, and `%Source.Reference{adapter: adapter}` to that adapter.
- `fetch/3` dispatches by `resolved.adapter`.
- malformed callback returns become `{:error, {:source, :invalid_adapter_result}}`.
- `resolve/3` validates every `%Resolved{}` before returning it. `adapter` must be an atom, `source_kind` must be one of `:path`, `:url`, `:object`, or `:reference`, `cache` must be `:normal` or `:skip`, and `identity` must be primitive deterministic key data. Invalid resolved data returns `{:error, {:source, :invalid_adapter_result}}` before cache lookup or fetch, including when `cache: :skip`.
- adapter exceptions from `validate_options/1`, `resolve/3`, and `fetch/3` become `{:error, {:source, :adapter_exception}}` inside the source span body.
- `wrap_response/2` returns `{:ok, %Response{stream: wrapped}}`; the wrapped stream yields only binaries. Deferred failures raise `%ImagePlug.Source.StreamError{reason: safe_reason}` during enumeration so tuples never reach `Image.open/2`.
- `wrap_response/2` enforces `:max_body_bytes`, rejects non-binary chunks, wraps adapter stream exceptions as `%StreamError{reason: :stream_exception}`, and never includes raw chunks or exception terms in error values.

The stream wrapper can be implemented as a `Stream.transform/3` wrapper over the adapter enumerable:

```elixir
defp wrap_stream(stream, max_body_bytes) do
  Stream.transform(
    stream,
    fn -> 0 end,
    fn chunk, size ->
      with {:ok, binary} <- validate_chunk(chunk),
           {:ok, new_size} <- add_size(size, binary, max_body_bytes) do
        {[binary], new_size}
      else
        {:error, reason} -> raise ImagePlug.Source.StreamError, reason: reason
      end
    end,
    fn _state -> :ok end
  )
end
```

If `Stream.transform/3` doesn't preserve cleanup and exception handling cleanly enough, use `Stream.resource/3` with `Enumerable.reduce/3`. The observable contract stays the same: the stream yields binaries only and raises `%StreamError{}` for deferred source failures.

- [ ] **Step 4: Wire source config validation into request options**

Modify `ImagePlug.Request.Options.validate!/1`:

```elixir
opts
|> Cache.validate_config!()
|> Source.validate_config!()
|> validate_known_opts!()
```

Keep `:root_url` accepted only inside this task so the existing test suite can still run before the request flow is moved. Task 7 removes it from the validated public options and updates tests to configure `sources:` explicitly.

- [ ] **Step 5: Run source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs test/image_plug/request_options_test.exs
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib/image_plug/source.ex lib/image_plug/source/resolved.ex lib/image_plug/source/response.ex lib/image_plug/source/stream_error.ex lib/image_plug/request/options.ex test/image_plug/source_test.exs test/support/image_plug/source_test/custom_adapter.ex test/support/image_plug/source_test/invalid_adapter.ex test/support/image_plug/source_test/invalid_identity_adapter.ex test/support/image_plug/source_test/raising_adapter.ex test/support/image_plug/source_test/stream_with_cleanup.ex
mise exec -- git commit -m "Add source registry and stream wrapper"
```

---

## Task 3: Cache Key Uses Resolved Source Identity

**Files:**

- Modify: `lib/image_plug/cache.ex`
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Modify: `test/image_plug/cache_test.exs`

- [ ] **Step 1: Write failing cache key tests**

In `test/image_plug/cache/key_test.exs`, change `build_key!/4` to pass a source identity term instead of a binary origin identity:

```elixir
defp source_identity do
  [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]
end

defp build_key!(conn, plan, source_identity, opts \\ []) do
  assert {:ok, key} = Key.build(conn, plan, source_identity, opts)
  key
end
```

Update the first cache key test to assert:

```elixir
assert key.data[:source_identity] == source_identity()
refute Keyword.has_key?(key.data, :origin_identity)
```

Add a test:

```elixir
test "resolved source identity, not raw plan source spelling, drives source cache material" do
  conn_one = conn(:get, "/sig-one/plain/images/cat.jpg")
  conn_two = conn(:get, "/sig-two/plain/local:///images/cat.jpg")

  identity = [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

  key_one = build_key!(conn_one, plan(source: %ImagePlug.Plan.Source.Path{segments: ["images", "cat.jpg"]}), identity)
  key_two = build_key!(conn_two, plan(source: %ImagePlug.Plan.Source.Path{segments: ["images", "cat.jpg"]}), identity)

  assert key_one.hash == key_two.hash
  assert key_one.data[:source_identity] == identity
end
```

Add a test:

```elixir
test "source identity rejects non-primitive cache material" do
  conn = conn(:get, "/_/plain/images/cat.jpg")
  identity = [kind: :path, client: self()]

  assert Key.build(conn, plan(), identity) == {:error, {:invalid_source_identity, identity}}
end
```

- [ ] **Step 2: Run failing cache key tests**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs
```

Expected: failures because `Key.build/4` still expects a binary origin identity and serializes `:origin_identity`.

- [ ] **Step 3: Implement source identity key material**

Change `ImagePlug.Cache.Key.build/4`:

```elixir
@spec build(Plug.Conn.t(), Plan.t(), term(), keyword()) ::
        {:ok, t()} | {:error, term()}
def build(conn, %Plan{} = plan, source_identity, opts \\ []) when is_list(opts) do
  with :ok <- validate_source_identity(source_identity),
       {:ok, pipelines} <- pipelines_data(plan.pipelines),
       {:ok, output} <- output_data(conn, plan.output, opts),
       {:ok, cache} <- cache_data(plan.cachebuster) do
    data = [
      schema_version: @schema_version,
      source_identity: source_identity,
      pipelines: pipelines,
      transform: transform_data(),
      output: output,
      cache: cache,
      selected_headers: selected_headers(conn, opts),
      selected_cookies: selected_cookies(conn, opts)
    ]

    serialized_data = serialize_key_data(data)
    {:ok, %__MODULE__{hash: hash(serialized_data), data: data, serialized_data: serialized_data}}
  end
end
```

Remove `source_data/1`. Add primitive validation:

```elixir
defp validate_source_identity(identity) do
  if primitive_key_data?(identity), do: :ok, else: {:error, {:invalid_source_identity, identity}}
end

defp primitive_key_data?(value)
     when is_binary(value) or is_atom(value) or is_integer(value) or is_float(value) or
            is_boolean(value) or is_nil(value),
     do: true

defp primitive_key_data?(value) when is_list(value) do
  if Keyword.keyword?(value) do
    Enum.all?(value, fn {key, item} -> is_atom(key) and primitive_key_data?(item) end)
  else
    Enum.all?(value, &primitive_key_data?/1)
  end
end

defp primitive_key_data?(value) when is_tuple(value),
  do: value |> Tuple.to_list() |> Enum.all?(&primitive_key_data?/1)

defp primitive_key_data?(value) when is_map(value) and not is_struct(value) do
  Enum.all?(value, fn {key, item} -> primitive_key_data?(key) and primitive_key_data?(item) end)
end

defp primitive_key_data?(_value), do: false
```

Change `ImagePlug.Cache.lookup/4` to accept `source_identity` and pass it to `Key.build/4`.

- [ ] **Step 4: Run cache tests**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/cache_test.exs
```

Expected: pass after updating assertions from `origin_identity` to `source_identity`.

- [ ] **Step 5: Commit**

```bash
mise exec -- git add lib/image_plug/cache.ex lib/image_plug/cache/key.ex test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/cache_test.exs
mise exec -- git commit -m "Use resolved source identity in cache keys"
```

---

## Task 4: Imgproxy Source Translation

**Files:**

- Create: `lib/image_plug/parser/imgproxy/source.ex`
- Create: `lib/image_plug/parser/imgproxy/source_scheme.ex`
- Create: `test/parser/imgproxy/source_test.exs`
- Modify: `lib/image_plug/parser/imgproxy.ex`
- Modify: `lib/image_plug/parser/imgproxy/path.ex`
- Modify: `lib/image_plug/parser/imgproxy/plan_builder.ex`
- Modify: `lib/image_plug/parser/imgproxy/parsed_request.ex`
- Modify: `test/parser/imgproxy/path_test.exs`
- Modify: `test/parser/imgproxy/plan_builder_test.exs`
- Modify: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write failing imgproxy source translation tests**

Create `test/parser/imgproxy/source_test.exs`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy.Source
  alias ImagePlug.Plan.Source.Object
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Plan.Source.URL

  defmodule FoobarTranslator do
    @behaviour ImagePlug.Parser.Imgproxy.SourceScheme

    @impl true
    def translate(source, opts) do
      send(self(), {:translate, source, opts})
      {:ok, %Object{adapter: :foobar, scope: "scope", key: source, revision: "r1"}}
    end
  end

  test "plain path translates to path source" do
    assert Source.translate("images/cat.jpg", []) ==
             {:ok, %Path{segments: ["images", "cat.jpg"]}}
  end

  test "local scheme translates to the same path source shape as plain path" do
    assert Source.translate("local:///images/cat.jpg", []) ==
             {:ok, %Path{segments: ["images", "cat.jpg"]}}
  end

  test "http and https translate to url source" do
    assert Source.translate("https://assets.example.com/images/cat.jpg?v=1", []) ==
             {:ok,
              %URL{
                scheme: :https,
                host: "assets.example.com",
                port: nil,
                path: ["images", "cat.jpg"],
                query: "v=1"
              }}

    assert Source.translate("http://assets.example.com:8080/cat.jpg", []) ==
             {:ok,
              %URL{
                scheme: :http,
                host: "assets.example.com",
                port: 8080,
                path: ["cat.jpg"],
                query: nil
              }}
  end

  test "url sources normalize mixed-case hosts before identity resolution" do
    assert Source.translate("https://Assets.Example.Com/cat.jpg", []) ==
             {:ok,
              %URL{
                scheme: :https,
                host: "assets.example.com",
                port: nil,
                path: ["cat.jpg"],
                query: nil
              }}
  end

  test "s3 translates URI host and path to object source with raw query as revision" do
    assert Source.translate("s3://bucket/images/cat.jpg?abc", []) ==
             {:ok, %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "abc"}}

    assert Source.translate("s3://bucket/images/cat.jpg%3Fabc", []) ==
             {:ok, %Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: "abc"}}

    assert Source.translate("s3://bucket/images/cat.jpg?version=abc", []) ==
             {:ok,
              %Object{
                adapter: :s3,
                scope: "bucket",
                key: "images/cat.jpg",
                revision: "version=abc"
              }}
  end

  test "object and local keys decode escaped reserved characters after URI structure is parsed" do
    assert Source.translate("s3://bucket/images/cat%23one%25two.jpg?abc", []) ==
             {:ok,
              %Object{
                adapter: :s3,
                scope: "bucket",
                key: "images/cat#one%two.jpg",
                revision: "abc"
              }}

    assert Source.translate("local:///images/cat%23one%25two.jpg", []) ==
             {:ok, %Path{segments: ["images", "cat#one%two.jpg"]}}
  end

  test "unknown schemes fail unless configured with a binary-keyed translator map" do
    assert Source.translate("foobar://thing/cat.jpg", []) ==
             {:error, {:unsupported_source_scheme, "foobar"}}

    assert Source.translate("foobar://thing/cat.jpg",
             source_schemes: %{"foobar" => {FoobarTranslator, color: "blue"}}
           ) ==
             {:ok, %Object{adapter: :foobar, scope: "scope", key: "foobar://thing/cat.jpg", revision: "r1"}}

    assert_receive {:translate, "foobar://thing/cat.jpg", [color: "blue"]}
  end

  test "custom translator errors are normalized before parser error responses inspect them" do
    defmodule FailingTranslator do
      @behaviour ImagePlug.Parser.Imgproxy.SourceScheme

      @impl true
      def translate(_source, _opts), do: {:error, {:secret_path, "/private/cat.jpg"}}
    end

    assert Source.translate("foobar://thing/cat.jpg",
             source_schemes: %{"foobar" => {FailingTranslator, []}}
           ) == {:error, {:source_scheme_error, "foobar"}}
  end
end
```

Add an integration assertion in `test/parser/imgproxy_test.exs`:

```elixir
test "parses escaped embedded s3 query before output suffix handling" do
  assert {:ok, %ImagePlug.Plan{source: source, output: output}} =
           Imgproxy.parse(conn(:get, "/_/plain/s3://bucket/images/cat.jpg%3Fabc@webp"), opts())

  assert source == %ImagePlug.Plan.Source.Object{
           adapter: :s3,
           scope: "bucket",
           key: "images/cat.jpg",
           revision: "abc"
         }

  assert output.mode == {:explicit, :webp}
end
```

- [ ] **Step 2: Run failing parser tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/source_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs test/parser/imgproxy/plan_builder_test.exs
```

Expected: failures for missing source translator and plan builder still returning `{:plain, path}`.

- [ ] **Step 3: Implement translator behaviour and source translation**

Create `ImagePlug.Parser.Imgproxy.SourceScheme`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.SourceScheme do
  @moduledoc """
  Parser extension for custom imgproxy source schemes.
  """

  @callback translate(source :: String.t(), opts :: keyword()) ::
              {:ok, ImagePlug.Plan.Source.t()} | {:error, term()}
end
```

Create `ImagePlug.Parser.Imgproxy.Source`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.Source do
  @moduledoc false

  alias ImagePlug.Plan.Source.Object
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Plan.Source.URL

  @spec translate(String.t(), keyword()) :: {:ok, ImagePlug.Plan.Source.t()} | {:error, term()}
  def translate(source, opts) when is_binary(source) do
    case URI.parse(source) do
      %URI{scheme: nil} -> path_source(source)
      %URI{scheme: "local"} = uri -> local_source(uri)
      %URI{scheme: scheme} = uri when scheme in ["http", "https"] -> url_source(uri)
      %URI{scheme: "s3"} = uri -> s3_source(uri)
      %URI{scheme: scheme} -> custom_source(scheme, source, opts)
    end
  end
end
```

Implement helper clauses:

- `path_source/1` splits the raw source string on `/`, decodes URI escapes in each segment, and returns `%Path{segments: segments}`.
- `local_source/1` rejects non-empty host, query, or fragment, trims the leading slash, and decodes URI escapes in path segments after URI structure is parsed.
- `url_source/1` maps scheme to atom, explicitly normalizes the host with `String.downcase/1`, keeps port, decodes URI escapes in path segments after URI structure is parsed, and keeps query.
- `s3_source/1` maps `host` to `scope`, decodes URI escapes in path segments after URI structure is parsed, joins them into `key`, and maps query to `revision`.
- `custom_source/3` reads `opts[:source_schemes]`, requires binary map keys, calls translator `translate/2`, and normalizes translator failures to `{:error, {:source_scheme_error, scheme}}` so the default parser error body doesn't inspect host-provided error terms.

`Path.parse_plain_source/1` must split `@format` and validate malformed URI escapes without decoding the whole source identifier first. It passes the raw embedded source string, such as `s3://bucket/images/cat%23one.jpg%3Fabc`, into `ImgproxySource.translate/2`. Built-in translators first split the source query separator in raw or escaped form (`?` or `%3F`), then parse URI structure, then decode URI escapes in path or key segments. That keeps escaped `#` and escaped literal escape bytes in filenames from becoming URI fragment or invalid escape syntax before bucket/key extraction.

Modify the imgproxy options schema:

```elixir
source_schemes: [
  type: {:custom, __MODULE__, :validate_source_schemes, []},
  default: %{}
]
```

Add:

```elixir
def validate_source_schemes(%{} = schemes) do
  if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
    {:ok, schemes}
  else
    {:error, "expected a map from binary scheme names to {module, keyword_options}"}
  end
end

def validate_source_schemes(_schemes),
  do: {:error, "expected a map from binary scheme names to {module, keyword_options}"}
```

- [ ] **Step 4: Modify PlanBuilder source handling and filenames**

Replace `source_plan/2` with:

```elixir
alias ImagePlug.Parser.Imgproxy.Source, as: ImgproxySource
alias ImagePlug.Plan.Source.{Object, Path, Reference, URL}

defp source_plan(:plain, source_identifier, opts),
  do: ImgproxySource.translate(source_identifier, Keyword.get(opts, :imgproxy, []))

defp source_plan(kind, _source_identifier, _opts), do: {:error, {:unsupported_source_kind, kind}}
```

Make `to_plan/2` call `source_plan(request.source_kind, request.source_path, opts)`.

Change `response_plan/2` to derive the default filename from typed source structs:

```elixir
defp response_plan(%ResponseRequest{filename: nil, disposition: disposition}, source) do
  {:ok, %Response{filename: source_filename(source), disposition: disposition}}
end

defp source_filename(%Path{segments: segments}), do: filename_from_segments(segments)
defp source_filename(%URL{path: path}), do: filename_from_segments(path)
defp source_filename(%Object{key: key}), do: key |> String.split("/", trim: true) |> filename_from_segments()
defp source_filename(%Reference{id: id}), do: valid_source_filename(id)
```

- [ ] **Step 5: Run parser tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/source_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs test/parser/imgproxy/plan_builder_test.exs
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/path.ex lib/image_plug/parser/imgproxy/plan_builder.ex lib/image_plug/parser/imgproxy/parsed_request.ex lib/image_plug/parser/imgproxy/source.ex lib/image_plug/parser/imgproxy/source_scheme.ex test/parser/imgproxy/source_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/path_test.exs test/parser/imgproxy/plan_builder_test.exs
mise exec -- git commit -m "Translate imgproxy sources into plan source structs"
```

---

## Task 5: HTTP And File Source Adapters

**Files:**

- Create: `lib/image_plug/source/http.ex`
- Create: `lib/image_plug/source/file.ex`
- Create: `test/image_plug/source/http_test.exs`
- Create: `test/image_plug/source/file_test.exs`
- Modify: `lib/image_plug/source.ex`

- [ ] **Step 1: Write failing HTTP adapter tests**

Create `test/image_plug/source/http_test.exs`:

```elixir
defmodule ImagePlug.Source.HTTPTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Plan.Source.URL
  alias ImagePlug.Source
  alias ImagePlug.Source.HTTP
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  test "resolve normalizes URL identity and enforces allowed hosts" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{scheme: :https, host: "assets.example.com", port: nil, path: ["images", "cat.jpg"], query: "v=1"}

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.adapter == :https
    assert resolved.source_kind == :url
    assert resolved.identity == [
             kind: :url,
             adapter: :https,
             scheme: :https,
             host: "assets.example.com",
             port: 443,
             path: ["images", "cat.jpg"],
             query: "v=1"
           ]

    denied = %URL{source | host: "evil.example"}
    assert HTTP.resolve(denied, opts, []) == {:error, {:source, :denied_host}}
  end

  test "resolve lowercases URL hosts before allowed-host checks and cache identity" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{scheme: :https, host: "Assets.Example.Com", port: nil, path: ["cat.jpg"], query: nil}

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.identity[:host] == "assets.example.com"
  end

  test "fetch creates a Req-backed lazy stream and preserves safe request options" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end
    source = %URL{scheme: :https, host: "assets.example.com", port: nil, path: ["cat.jpg"], query: nil}

    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"], req_options: [plug: plug])
    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, sources: %{https: {HTTP, opts}}, max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
  end

  test "non-success statuses and transport failures are deferred safe stream errors" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end
    source = %URL{scheme: :https, host: "assets.example.com", port: nil, path: ["missing.jpg"], query: nil}

    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"], req_options: [plug: plug])
    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, sources: %{https: {HTTP, opts}}, max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end

  test "redirects cannot bypass allowed host policy" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://evil.example/cat.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    source = %URL{scheme: :https, host: "assets.example.com", port: nil, path: ["redirect.jpg"], query: nil}

    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"], req_options: [plug: plug])
    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, sources: %{https: {HTTP, opts}}, [])

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end
end
```

- [ ] **Step 2: Write failing file adapter tests**

Create `test/image_plug/source/file_test.exs`:

```elixir
defmodule ImagePlug.Source.FileTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Source.File
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  setup do
    tmp = Path.join(System.tmp_dir!(), "image-plug-file-source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "images"))
    File.write!(Path.join(tmp, "images/cat.jpg"), "image bytes")
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, root: tmp}
  end

  test "resolve keeps absolute root path out of identity", %{root: root} do
    assert {:ok, opts} = File.validate_options(root: root, root_id: "fixture-root")

    assert {:ok, %Resolved{} = resolved} =
             File.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])

    assert resolved.identity == [
             kind: :path,
             adapter: :path,
             root: "fixture-root",
             path: ["images", "cat.jpg"]
           ]

    refute inspect(resolved.identity) =~ root
  end

  test "resolve rejects traversal before fetch", %{root: root} do
    assert {:ok, opts} = File.validate_options(root: root, root_id: "fixture-root")

    assert File.resolve(%Path{segments: ["..", "secret.jpg"]}, opts, []) ==
             {:error, {:source, :denied_path}}
  end

  test "resolve rejects symlinks that escape the configured root", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "image-plug-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.jpg"), "secret")
    File.ln_s!(outside, Path.join(root, "images/outside"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, opts} = File.validate_options(root: root, root_id: "fixture-root")

    assert File.resolve(%Path{segments: ["images", "outside", "secret.jpg"]}, opts, []) ==
             {:error, {:source, :denied_path}}
  end

  test "fetch streams regular file bytes", %{root: root} do
    assert {:ok, opts} = File.validate_options(root: root, root_id: "fixture-root")
    assert {:ok, resolved} = File.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    assert {:ok, %Response{} = response} = File.fetch(resolved, opts, max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
  end

  test "fetch returns safe source errors for missing files", %{root: root} do
    assert {:ok, opts} = File.validate_options(root: root, root_id: "fixture-root")
    assert {:ok, resolved} = File.resolve(%Path{segments: ["images", "missing.jpg"]}, opts, [])

    assert File.fetch(resolved, opts, []) == {:error, {:source, :not_found}}
  end
end
```

- [ ] **Step 3: Run failing adapter tests**

Run:

```bash
mise exec -- mix test test/image_plug/source/http_test.exs test/image_plug/source/file_test.exs
```

Expected: missing adapter modules.

- [ ] **Step 4: Implement HTTP adapter**

Implement `ImagePlug.Source.HTTP` with:

- `validate_options/1` using NimbleOptions for `:allowed_hosts`, `:req_options`, `:receive_timeout`, `:connect_timeout`, `:pool_timeout`, and `:max_redirects`.
- `resolve/3` requiring `%Source.URL{scheme: :http | :https}`, converting host names to lowercase with `String.downcase/1`, enforcing `allowed_hosts`, normalizing default ports to `80` or `443`, building URL string for `fetch`, and using source adapter key equal to scheme.
- `fetch/3` returning `%Source.Response{stream: req_stream(url, opts, runtime_opts)}` and relying on `ImagePlug.Source.wrap_response/2` through registry dispatch.
- redirect handling must either be disabled or each redirect target must pass the same normalized host policy before a redirected request is sent. The first slice should disable redirects until redirect-target validation has tests.
- Req options must delete caller overrides for `:url`, `:into`, `:retry`, and unsafe asynchronous response options before merging safe request fields.

- [ ] **Step 5: Implement file adapter**

Implement `ImagePlug.Source.File` with:

- `validate_options/1` requiring `:root` and `:root_id`.
- `resolve/3` rejecting traversal and absolute-looking segments with `Path.safe_relative/2`, building an absolute path under root, and keeping only `root_id` and path segments in identity.
- `fetch/3` requiring a regular file, using `File.stream!(path, [], 2048)` for streaming, returning `{:error, {:source, :not_found}}` for missing files and `{:error, {:source, :unreadable}}` for non-regular or unreadable files.
- `Path.safe_relative/2` must run against the configured root so symlink traversal above the root fails before fetch. Don't replace it with a lexical `Path.expand/1` prefix check.

- [ ] **Step 6: Run adapter tests**

Run:

```bash
mise exec -- mix test test/image_plug/source/http_test.exs test/image_plug/source/file_test.exs test/image_plug/source_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
mise exec -- git add lib/image_plug/source.ex lib/image_plug/source/http.ex lib/image_plug/source/file.ex test/image_plug/source/http_test.exs test/image_plug/source/file_test.exs
mise exec -- git commit -m "Add HTTP and file source adapters"
```

---

## Task 6: S3 Source Adapter

**Files:**

- Create: `lib/image_plug/source/s3.ex`
- Create: `lib/image_plug/source/s3/credentials.ex`
- Create: `test/image_plug/source/s3_test.exs`
- Create: `test/support/image_plug/source_test/credential_provider.ex`
- Modify: `lib/image_plug/source.ex`

- [ ] **Step 1: Write failing S3 tests**

Create `test/support/image_plug/source_test/credential_provider.ex`:

```elixir
defmodule ImagePlug.SourceTest.CredentialProvider do
  @moduledoc false

  def fetch_credentials(scope, provider_opts, runtime_opts) do
    send(self(), {:fetch_credentials, scope, provider_opts, runtime_opts})

    {:ok,
     [
       access_key_id: "AKIA_TEST",
       secret_access_key: "SECRET_TEST",
       token: "TOKEN_TEST"
     ]}
  end
end
```

Create `test/image_plug/source/s3_test.exs`:

```elixir
defmodule ImagePlug.Source.S3Test do
  use ExUnit.Case, async: false

  alias ImagePlug.Plan.Source.Object
  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.Source.S3
  alias ImagePlug.SourceTest.CredentialProvider

  test "per-bucket config overrides defaults and identity includes endpoint bucket key revision" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ],
               buckets: %{
                 "tenant-a" => [
                   region: "eu-west-1",
                   endpoint: "https://s3.eu-west-1.amazonaws.com"
                 ]
               }
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg", revision: "abc"}

    assert {:ok, %Resolved{} = resolved} = S3.resolve(source, opts, [])
    assert resolved.adapter == :s3
    assert resolved.source_kind == :object
    assert resolved.identity == [
             kind: :object,
             adapter: :s3,
             endpoint: "https://s3.eu-west-1.amazonaws.com",
             bucket: "tenant-a",
             key: "images/cat.jpg",
             revision: "abc"
           ]

    refute inspect(resolved.identity) =~ "AKIA"
    refute_received {:fetch_credentials, _, _, _}
  end

  test "bucket map fails closed for unlisted buckets" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ],
               buckets: %{"tenant-a" => []}
             )

    assert S3.resolve(%Object{adapter: :s3, scope: "tenant-b", key: "cat.jpg"}, opts, []) ==
             {:error, {:source, :denied_bucket}}
  end

  test "per-bucket credential providers are selected by exact bucket only during fetch" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 req_options: [plug: plug]
               ],
               buckets: %{
                 "tenant-a" => [credentials: {:provider, CredentialProvider, role: "tenant-a"}],
                 "tenant-b" => [credentials: {:provider, CredentialProvider, role: "tenant-b"}]
               }
             )

    assert {:ok, resolved} =
             S3.resolve(%Object{adapter: :s3, scope: "tenant-b", key: "images/cat.jpg"}, opts, [])

    refute_received {:fetch_credentials, _, _, _}

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, sources: %{s3: {S3, opts}}, max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:fetch_credentials, "tenant-b", [role: "tenant-b"], [max_body_bytes: 20]}
    refute_received {:fetch_credentials, "tenant-a", _, _}
  end

  test "invalid credential configuration fails during option validation" do
    assert {:error, {:invalid_source_config, _reason}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A"}
               ]
             )

    assert {:error, {:invalid_source_config, _reason}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:provider, NotLoadedProvider, []}
               ]
             )
  end

  test "fetch calls credential provider only on cache miss" do
    plug = fn conn ->
      send(self(), {:s3_request, conn.req_headers, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 credentials: {:provider, CredentialProvider, role: "tenant-a"},
                 req_options: [plug: plug]
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg", revision: "abc"}

    assert {:ok, resolved} = S3.resolve(source, opts, [])
    refute_received {:fetch_credentials, _, _, _}

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, sources: %{s3: {S3, opts}}, max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:fetch_credentials, "tenant-a", [role: "tenant-a"], [max_body_bytes: 20]}
    assert_receive {:s3_request, headers, "/tenant-a/images/cat.jpg", "versionId=abc"}
    assert {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization =~ "AWS4-HMAC-SHA256"
    assert authorization =~ "/us-east-1/s3/aws4_request"
    assert {"x-amz-security-token", "TOKEN_TEST"} = List.keyfind(headers, "x-amz-security-token", 0)
  end

  test "signed fetches do not follow redirects" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://other.example/tenant-a/cat.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 req_options: [plug: plug]
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "cat.jpg"}
    assert {:ok, resolved} = S3.resolve(source, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, sources: %{s3: {S3, opts}}, [])

    error = assert_raise Source.StreamError, fn -> Enum.to_list(response.stream) end
    assert error.reason == :bad_status
  end

  test "credential failures are safe source errors" do
    defmodule FailingProvider do
      def fetch_credentials(_scope, _provider_opts, _runtime_opts),
        do: {:error, {:source, :credentials_unavailable}}
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:provider, FailingProvider, []}
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg"}
    assert {:ok, resolved} = S3.resolve(source, opts, [])
    assert S3.fetch(resolved, opts, []) == {:error, {:source, :credentials_unavailable}}
  end
end
```

- [ ] **Step 2: Run failing S3 tests**

Run:

```bash
mise exec -- mix test test/image_plug/source/s3_test.exs
```

Expected: missing S3 modules.

- [ ] **Step 3: Implement S3 config and resolution**

Implement `ImagePlug.Source.S3`:

- `validate_options/1` validates `default: keyword()` and optional `buckets: map()`.
- accepted bucket fields: `:region`, `:endpoint`, `:credentials`, `:req_options`, `:addressing`.
- if `buckets` is present, only exact listed bucket names resolve.
- without `buckets`, `default` applies to every bucket.
- bucket config is `Keyword.merge(default, bucket_config)`.
- `resolve/3` validates `%Source.Object{adapter: :s3}`, bucket/scope string, non-empty key, optional binary revision.
- identity is `[kind: :object, adapter: :s3, endpoint: endpoint, bucket: scope, key: key, revision: revision]`.
- fetch payload stores URL, bucket, key, revision, region, credential reference, and sanitized request options.
- `resolve/3` must not call credential providers.

- [ ] **Step 4: Implement credentials helper and fetch**

Implement `ImagePlug.Source.S3.Credentials`:

```elixir
@spec fetch(String.t(), term(), keyword()) ::
        {:ok, keyword()} | {:error, ImagePlug.Source.error()}
def fetch(_scope, {:static, static_opts}, _runtime_opts), do: validate_static(static_opts)
def fetch(scope, {:provider, provider, provider_opts}, runtime_opts),
  do: provider.fetch_credentials(scope, provider_opts, runtime_opts)
```

Normalize credential results to require `:access_key_id` and `:secret_access_key`, allow `:token`, and reject malformed provider results with `{:error, {:source, :credentials_unavailable}}`.

Implement S3 `fetch/3`:

- validate static credentials and provider tuple shape during `validate_options/1`; call credential providers inside `fetch/3` only.
- build a Req GET URL from endpoint, bucket, key, and optional `versionId=revision`.
- pass SigV4 options with `aws_sigv4: [service: :s3, region: region, access_key_id: ..., secret_access_key: ..., token: ...]` or the exact Req 0.5 option shape verified from local dependency docs.
- turn redirects off for signed fetches unless tests prove same-host redirect handling is safe.
- return `%Source.Response{stream: req_stream}` and rely on registry wrapping.

- [ ] **Step 5: Run S3 tests**

Run:

```bash
mise exec -- mix test test/image_plug/source/s3_test.exs test/image_plug/source_test.exs
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib/image_plug/source.ex lib/image_plug/source/s3.ex lib/image_plug/source/s3/credentials.ex test/image_plug/source/s3_test.exs test/support/image_plug/source_test/credential_provider.ex
mise exec -- git commit -m "Add S3 source adapter"
```

---

## Task 7: Request Flow Integration

**Files:**

- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/request/options.ex`
- Modify: `lib/image_plug/request/runner.ex`
- Modify: `lib/image_plug/request/processor.ex`
- Modify: `lib/image_plug/response/sender.ex`
- Delete: `lib/image_plug/origin/identity.ex`
- Delete: `lib/image_plug/origin/decoded.ex`
- Create: `test/support/image_plug/source_test/valid_adapter.ex`
- Modify: `test/image_plug/request_safety_test.exs`
- Modify: `test/image_plug/processor_test.exs`
- Modify: `test/image_plug/request_runner_test.exs`
- Modify: `test/image_plug_test.exs`
- Modify: `test/image_plug/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Write failing request ordering tests**

In `test/image_plug/request_safety_test.exs`, replace origin-specific doubles with source doubles and add:

```elixir
defmodule DenyingSourceAdapter do
  @behaviour ImagePlug.Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(_source, _opts, _runtime_opts) do
    send(self(), :source_resolve)
    {:error, {:source, :denied_path}}
  end

  @impl true
  def fetch(_resolved, _opts, _runtime_opts) do
    raise "source should not fetch"
  end
end

```

Create `test/support/image_plug/source_test/valid_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.ValidAdapter do
  @moduledoc false

  @behaviour ImagePlug.Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(source, opts, _runtime_opts) do
    send(self(), {:source_resolve, source})

    {:ok,
     %ImagePlug.Source.Resolved{
       adapter: Keyword.get(opts, :adapter, :path),
       source_kind: :path,
       identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: :fixture
     }}
  end

  @impl true
  def fetch(resolved, _opts, _runtime_opts) do
    send(self(), {:source_fetch, resolved.fetch})
    {:ok, %ImagePlug.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end
end
```

Add:

```elixir
test "invalid pipeline plans return before source resolution" do
  conn =
    ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
      parser: InvalidPipelinePlanParser,
      sources: [path: {ImagePlug.SourceTest.ValidAdapter, []}],
      cache: {CacheProbe, []}
    )

  assert conn.status == 422
  assert conn.resp_body == "invalid image transform"
  refute_received {:source_resolve, _source}
  refute_received {:source_fetch, _fetch}
  refute_received :cache_lookup
  refute_received :cache_put
end

test "source resolution failures return before cache lookup and fetch" do
  conn =
    ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
      parser: ImagePlug.Parser.Imgproxy,
      sources: [path: {DenyingSourceAdapter, []}],
      cache: {CacheProbe, []}
    )

  assert conn.status == 422
  assert conn.resp_body == "invalid image source"
  assert_received :source_resolve
  refute_received {:source_fetch, _fetch}
  refute_received :cache_lookup
  refute_received :cache_put
end
```

In `test/image_plug/request_runner_test.exs`, add a cache skip test:

```elixir
defmodule CacheSkipProbe do
  def get(_key, _opts) do
    send(self(), :cache_lookup)
    :miss
  end

  def put(_key, _entry, _opts) do
    send(self(), :cache_put)
    :ok
  end
end

test "cache skip bypasses cache lookup and cache write before fetching source" do
  resolved = %ImagePlug.Source.Resolved{
    adapter: :path,
    source_kind: :path,
    identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
    cache: :skip,
    fetch: :fixture
  }

  assert {:ok, {:image, _state, _output, _response}} =
             Runner.run(conn(:get, "/_/plain/images/cat.jpg"), plan(), resolved,
             cache: {CacheSkipProbe, []},
             sources: [path: {ImagePlug.SourceTest.ValidAdapter, []}],
             image_open_module: ImagePlug.Request.ProcessorTest.DecodeValidImageOpen
           )

  refute_received :cache_lookup
  refute_received :cache_put
  assert_received {:source_fetch, :fixture}
end
```

- [ ] **Step 2: Run failing request tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs
```

Expected: failures because `ImagePlug` still resolves origin identity and `Runner.run/4` expects a binary origin identity.

- [ ] **Step 3: Change `ImagePlug.call/2` to source resolution**

Modify `ImagePlug`:

- replace `ImagePlug.Origin` dependency with `ImagePlug.Source`.
- after parser, plan shape validation, and transform-safety validation, call `Source.resolve(plan.source, opts, source_runtime_opts(opts))`.
- route `{:error, {:source, reason}}` through `Sender.send_source_error/2`.
- use source telemetry spans inside `ImagePlug.Source.resolve/3`, not in `ImagePlug`.
- remove `resolve_origin_identity/2`.

The success path becomes:

```elixir
with {:ok, %Plan{} = plan} <- parse(conn, parser, opts),
     {:ok, %Plan{} = plan} <- validate_client_plan(plan),
     {:ok, %Source.Resolved{} = resolved_source} <- Source.resolve(plan.source, opts, source_runtime_opts(opts)) do
  result = Runner.run(conn, plan, resolved_source, opts)
  ...
end
```

- [ ] **Step 4: Change runner cache/fetch ordering**

Modify `ImagePlug.Request.Runner.run/4` to accept `%Source.Resolved{}`:

```elixir
@spec run(Plug.Conn.t(), Plan.t(), Source.Resolved.t(), keyword()) ::
        {:ok, delivery()} | {:error, error()}
def run(conn, %Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
  with :ok <- validate_cache_config(opts) do
    run_with_cache_config(conn, plan, resolved_source, opts)
  else
    {:error, {:cache, reason}} -> {:error, {:cache, reason}}
    {:error, reason} -> {:error, {:processing, reason, []}}
  end
end
```

`Runner.run/4` must not be the first transform-safety validation point. The top-level plug validates transform safety before source resolution; direct internal callers are trusted to pass a validated plan.

Branch on cache policy before lookup:

```elixir
defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :skip} = resolved_source, opts),
  do: process_uncached(conn, plan, resolved_source, opts)

defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :normal} = resolved_source, opts) do
  ...
  Cache.lookup(conn, plan, resolved_source.identity, opts)
end
```

Pass `%Source.Resolved{}` to `process_request/4` and cache miss handling. Cache writes only happen for `cache: :normal`.

- [ ] **Step 5: Change processor fetch/decode ownership**

Modify `ImagePlug.Request.Processor`:

- remove `alias ImagePlug.Origin`.
- keep decoded source state in a private `%Decoded{}` module under `ImagePlug.Request.Processor.Decoded`; don't create a new public decoded source module unless another module needs the type.
- replace `fetch_origin/3` with `fetch_source/3`.
- call `Source.fetch(resolved_source, opts, source_runtime_opts(opts))`.
- keep `DecodePlanner.open_options/1`, decode, input pixel validation, and source format detection in processor.

The first fetch/decode function should become:

```elixir
@spec fetch_decode_validate_source_with_source_format(Plan.t(), Source.Resolved.t(), keyword()) ::
        {:ok, Decoded.t()} | {:error, term()}
def fetch_decode_validate_source_with_source_format(%Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
  result =
    with {:ok, %Source.Response{} = source_response} <- Source.fetch(resolved_source, opts, source_runtime_opts(opts)) do
      decode_validate_source_response(source_response, plan, opts)
    end

  result
end
```

Wrap only `%ImagePlug.Source.StreamError{}` from decoder enumeration and convert it to `{:error, {:source, reason}}` before normal decode-error wrapping:

```elixir
defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
  image_open_module = Keyword.get(opts, :image_open_module, Image)

  image_open_module.open(source_response.stream, decode_options)
rescue
  exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
end
```

Don't add a source span around decode. Source fetch telemetry covers stream creation only.

- [ ] **Step 6: Add response sender support for source errors**

Modify `ImagePlug.Response.Sender`:

```elixir
def send_source_error(%Plug.Conn{} = conn, _reason) do
  conn
  |> Plug.Conn.put_resp_content_type("text/plain")
  |> Plug.Conn.send_resp(422, "invalid image source")
end
```

Ensure default source error responses never inspect full source URLs, paths, buckets, credentials, signed headers, or raw adapter errors.

- [ ] **Step 7: Run request tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs test/image_plug_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: pass after updating tests to configure file-backed path sources:

```elixir
sources: [
  path: {ImagePlug.Source.File, root: fixture_root, root_id: "fixture"}
]
```

For tests that need absolute HTTP URL sources, use imgproxy paths such as `/_/plain/http://origin.test/images/cat.jpg` and configure `http: {ImagePlug.Source.HTTP, ...}`. Don't add an HTTP-root adapter for plain path sources.

- [ ] **Step 8: Commit**

```bash
mise exec -- git add lib/image_plug.ex lib/image_plug/request/options.ex lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex lib/image_plug/response/sender.ex test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs test/image_plug_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
mise exec -- git rm lib/image_plug/origin/identity.ex
mise exec -- git commit -m "Resolve sources before cache lookup"
```

---

## Task 8: Telemetry And Boundary Replacement

**Files:**

- Modify: `lib/image_plug/source.ex`
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/request.ex`
- Modify: `lib/image_plug/response.ex`
- Modify: `lib/image_plug/cache.ex`
- Modify: `lib/image_plug/transform.ex`
- Modify: `mix.exs`
- Modify: `test/image_plug/telemetry_test.exs`
- Modify: `test/image_plug/architecture_boundary_test.exs`
- Delete: `lib/image_plug/origin.ex`
- Delete: `lib/image_plug/origin/decoded.ex`
- Delete: `test/image_plug/origin_test.exs`

- [ ] **Step 1: Write failing telemetry tests**

In `test/image_plug/telemetry_test.exs`, add:

```elixir
test "source resolve and fetch spans use safe low-cardinality metadata" do
  conn =
    :get
    |> conn("/_/plain/images/beach.jpg")
    |> ImagePlug.call(base_opts())

  assert conn.status == 200
  events = telemetry_events()

  for stage <- [[:source, :resolve], [:source, :fetch]] do
    assert_event(events, [:image_plug | stage] ++ [:start], fn measurements, metadata ->
      assert is_integer(measurements.system_time)
      assert metadata.source_kind in [:path, :url, :object, :reference]
      assert metadata.source_adapter_kind in [:file, :http, :s3, :custom]
      refute Map.has_key?(metadata, :source_adapter)
      refute inspect(metadata) =~ "images/beach.jpg"
      refute inspect(metadata) =~ "origin.test"
    end)

    assert_event(events, [:image_plug | stage] ++ [:stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.source_kind in [:path, :url, :object, :reference]
      assert metadata.source_adapter_kind in [:file, :http, :s3, :custom]
      refute Map.has_key?(metadata, :source_adapter)
      refute inspect(metadata) =~ "images/beach.jpg"
      refute inspect(metadata) =~ "origin.test"
    end)
  end
end
```

Update the `stages/0` helper in `telemetry_test.exs` to replace `[:origin, :identity]` and `[:origin, :fetch_decode]` with `[:source, :resolve]` and `[:source, :fetch]`. Update `base_opts/1`, `opts/1`, and `plan/1` in the same file to use `%ImagePlug.Plan.Source.Path{}` and file source config instead of `root_url` and `origin_req_options`.

- [ ] **Step 2: Write failing boundary tests**

Modify `test/image_plug/architecture_boundary_test.exs`:

- replace `ImagePlug.Origin` in `@boundary_files` with `ImagePlug.Source => "lib/image_plug/source.ex"`.
- change request boundary dependencies to include `ImagePlug.Source` instead of `ImagePlug.Origin`.
- add source boundary assertion:

```elixir
test "source boundary owns source identity and fetch context" do
  source = boundary_declaration(ImagePlug.Source)

  assert_boundary_deps(source, [ImagePlug.Plan, ImagePlug.Telemetry])
  refute_boundary_deps(source, [
    ImagePlug.Request,
    ImagePlug.Response,
    ImagePlug.Cache,
    ImagePlug.Output,
    ImagePlug.Transform,
    ImagePlug.Parser
  ])

  assert_boundary_exports(source, [
    ImagePlug.Source.Resolved,
    ImagePlug.Source.Response,
    ImagePlug.Source.StreamError,
    ImagePlug.Source.HTTP,
    ImagePlug.Source.File,
    ImagePlug.Source.S3
  ])
end
```

Add an output boundary assertion while this file is already being updated:

```elixir
test "output boundary depends only on plan data" do
  output = boundary_declaration(ImagePlug.Output)

  assert_boundary_deps(output, [ImagePlug.Plan])
  refute_boundary_deps(output, [
    ImagePlug.Source,
    ImagePlug.Parser,
    ImagePlug.Request,
    ImagePlug.Response,
    ImagePlug.Cache,
    ImagePlug.Transform
  ])
end
```

Keep the old test that asserts no `ImagePlug.Runtime` files exist. Don't add tests that require old Origin modules to remain deleted after this architecture assertion exists.

When updating source-scanning architecture tests, replace origin globs with source globs instead of only changing Boundary declarations. Request, source, and response files should be covered by the tests that forbid direct references to concrete transform operation modules. Parser-specific source translation structs should stay out of request, source, cache, output, response, and transform files. Source files may depend on `ImagePlug.Plan.Source.*` structs but must not depend on parser-specific imgproxy source structs.

- [ ] **Step 3: Run failing telemetry and boundary tests**

Run:

```bash
mise exec -- mix test test/image_plug/telemetry_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: failures until source spans and Boundary declarations are updated.

- [ ] **Step 4: Implement source telemetry spans**

In `ImagePlug.Source.resolve/3`:

```elixir
Telemetry.span(runtime_opts, [:source, :resolve], source_metadata(source, adapter_kind), fn ->
  result = do_resolve(source, opts, runtime_opts)
  {result, source_stop_metadata(result)}
end)
```

In `ImagePlug.Source.fetch/3`:

```elixir
Telemetry.span(runtime_opts, [:source, :fetch], resolved_metadata(resolved, adapter_kind), fn ->
  result = do_fetch(resolved, opts, runtime_opts)
  {result, source_stop_metadata(result)}
end)
```

The calls inside the span body must go through a `safe_adapter_call/1` helper:

```elixir
defp safe_adapter_call(fun) do
  fun.()
rescue
  _exception -> {:error, {:source, :adapter_exception}}
catch
  :exit, _reason -> {:error, {:source, :adapter_exception}}
end
```

Add telemetry tests with a raising source adapter and a raising credential provider. The expected result is a returned `{:error, {:source, :adapter_exception}}` and `[:source, :resolve, :stop]` or `[:source, :fetch, :stop]` metadata with `result: :source_error`; there must be no `[:source, ..., :exception]` telemetry event.

Metadata must include only:

```elixir
%{
  source_kind: source_kind,
  source_adapter_kind: adapter_family,
  result: :ok | :source_error
}
```

Custom adapters default to `:custom`. Built-ins emit `:http`, `:file`, and `:s3`. Don't include dispatch adapter keys, hosts, paths, buckets, object keys, raw errors, exception structs, stack traces, or parser structs.

- [ ] **Step 5: Update Boundary declarations and docs grouping**

Update:

- `ImagePlug` dependencies: replace `ImagePlug.Origin` with `ImagePlug.Source`.
- `ImagePlug.Request` dependencies: replace `ImagePlug.Origin` with `ImagePlug.Source`.
- `ImagePlug.Response` forbidden dependencies in tests: replace origin with source where relevant.
- `ImagePlug.Source` boundary declaration: `deps: [ImagePlug.Plan, ImagePlug.Telemetry]`.
- `mix.exs` docs grouping: replace `~r/ImagePlug\.Origin.*/` with `~r/ImagePlug\.Source.*/`.

Delete origin modules after all callers move:

```bash
mise exec -- git rm lib/image_plug/origin.ex lib/image_plug/origin/decoded.ex test/image_plug/origin_test.exs
```

- [ ] **Step 6: Run telemetry, boundary, and compile checks**

Run:

```bash
mise exec -- mix test test/image_plug/telemetry_test.exs test/image_plug/architecture_boundary_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
mise exec -- git add lib/image_plug.ex lib/image_plug/request.ex lib/image_plug/response.ex lib/image_plug/cache.ex lib/image_plug/transform.ex lib/image_plug/source.ex mix.exs test/image_plug/telemetry_test.exs test/image_plug/architecture_boundary_test.exs
mise exec -- git commit -m "Replace origin boundary with source boundary"
```

---

## Task 9: Plug-Level HTTP, File, S3, Cache, And Custom Adapter Coverage

**Files:**

- Modify: `test/image_plug_test.exs`
- Modify: `test/image_plug/request_safety_test.exs`
- Modify: `test/image_plug/imgproxy_wire_conformance_test.exs`
- Modify: `test/support/image_plug/imgproxy_wire_conformance_test/cache_probe.ex`
- Create: `test/support/image_plug/source_test/foobar_translator.ex`
- Create: `test/support/image_plug/source_test/plug_custom_adapter.ex`

- [ ] **Step 1: Add plug-level custom adapter tests**

Create `test/support/image_plug/source_test/foobar_translator.ex`:

```elixir
defmodule ImagePlug.SourceTest.FoobarTranslator do
  @moduledoc false

  @behaviour ImagePlug.Parser.Imgproxy.SourceScheme

  @impl true
  def translate(source, _opts) do
    send(self(), {:foobar_translate, source})

    {:ok,
     %ImagePlug.Plan.Source.Object{
       adapter: :foobar,
       scope: "asset",
       key: source,
       revision: nil
     }}
  end
end
```

Create `test/support/image_plug/source_test/plug_custom_adapter.ex`:

```elixir
defmodule ImagePlug.SourceTest.PlugCustomAdapter do
  @moduledoc false

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  @behaviour Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(source, opts, _runtime_opts) do
    send(self(), {:custom_resolve, source})

    {:ok,
     %Resolved{
       adapter: Keyword.fetch!(opts, :adapter),
       source_kind: :object,
       identity: [kind: :object, adapter: Keyword.fetch!(opts, :adapter), scope: "custom", key: "cat.jpg"],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: :cat
     }}
  end

  @impl true
  def fetch(%Resolved{} = resolved, _opts, _runtime_opts) do
    send(self(), {:custom_fetch, resolved.fetch})
    {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end
end
```

Add a plug-level test:

```elixir
test "custom imgproxy scheme translator and custom source adapter fetch only on cache miss" do
  conn =
    conn(:get, "/_/plain/foobar://asset/cat.jpg")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      imgproxy: [
        source_schemes: %{
          "foobar" => {ImagePlug.SourceTest.FoobarTranslator, []}
        }
      ],
      sources: [
        foobar: {ImagePlug.SourceTest.PlugCustomAdapter, adapter: :foobar}
      ],
      cache: {ImgproxyWireConformanceTest.CacheProbe, []}
    )

  assert conn.status == 200
  assert_received {:foobar_translate, "foobar://asset/cat.jpg"}
  assert_received {:custom_resolve, _source}
  assert_received {:custom_fetch, :cat}
end
```

- [ ] **Step 2: Add plug-level cache hit and cache miss ordering tests**

Update `test/support/image_plug/imgproxy_wire_conformance_test/cache_probe.ex` so tests can choose a hit or miss:

```elixir
def get(key, opts) do
  send(self(), {:cache_lookup, key})

  case Keyword.get(opts, :result, :miss) do
    :miss -> :miss
    {:hit, entry} -> {:hit, entry}
  end
end

def put(key, entry, _opts) do
  send(self(), {:cache_put, key, entry})
  :ok
end
```

Add focused plug-level tests:

```elixir
defp cache_entry do
  %ImagePlug.Cache.Entry{
    body: File.read!("priv/static/images/beach.jpg"),
    content_type: "image/jpeg",
    headers: [],
    created_at: DateTime.utc_now()
  }
end

test "cache hit resolves custom source but does not fetch" do
  conn =
    conn(:get, "/_/plain/foobar://asset/cat.jpg")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      imgproxy: [
        source_schemes: %{"foobar" => {ImagePlug.SourceTest.FoobarTranslator, []}}
      ],
      sources: [foobar: {ImagePlug.SourceTest.PlugCustomAdapter, adapter: :foobar}],
      cache: {ImgproxyWireConformanceTest.CacheProbe, result: {:hit, cache_entry()}}
    )

  assert conn.status == 200
  assert_received {:custom_resolve, _source}
  assert_received {:cache_lookup, _key}
  refute_received {:custom_fetch, _fetch}
  refute_received {:cache_put, _key, _entry}
end

test "cache miss fetches custom source and writes successful encoded response" do
  conn =
    conn(:get, "/_/plain/foobar://asset/cat.jpg")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      imgproxy: [
        source_schemes: %{"foobar" => {ImagePlug.SourceTest.FoobarTranslator, []}}
      ],
      sources: [foobar: {ImagePlug.SourceTest.PlugCustomAdapter, adapter: :foobar}],
      cache: {ImgproxyWireConformanceTest.CacheProbe, result: :miss}
    )

  assert conn.status == 200
  assert_received {:custom_resolve, _source}
  assert_received {:cache_lookup, _key}
  assert_received {:custom_fetch, :cat}
  assert_received {:cache_put, _key, _entry}
end

test "cache skip fetches custom source without cache lookup or write" do
  conn =
    conn(:get, "/_/plain/foobar://asset/cat.jpg")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      imgproxy: [
        source_schemes: %{"foobar" => {ImagePlug.SourceTest.FoobarTranslator, []}}
      ],
      sources: [
        foobar: {ImagePlug.SourceTest.PlugCustomAdapter, adapter: :foobar, cache: :skip}
      ],
      cache: {ImgproxyWireConformanceTest.CacheProbe, result: :miss}
    )

  assert conn.status == 200
  assert_received {:custom_resolve, _source}
  assert_received {:custom_fetch, :cat}
  refute_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry}
end
```

Keep the request-safety tests from Task 7 for parser failures and source resolution failures before cache lookup. Use message-sending adapters and cache probes rather than source-code inspection.

- [ ] **Step 3: Add plug-level S3 credential timing test**

Add plug-level tests for S3 credential timing:

```elixir
test "S3 cache hit resolves identity without asking credential providers" do
  conn =
    conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      sources: [
        s3:
          {ImagePlug.Source.S3,
           default: [
             endpoint: "https://minio.test",
             region: "eu-west-1",
             credentials: {:provider, ImagePlug.SourceTest.CredentialProvider}
           ],
           buckets: %{
             "tenant-a" => [
               credentials: {:provider, ImagePlug.SourceTest.CredentialProvider}
             ]
           }}
      ],
      cache: {ImgproxyWireConformanceTest.CacheProbe, result: {:hit, cache_entry()}}
    )

  assert conn.status == 200
  assert_received {:cache_lookup, _key}
  refute_received {:fetch_credentials, _, _, _}
end

test "S3 cache miss asks only the selected bucket credential provider before fetch" do
  plug = fn conn -> Plug.Conn.send_resp(conn, 200, File.read!("priv/static/images/beach.jpg")) end

  conn =
    conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      sources: [
        s3:
          {ImagePlug.Source.S3,
           default: [
             endpoint: "https://minio.test",
             region: "eu-west-1",
             credentials: {:provider, ImagePlug.SourceTest.CredentialProvider, role: "default"}
           ],
           buckets: %{
             "tenant-a" => [
               credentials: {:provider, ImagePlug.SourceTest.CredentialProvider, role: "tenant-a"}
             ],
             "tenant-b" => [
               credentials: {:provider, ImagePlug.SourceTest.CredentialProvider, role: "tenant-b"}
             ]
           },
           req_options: [plug: plug]}
      ],
      cache: {ImgproxyWireConformanceTest.CacheProbe, result: :miss}
    )

  assert conn.status == 200
  assert_received {:fetch_credentials, "tenant-a", [role: "tenant-a"], _runtime_opts}
  refute_received {:fetch_credentials, "tenant-a", [role: "default"], _runtime_opts}
  refute_received {:fetch_credentials, "tenant-b", [role: "tenant-b"], _runtime_opts}
end
```

- [ ] **Step 4: Run plug-level tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/image_plug/request_safety_test.exs test/image_plug/imgproxy_wire_conformance_test.exs
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
mise exec -- git add test/image_plug_test.exs test/image_plug/request_safety_test.exs test/image_plug/imgproxy_wire_conformance_test.exs test/support/image_plug/imgproxy_wire_conformance_test/cache_probe.ex test/support/image_plug/source_test/foobar_translator.ex test/support/image_plug/source_test/plug_custom_adapter.ex
mise exec -- git commit -m "Cover source adapters at the plug boundary"
```

---

## Task 10: Final Cleanup And Verification

**Files:**

- Modify as needed: `README.md`
- Modify as needed: `docs/imgproxy_path_api.md`
- Modify as needed: `docs/telemetry.md`
- Modify as needed: `docs/cache.md`
- Modify as needed: `CHANGELOG.md`

- [ ] **Step 1: Search for stale origin terminology**

Run:

```bash
rg "Origin|origin_identity|origin_url|origin_req_options|root_url|\\{:plain" lib test docs README.md CHANGELOG.md
```

Expected: only deliberate compatibility references remain. Any runtime path still using `ImagePlug.Origin` must be removed. Any public docs that still describe a single HTTP root must be updated to source adapters.

- [ ] **Step 2: Update docs for observable behavior**

Update docs to state:

- parser and plan validation finish before source resolution, cache, or fetch.
- source resolution finishes before cache lookup.
- cache lookup happens before source fetch and decode for cacheable sources.
- fetch and decode run only on cache miss or `cache: :skip`.
- `sources:` config maps adapter keys to modules and options.
- built-in first slice supports path/file, HTTP, HTTPS, and S3-compatible object sources.
- S3 `buckets` is a map; when present it's an allowlist and `default` only supplies shared defaults.
- source telemetry emits `[:source, :resolve]` and `[:source, :fetch]` spans with safe metadata.

Don't mention the private reference projects or URLs used during brainstorming.

- [ ] **Step 3: Format**

Run:

```bash
mise exec -- mix format
```

Expected: no errors.

- [ ] **Step 4: Run focused test suite**

Run:

```bash
mise exec -- mix test test/image_plug/plan/source_test.exs test/image_plug/source_test.exs test/image_plug/source/http_test.exs test/image_plug/source/file_test.exs test/image_plug/source/s3_test.exs test/parser/imgproxy/source_test.exs test/image_plug/cache/key_test.exs test/image_plug/request_safety_test.exs test/image_plug/architecture_boundary_test.exs test/image_plug/telemetry_test.exs
```

Expected: pass.

- [ ] **Step 5: Run full verification**

Run:

```bash
mise exec -- mix test
mise exec -- mix compile --warnings-as-errors
mise exec -- vale README.md docs/cache.md docs/imgproxy_path_api.md docs/telemetry.md docs/superpowers/specs/2026-05-18-source-adapters-design.md
```

Expected: all pass.

- [ ] **Step 6: Commit final cleanup**

```bash
mise exec -- git add README.md CHANGELOG.md docs/cache.md docs/imgproxy_path_api.md docs/telemetry.md lib test mix.exs
mise exec -- git commit -m "Document source adapter behavior"
```

---

## Implementation Notes

- Keep `resolve/3` pure with respect to source bytes: no network calls, file reads, credential provider calls, storage client calls, decode calls, or cache calls.
- Keep `fetch/3` byte-oriented: adapters return `%ImagePlug.Source.Response{stream: enumerable}` only. They don't return decoded images.
- Keep `ImagePlug.Source.Resolved.identity` primitive and deterministic. The cache receives `resolved.identity`, not the whole struct.
- Keep credential data out of `ImagePlug.Plan`, cache keys, telemetry, response bodies, and default error terms.
- Don't try to preserve the old `ImagePlug.Origin` boundary. The design explicitly replaces it with `ImagePlug.Source`.
- Don't add support for GCS, Azure Blob Storage, Swift, or reference fetching in this slice. The structs and behaviour shape should leave room for them.
- Don't test impossible internal misuse. Test public option validation, parser translation, source resolution, cache ordering, fetch behavior, stream wrapping, telemetry, and Boundary dependencies.

## Self-Review Checklist

- Spec coverage: Tasks cover typed plan sources, source registry, HTTP/File/S3 adapters, imgproxy translations, custom scheme translators, source identity in cache keys, cache skip, stream wrapping, telemetry, boundary replacement, and plug-level ordering.
- Deferred scope: `Reference` has a struct and validation only; no fetch adapter is planned.
- Ordering: source resolution is planned before cache lookup; fetch/decode are planned only after cache miss or cache skip.
- Safety: secrets, signed data, absolute root paths, parser structs, adapter modules, and raw reasons are excluded from cache and default telemetry.
- Naming: the plan uses `adapter`, not `adapter_key`, and doesn't introduce `ImagePlug.Runtime`.
- Verification: every task has focused tests and a commit; the final task runs full test, compile, format, and Vale checks.
