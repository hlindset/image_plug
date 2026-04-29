# Filesystem Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add optional persistent filesystem caching for processed image responses while preserving pre-origin parser and planner validation.

**Architecture:** Introduce a small cache boundary made of `ImagePlug.Cache.Key`, `ImagePlug.Cache.Entry`, `ImagePlug.Cache`, and `ImagePlug.Cache.FileSystem`. Refactor `ImagePlug.call/2` so cache-enabled requests build the resolved origin identity before cache lookup, serve complete cached entries on hit, and encode complete response bodies on cacheable misses before optional filesystem storage.

**Tech Stack:** Elixir, Plug, ExUnit, Req, image/Vix/libvips, Erlang `:crypto`, filesystem APIs from `File` and `Path`. Run all project commands through `mise exec -- ...`.

---

## File Structure

- Create `lib/image_plug/cache/entry.ex`: adapter-independent cached response struct with cached response header normalization and allowlisting.
- Create `lib/image_plug/cache/key.ex`: deterministic cache-key material serialization and SHA-256 hash generation, including `Accept` normalization for `format:auto`.
- Create `lib/image_plug/cache.ex`: cache behaviour and coordinator for configured adapters, max-body checks, and `fail_on_cache_error` policy.
- Create `lib/image_plug/cache/file_system.ex`: local filesystem adapter with validated root/prefix handling, hash-partitioned paths, metadata/body reads, atomic writes, and temp cleanup.
- Modify `lib/image_plug.ex`: split origin URL construction from origin fetch, branch into uncached streaming and cache-enabled whole-body response paths, and isolate response sending helpers.
- Modify `README.md`: document the optional filesystem cache, cache-key inputs, and fail-open/fail-closed behavior.
- Create `test/image_plug/cache/entry_test.exs`: entry construction, cached response header normalization, and header allowlisting.
- Create `test/image_plug/cache/key_test.exs`: canonical key material, schema versioning, deterministic serialization, signature exclusion, origin identity inclusion, header/cookie selection, and `Accept` normalization.
- Create `test/image_plug/cache_test.exs`: coordinator miss/hit/error/max-body policy using fake adapters.
- Create `test/image_plug/cache/file_system_test.exs`: option validation, traversal rejection, path safety, get/put, miss cases, invalid metadata, metadata read errors, and temp cleanup.
- Create `test/image_plug/cache/key_property_test.exs`: property tests for deterministic key serialization, excluded fields, included fields, and `Accept` normalization.
- Create `test/image_plug/cache/entry_property_test.exs`: property tests for cached response header allowlisting, lowercase normalization, and relative order.
- Create `test/image_plug/cache/file_system_property_test.exs`: property tests for path safety, prefix rejection, filesystem round-trips, and corrupt metadata handling.
- Modify `test/image_plug_test.exs`: integration tests proving no-cache requests keep the streaming path, parser/planner errors avoid cache and origin, cache hits avoid origin, misses write processed entries, oversized outputs skip writes, and `fail_on_cache_error` controls failure behavior.

## Implementation Notes

- Keep the existing uncached path streaming through `Image.stream!/2`; only cache-enabled misses switch to whole-body encoding.
- Build the cache key only after parser success, planner success, and successful origin URL construction. This preserves current validation behavior and avoids hiding origin URL errors behind cache hits.
- Use the resolved origin URL from `ImagePlug.Origin.build_url/2` as the first origin identity for `:plain` sources.
- Cache key material must include `schema_version: 1` from day one. Build key material only from plain Elixir/Erlang primitives, not structs. Serialize it as a sorted keyword-style list with recursive canonicalization and `:erlang.term_to_binary(canonical_material, [:deterministic])`, then hash that binary with SHA-256.
- Do not include `ProcessingRequest.signature`, raw request path, query string, unconfigured headers, or unconfigured cookies in key material.
- For `format:auto`, include normalized `Accept` key material and store the final response content type plus `vary: Accept` header in the cache entry. The first implementation performs safe syntactic normalization only: downcase media ranges and parameter names, trim optional whitespace, preserve media-range order and q-values, and do not sort media ranges. Extra cache misses are safer than incorrect cache hits. Do not attempt full RFC-perfect content negotiation in the cache key.
- Provide both `ImagePlug.Cache.Entry.new/1` and `ImagePlug.Cache.Entry.new!/1`. Filesystem reads use `new/1` so corrupt metadata returns structured misses/errors instead of relying on exception control flow.
- Entry construction rejects non-binary bodies, blank or non-binary content types, malformed headers, and non-`DateTime` `created_at` values.
- `created_at` is the cache entry creation timestamp, not an origin timestamp or HTTP response date.
- Cache entry response headers are intentionally narrow: store and send only `vary` and `cache-control`, normalize header names to lowercase internally, and preserve duplicate allowed headers in input order after normalization. Do not cache hop-by-hop or request-specific response headers.
- Filesystem paths must be derived only from the generated SHA-256 hash, fixed suffixes, validated root, and validated `path_prefix`. `path_prefix` is split into path segments and must reject absolute paths, backslashes, empty segments from duplicate slashes, `.`, `..`, and `~`-prefixed segments.
- A filesystem cache entry is valid only when metadata and body both exist, metadata parses successfully, and metadata matches the body size. Metadata has its own `metadata_version: 1`, independent of cache key `schema_version: 1`. Rename body into place first and metadata into place last, so readers never count a body-only partial write as a hit.
- Invalid metadata is treated as a miss by default and as a cache read error when `fail_on_cache_error: true`.
- Concurrent writes to the same key are acceptable. Temp files are exclusive and unique, final renames are atomic, and the last completed writer wins.
- The cache root is trusted local configuration. The adapter expands and validates the configured root and generated paths, but it does not attempt to defend against a local actor replacing directories inside the cache root with symlinks. Document this trust boundary.
- Cache reads and writes fail open by default. When `fail_on_cache_error: true`, read errors fail before origin fetch and write errors fail before the cache-enabled response is sent.
- `max_body_bytes` applies to cache storage, not to serving the processed response. Cache-enabled misses still send oversized encoded outputs successfully when encoding succeeds; they only skip cache storage.
- Only successful processed image responses are cacheable. Parser, planner, origin fetch, decode, transform, negotiation, and encode errors are never stored; origin error bodies are not cached.
- Property tests use the existing `stream_data` dependency and `use ExUnitProperties`. If a future branch lacks `stream_data`, add `{:stream_data, "~> 1.1", only: :test}` before adding property test files.
- Property generators must keep binary bodies, header lists, path prefixes, and metadata sizes bounded so the suite remains fast and deterministic.
- Use project commands exactly as shown; the repo's `AGENTS.md` requires `mise exec -- ...`.

### Task 1: Add Cache Entry

**Files:**
- Create: `test/image_plug/cache/entry_test.exs`
- Create: `lib/image_plug/cache/entry.ex`

- [ ] **Step 1: Write the failing entry test**

Create `test/image_plug/cache/entry_test.exs`:

```elixir
defmodule ImagePlug.Cache.EntryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Cache.Entry

  test "builds an entry and normalizes allowlisted response headers" do
    created_at = ~U[2026-04-29 10:15:00Z]

    entry = Entry.new!(
      body: "encoded image",
      content_type: "image/webp",
      headers: [
        {"Vary", "Accept"},
        {"cache-control", "public, max-age=60"},
        {"connection", "close"},
        {"x-request-id", "abc123"}
      ],
      created_at: created_at
    )

    assert entry.body == "encoded image"
    assert entry.content_type == "image/webp"
    assert entry.headers == [{"vary", "Accept"}, {"cache-control", "public, max-age=60"}]
    assert entry.created_at == created_at
  end

  test "preserves duplicate allowed headers in input order" do
    entry =
      Entry.new!(
        body: <<1, 2, 3>>,
        content_type: "image/png",
        headers: [
          {"Vary", "Accept"},
          {"vary", "Origin"},
          {"Cache-Control", "public"},
          {"cache-control", "max-age=60"}
        ],
        created_at: ~U[2026-04-29 10:15:00Z]
      )

    assert entry.headers == [
             {"vary", "Accept"},
             {"vary", "Origin"},
             {"cache-control", "public"},
             {"cache-control", "max-age=60"}
           ]
  end

  test "drops response headers outside the cache allowlist case-insensitively" do
    entry =
      Entry.new!(
        body: <<1, 2, 3>>,
        content_type: "image/png",
        headers: [{"Set-Cookie", "secret"}, {"VARY", "Accept"}],
        created_at: ~U[2026-04-29 10:15:00Z]
      )

    assert entry.headers == [{"vary", "Accept"}]
  end

  test "rejects invalid entry fields" do
    assert {:error, {:invalid_body, :not_binary}} =
             Entry.new(
               body: :not_binary,
               content_type: "image/webp",
               headers: [],
               created_at: DateTime.utc_now()
             )

    assert_raise ArgumentError, fn ->
      Entry.new!(
        body: :not_binary,
        content_type: "image/webp",
        headers: [],
        created_at: DateTime.utc_now()
      )
    end
  end
end
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/cache/entry_test.exs
```

Expected: failure because `ImagePlug.Cache.Entry` is not defined.

- [ ] **Step 3: Add the entry module**

Create `lib/image_plug/cache/entry.ex`:

```elixir
defmodule ImagePlug.Cache.Entry do
  @moduledoc """
  Adapter-independent cached image response.
  """

  @allowed_headers ~w(vary cache-control)

  @enforce_keys [:body, :content_type, :headers, :created_at]
  defstruct [:body, :content_type, :headers, :created_at]

  @type header() :: {String.t(), String.t()}

  @type t() :: %__MODULE__{
          body: binary(),
          content_type: String.t(),
          headers: [header()],
          # Cache entry creation timestamp, not an origin or HTTP date.
          created_at: DateTime.t()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    with {:ok, body} <- fetch_binary(attrs, :body),
         {:ok, content_type} <- fetch_non_empty_binary(attrs, :content_type),
         {:ok, headers} <- normalize_headers(Keyword.get(attrs, :headers, [])),
         {:ok, created_at} <- fetch_datetime(attrs, :created_at) do
      {:ok,
       %__MODULE__{
         body: body,
         content_type: content_type,
         headers: headers,
         created_at: created_at
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    case new(attrs) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "invalid cache entry: #{inspect(reason)}"
    end
  end

  @spec normalize_headers([term()]) :: {:ok, [header()]} | {:error, term()}
  def normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce_while({:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        key = String.downcase(key)

        if key in @allowed_headers do
          {:cont, {:ok, [{key, value} | acc]}}
        else
          {:cont, {:ok, acc}}
        end

      header, {:ok, _acc} ->
        {:halt, {:error, {:invalid_header, header}}}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_headers(headers), do: {:error, {:invalid_headers, headers}}

  defp fetch_binary(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_body, value}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp fetch_non_empty_binary(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_content_type, value}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp fetch_datetime(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, %DateTime{} = value} -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_created_at, value}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end
end
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
mise exec -- mix test test/image_plug/cache/entry_test.exs
```

Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit Task 1**

Run:

```bash
git add lib/image_plug/cache/entry.ex test/image_plug/cache/entry_test.exs
git commit -m "feat: add cache entry"
```

### Task 2: Add Cache Key Generation

**Files:**
- Create: `test/image_plug/cache/key_test.exs`
- Create: `lib/image_plug/cache/key.ex`

- [ ] **Step 1: Write cache key tests**

Create `test/image_plug/cache/key_test.exs`:

```elixir
defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  defp request(overrides \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "sig-one",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          width: {:pixels, 100},
          height: {:pixels, 80},
          fit: :cover,
          focus: {:anchor, :center, :center},
          format: :webp
        ],
        overrides
      )
    )
  end

  test "builds stable hash and material from canonical request fields and origin identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = Key.build(conn, request(), "https://origin-a.test/images/cat.jpg")
    same = Key.build(conn, request(), "https://origin-a.test/images/cat.jpg")
    different_origin = Key.build(conn, request(), "https://origin-b.test/images/cat.jpg")

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert is_binary(key.serialized_material)
    assert key.material[:schema_version] == 1
    assert key.material[:origin_identity] == "https://origin-a.test/images/cat.jpg"
    assert key.material[:operations] == [
             source_kind: :plain,
             source_path: ["images", "cat.jpg"],
             width: {:pixels, 100},
             height: {:pixels, 80},
             fit: :cover,
             focus: {:anchor, :center, :center}
           ]
    assert key.material[:output] == [format: :webp, accept: nil]
    assert key.material[:selected_headers] == []
    assert key.material[:selected_cookies] == []
    assert key.serialized_material == Key.serialize_material(key.material)
    refute Keyword.has_key?(key.material, :signature)
    refute inspect(key.material) =~ "ignored=true"
    refute key.hash == different_origin.hash
  end

  test "signature changes do not change the key" do
    conn = conn(:get, "/sig-one/plain/images/cat.jpg")

    key_one = Key.build(conn, request(signature: "sig-one"), "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn, request(signature: "sig-two"), "https://origin.test/images/cat.jpg")

    assert key_one.hash == key_two.hash
  end

  test "only configured headers and cookies are included" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("x-ignored", "ignored")
      |> put_req_header("cookie", "tenant=acme; ignored_cookie=ignored")

    key =
      Key.build(conn, request(),
        "https://origin.test/images/cat.jpg",
        key_headers: ["Accept-Language"],
        key_cookies: ["tenant"]
      )

    assert key.material[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.material[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.material) =~ "x-ignored"
    refute inspect(key.material) =~ "ignored_cookie"
  end

  test "format auto includes normalized Accept material" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", " Image/WEBP ; Q=0.8 , image/AVIF;q=1 ")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=0.8,image/avif;q=1")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [format: :auto, accept: "image/webp;q=0.8,image/avif;q=1"]
    assert key_one.hash == key_two.hash
  end

  test "missing Accept normalizes to an empty string for format auto" do
    key =
      Key.build(
        conn(:get, "/_/plain/images/cat.jpg"),
        request(format: :auto),
        "https://origin.test/images/cat.jpg"
      )

    assert key.material[:output] == [format: :auto, accept: ""]
  end

  test "wildcard Accept headers normalize whitespace and casing while preserving order" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", " image/AVIF , */* ")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,*/*")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [format: :auto, accept: "image/avif,*/*"]
    assert key_one.hash == key_two.hash
  end

  test "format auto preserves media-range order because negotiation may use it as a tiebreaker" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp,image/avif")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    refute key_one.hash == key_two.hash
  end

  test "quality values remain key material for format auto" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=0.9,image/avif;q=1")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.9")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    refute key_one.hash == key_two.hash
  end

  test "explicit formats do not include Accept material" do
    conn =
      :get
      |> conn("/_/format:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = Key.build(conn, request(format: :webp), "https://origin.test/images/cat.jpg")

    assert key.material[:output] == [format: :webp, accept: nil]
  end
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs
```

Expected: failure because `ImagePlug.Cache.Key` is not defined.

- [ ] **Step 3: Add the key module**

Create `lib/image_plug/cache/key.ex`:

```elixir
defmodule ImagePlug.Cache.Key do
  @moduledoc """
  Builds canonical cache-key material and a filesystem-safe hash.
  """

  import Plug.Conn

  alias ImagePlug.ProcessingRequest

  @schema_version 1

  @enforce_keys [:hash, :material, :serialized_material]
  defstruct [:hash, :material, :serialized_material]

  @type t() :: %__MODULE__{
          hash: String.t(),
          material: keyword(),
          serialized_material: binary()
        }

  @spec build(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: t()
  def build(%Plug.Conn{} = conn, %ProcessingRequest{} = request, origin_identity, opts \\ [])
      when is_binary(origin_identity) do
    material = [
      schema_version: @schema_version,
      origin_identity: origin_identity,
      operations: [
        source_kind: request.source_kind,
        source_path: request.source_path,
        width: request.width,
        height: request.height,
        fit: request.fit,
        focus: request.focus
      ],
      output: output_material(conn, request),
      selected_headers: selected_headers(conn, Keyword.get(opts, :key_headers, [])),
      selected_cookies: selected_cookies(conn, Keyword.get(opts, :key_cookies, []))
    ]

    serialized_material = serialize_material(material)

    %__MODULE__{
      hash: hash_serialized_material(serialized_material),
      material: material,
      serialized_material: serialized_material
    }
  end

  @spec serialize_material(keyword()) :: binary()
  def serialize_material(material) when is_list(material) do
    material
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  @spec normalize_accept(String.t() | nil) :: String.t()
  def normalize_accept(nil), do: ""
  def normalize_accept(""), do: ""

  def normalize_accept(accept_header) when is_binary(accept_header) do
    accept_header
    |> String.split(",")
    |> Enum.map(&normalize_accept_entry/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp output_material(conn, %ProcessingRequest{format: :auto}) do
    accept =
      conn
      |> get_req_header("accept")
      |> Enum.join(",")
      |> normalize_accept()

    [format: :auto, accept: accept]
  end

  defp output_material(_conn, %ProcessingRequest{format: format}), do: [format: format, accept: nil]

  defp selected_headers(conn, header_names) do
    header_names
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn header_name -> {header_name, get_req_header(conn, header_name)} end)
  end

  defp selected_cookies(conn, cookie_names) do
    conn = fetch_cookies(conn)

    cookie_names
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn cookie_name -> {cookie_name, Map.get(conn.req_cookies, cookie_name)} end)
  end

  defp normalize_accept_entry(entry) do
    [media_range | params] =
      entry
      |> String.split(";")
      |> Enum.map(&String.trim/1)

    media_range = String.downcase(media_range)

    if media_range == "" do
      ""
    else
      params =
        params
        |> Enum.map(&normalize_accept_param/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.sort()

      Enum.join([media_range | params], ";")
    end
  end

  defp normalize_accept_param(param) do
    case String.split(param, "=", parts: 2) do
      [name, value] -> String.downcase(String.trim(name)) <> "=" <> String.trim(value)
      [name] -> String.downcase(String.trim(name))
    end
  end

  defp canonicalize(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    else
      Enum.map(list, &canonicalize/1)
    end
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
  end

  defp canonicalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.map(&canonicalize/1) |> List.to_tuple()
  defp canonicalize(value), do: value

  defp hash_serialized_material(serialized_material) do
    :sha256
    |> :crypto.hash(serialized_material)
    |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add lib/image_plug/cache/key.ex test/image_plug/cache/key_test.exs
git commit -m "feat: add cache key generation"
```

### Task 3: Add Cache Coordinator

**Files:**
- Create: `test/image_plug/cache_test.exs`
- Create: `lib/image_plug/cache.ex`

- [ ] **Step 1: Write coordinator tests**

Create `test/image_plug/cache_test.exs`:

```elixir
defmodule ImagePlug.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  defmodule HitAdapter do
    def get(%Key{}, opts), do: {:hit, Keyword.fetch!(opts, :entry)}
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defmodule MissAdapter do
    def get(%Key{}, _opts), do: :miss
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defmodule ErrorAdapter do
    def get(%Key{}, _opts), do: {:error, :read_failed}
    def put(%Key{}, %Entry{}, _opts), do: {:error, :write_failed}
  end

  defp request do
    %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      format: :webp
    }
  end

  defp entry(body \\ "body") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  test "returns disabled when no cache is configured" do
    assert Cache.lookup(conn(:get, "/_/plain/images/cat.jpg"), request(), "https://origin.test/cat.jpg", []) ==
             :disabled
  end

  test "returns hits with the generated key" do
    configured_entry = entry()

    assert {:hit, %Key{} = key, ^configured_entry} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {HitAdapter, entry: configured_entry}
             )

    assert key.material[:origin_identity] == "https://origin.test/cat.jpg"
  end

  test "returns miss with the generated key" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {MissAdapter, []}
             )

    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "read errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}} =
                 Cache.lookup(
                   conn(:get, "/_/format:webp/plain/images/cat.jpg"),
                   request(),
                   "https://origin.test/cat.jpg",
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ ":read_failed"
  end

  test "read errors are returned when fail_on_cache_error is true" do
    assert {:error, {:cache_read, :read_failed}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ErrorAdapter, fail_on_cache_error: true}
             )
  end

  test "put skips bodies over max_body_bytes" do
    assert :skipped =
             Cache.put(
               cache_key(),
               entry("123456"),
               cache: {ErrorAdapter, max_body_bytes: 5}
             )
  end

  test "write errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert :ok =
                 Cache.put(
                   cache_key(),
                   entry(),
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache write error"
    assert log =~ ":write_failed"
  end

  test "write errors are returned when fail_on_cache_error is true" do
    assert {:error, {:cache_write, :write_failed}} =
             Cache.put(
               cache_key(),
               entry(),
               cache: {ErrorAdapter, fail_on_cache_error: true}
             )
  end
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs
```

Expected: failure because `ImagePlug.Cache` is not defined.

- [ ] **Step 3: Add the coordinator module**

Create `lib/image_plug/cache.ex`:

```elixir
defmodule ImagePlug.Cache do
  @moduledoc """
  Cache behaviour and top-level cache policy.
  """

  require Logger

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  @callback get(Key.t(), keyword()) :: {:hit, Entry.t()} | :miss | {:error, term()}
  @callback put(Key.t(), Entry.t(), keyword()) :: :ok | {:error, term()}

  @type lookup_result() ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:error, {:cache_read, term()}}

  @spec lookup(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: lookup_result()
  def lookup(%Plug.Conn{} = conn, %ProcessingRequest{} = request, origin_identity, opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        :disabled

      {adapter, cache_opts} ->
        key = Key.build(conn, request, origin_identity, cache_opts)

        case adapter.get(key, cache_opts) do
          {:hit, %Entry{} = entry} ->
            {:hit, key, entry}

          :miss ->
            {:miss, key}

          {:error, reason} ->
            handle_read_error(reason, key, cache_opts)
        end
    end
  end

  @spec put(Key.t(), Entry.t(), keyword()) :: :ok | :skipped | {:error, {:cache_write, term()}}
  def put(%Key{} = key, %Entry{} = entry, opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        :skipped

      {adapter, cache_opts} ->
        max_body_bytes = Keyword.get(cache_opts, :max_body_bytes, :infinity)

        if max_body_bytes != :infinity and byte_size(entry.body) > max_body_bytes do
          :skipped
        else
          case adapter.put(key, entry, cache_opts) do
            :ok -> :ok
            {:error, reason} -> handle_write_error(reason, cache_opts)
          end
        end
    end
  end

  defp handle_read_error(reason, key, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_read, reason}}
    else
      Logger.warning("cache read error: #{inspect(reason)}")
      {:miss, key}
    end
  end

  defp handle_write_error(reason, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_write, reason}}
    else
      Logger.warning("cache write error: #{inspect(reason)}")
      :ok
    end
  end
end
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add lib/image_plug/cache.ex test/image_plug/cache_test.exs
git commit -m "feat: add cache coordinator"
```

### Task 4: Add Filesystem Cache Adapter

**Files:**
- Create: `test/image_plug/cache/file_system_test.exs`
- Create: `lib/image_plug/cache/file_system.ex`

- [ ] **Step 1: Write filesystem adapter tests**

Create `test/image_plug/cache/file_system_test.exs`:

```elixir
defmodule ImagePlug.Cache.FileSystemTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.FileSystem
  alias ImagePlug.Cache.Key

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  defp entry(body \\ "encoded image") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp root(context) do
    Path.join(System.tmp_dir!(), "image_plug_fs_cache_#{context.test}")
  end

  setup context do
    root = root(context)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "requires an absolute root" do
    assert FileSystem.get(key(), []) == {:error, {:missing_required_option, :root}}
    assert FileSystem.get(key(), root: "relative/cache") == {:error, {:invalid_root, "relative/cache"}}
  end

  test "rejects traversal-shaped path prefixes", %{root: root} do
    assert FileSystem.get(key(), root: root, path_prefix: "../outside") ==
             {:error, {:invalid_path_prefix, "../outside"}}

    assert FileSystem.get(key(), root: root, path_prefix: "/absolute") ==
             {:error, {:invalid_path_prefix, "/absolute"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed/./images") ==
             {:error, {:invalid_path_prefix, "processed/./images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed//images") ==
             {:error, {:invalid_path_prefix, "processed//images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "~/cache") ==
             {:error, {:invalid_path_prefix, "~/cache"}}
  end

  test "writes and reads body and metadata under hash-partitioned paths", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert FileSystem.put(cache_key, entry(), root: root, path_prefix: "processed") == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root, path_prefix: "processed")

    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]
    assert File.exists?(Path.join([root, "processed", "ab", "cd", cache_key.hash <> ".body"]))
    assert File.exists?(Path.join([root, "processed", "ab", "cd", cache_key.hash <> ".meta"]))
  end

  test "missing metadata or body is a miss", %{root: root} do
    cache_key = key("123456" <> String.duplicate("a", 58))
    assert FileSystem.get(cache_key, root: root) == :miss

    dir = Path.join([root, "12", "34"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, cache_key.hash <> ".body"), "body")

    assert FileSystem.get(cache_key, root: root) == :miss

    meta_only_key = key("223456" <> String.duplicate("a", 58))
    meta_only_dir = Path.join([root, "22", "34"])
    File.mkdir_p!(meta_only_dir)

    File.write!(
      Path.join(meta_only_dir, meta_only_key.hash <> ".meta"),
      :erlang.term_to_binary(%{
        metadata_version: 1,
        content_type: "image/webp",
        headers: [],
        created_at: "2026-04-29T10:15:00Z",
        body_byte_size: 4
      })
    )

    assert FileSystem.get(meta_only_key, root: root) == :miss
  end

  test "invalid metadata is a miss", %{root: root} do
    cache_key = key("654321" <> String.duplicate("b", 58))
    dir = Path.join([root, "65", "43"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, cache_key.hash <> ".body"), "body")
    File.write!(Path.join(dir, cache_key.hash <> ".meta"), :erlang.term_to_binary(%{metadata_version: 999}))

    assert FileSystem.get(cache_key, root: root) == :miss
  end

  test "invalid metadata is an error when fail_on_cache_error is true", %{root: root} do
    cache_key = key("754321" <> String.duplicate("b", 58))
    dir = Path.join([root, "75", "43"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, cache_key.hash <> ".body"), "body")
    File.write!(Path.join(dir, cache_key.hash <> ".meta"), :erlang.term_to_binary(%{metadata_version: 999}))

    assert FileSystem.get(cache_key, root: root, fail_on_cache_error: true) ==
             {:error, {:invalid_metadata, :version_mismatch}}
  end

  test "body byte-size mismatch is a miss", %{root: root} do
    cache_key = key("bbbbbb" <> String.duplicate("c", 58))
    assert FileSystem.put(cache_key, entry("12345"), root: root) == :ok

    dir = Path.join([root, "bb", "bb"])
    File.write!(Path.join(dir, cache_key.hash <> ".body"), "123")

    assert FileSystem.get(cache_key, root: root) == :miss
  end

  test "cleans temp files when metadata write fails", %{root: root} do
    cache_key = key("cccccc" <> String.duplicate("d", 58))
    dir = Path.join([root, "cc", "cc"])
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, cache_key.hash <> ".meta"))

    assert {:error, _reason} = FileSystem.put(cache_key, entry(), root: root)
    refute File.ls!(dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
  end

  test "concurrent puts for the same key leave a readable entry", %{root: root} do
    cache_key = key("dddddd" <> String.duplicate("e", 58))

    results =
      ["body-one", "body-two"]
      |> Enum.map(fn body ->
        Task.async(fn -> FileSystem.put(cache_key, entry(body), root: root) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body in ["body-one", "body-two"]
  end
end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/cache/file_system_test.exs
```

Expected: failure because `ImagePlug.Cache.FileSystem` is not defined.

- [ ] **Step 3: Add the filesystem adapter**

Create `lib/image_plug/cache/file_system.ex`:

```elixir
defmodule ImagePlug.Cache.FileSystem do
  @moduledoc """
  Filesystem cache adapter for complete encoded image responses.
  """

  @behaviour ImagePlug.Cache

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key

  @metadata_schema_version 1

  @impl ImagePlug.Cache
  def get(%Key{} = key, opts) do
    with {:ok, paths} <- paths(key, opts),
         {:ok, metadata_binary} <- read_cache_file(paths.meta_path),
         {:ok, metadata} <- decode_metadata(metadata_binary, opts),
         {:ok, body} <- read_cache_file(paths.body_path),
         :ok <- validate_body_size(body, metadata.body_byte_size, opts),
         {:ok, entry} <-
           Entry.new(
             body: body,
             content_type: metadata.content_type,
             headers: metadata.headers,
             created_at: metadata.created_at
           ) do
      {:hit, entry}
    else
      :miss -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  @impl ImagePlug.Cache
  def put(%Key{} = key, %Entry{} = entry, opts) do
    with {:ok, paths} <- paths(key, opts),
         :ok <- File.mkdir_p(paths.dir),
         :ok <- write_temp(paths.body_tmp_path, entry.body),
         :ok <- write_temp(paths.meta_tmp_path, encode_metadata(entry)),
         :ok <- File.rename(paths.body_tmp_path, paths.body_path),
         :ok <- File.rename(paths.meta_tmp_path, paths.meta_path) do
      :ok
    else
      {:error, reason} ->
        cleanup_temp_files(key, opts)
        {:error, reason}
    end
  end

  @doc false
  def paths(%Key{hash: hash}, opts) do
    with {:ok, root} <- root(opts),
         {:ok, prefix_segments} <- path_prefix(opts),
         <<a::binary-size(2), b::binary-size(2), _rest::binary>> <- hash do
      dir = Path.join([root | prefix_segments ++ [a, b]])
      body_path = Path.join(dir, hash <> ".body")
      meta_path = Path.join(dir, hash <> ".meta")
      unique = System.unique_integer([:positive, :monotonic])
      body_tmp_path = Path.join(dir, ".#{hash}.#{unique}.body.tmp")
      meta_tmp_path = Path.join(dir, ".#{hash}.#{unique}.meta.tmp")

      paths = %{
        root: root,
        dir: dir,
        body_path: body_path,
        meta_path: meta_path,
        body_tmp_path: body_tmp_path,
        meta_tmp_path: meta_tmp_path
      }

      if Enum.all?(Map.values(Map.take(paths, [:dir, :body_path, :meta_path, :body_tmp_path, :meta_tmp_path])), &under_root?(&1, root)) do
        {:ok, paths}
      else
        {:error, :path_escaped_root}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:invalid_hash, hash}}
    end
  end

  defp root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) ->
        if Path.type(root) == :absolute do
          {:ok, Path.expand(root)}
        else
          {:error, {:invalid_root, root}}
        end

      {:ok, root} ->
        {:error, {:invalid_root, root}}

      :error ->
        {:error, {:missing_required_option, :root}}
    end
  end

  defp path_prefix(opts) do
    prefix = Keyword.get(opts, :path_prefix, "")

    cond do
      prefix in [nil, ""] ->
        {:ok, []}

      not is_binary(prefix) ->
        {:error, {:invalid_path_prefix, prefix}}

      Path.type(prefix) == :absolute ->
        {:error, {:invalid_path_prefix, prefix}}

      String.contains?(prefix, "//") ->
        {:error, {:invalid_path_prefix, prefix}}

      true ->
        segments = Path.split(prefix)

        if Enum.any?(segments, &(&1 in ["", ".", ".."] or String.starts_with?(&1, "~"))) do
          {:error, {:invalid_path_prefix, prefix}}
        else
          {:ok, segments}
        end
    end
  end

  defp read_cache_file(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_temp(path, binary) do
    case File.write(path, binary, [:binary, :exclusive]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_metadata(%Entry{} = entry) do
    {:ok, headers} = Entry.normalize_headers(entry.headers)

    :erlang.term_to_binary(%{
      metadata_version: @metadata_schema_version,
      content_type: entry.content_type,
      headers: headers,
      created_at: DateTime.to_iso8601(entry.created_at),
      body_byte_size: byte_size(entry.body)
    })
  end

  defp decode_metadata(binary, opts) do
    metadata = :erlang.binary_to_term(binary)

    with %{metadata_version: @metadata_schema_version} <- metadata,
         content_type when is_binary(content_type) <- Map.get(metadata, :content_type),
         headers when is_list(headers) <- Map.get(metadata, :headers),
         true <- Enum.all?(headers, &valid_header?/1),
         created_at when is_binary(created_at) <- Map.get(metadata, :created_at),
         {:ok, created_at, 0} <- DateTime.from_iso8601(created_at),
         body_byte_size when is_integer(body_byte_size) and body_byte_size >= 0 <-
           Map.get(metadata, :body_byte_size) do
      {:ok,
       %{
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size
       }}
    else
      _ -> metadata_miss(opts, :version_mismatch)
    end
  rescue
    _ -> metadata_miss(opts, :decode_failed)
  end

  defp valid_header?({key, value}) when is_binary(key) and is_binary(value), do: true
  defp valid_header?(_header), do: false

  defp validate_body_size(body, expected_size, opts) do
    if byte_size(body) == expected_size do
      :ok
    else
      metadata_miss(opts, :body_size_mismatch)
    end
  end

  defp metadata_miss(opts, reason) do
    if Keyword.get(opts, :fail_on_cache_error, false) do
      {:error, {:invalid_metadata, reason}}
    else
      :miss
    end
  end

  defp cleanup_temp_files(%Key{} = key, opts) do
    with {:ok, paths} <- paths(key, opts),
         {:ok, entries} <- File.ls(paths.dir) do
      Enum.each(entries, fn entry ->
        if String.starts_with?(entry, "." <> key.hash) and String.ends_with?(entry, ".tmp") do
          File.rm(Path.join(paths.dir, entry))
        end
      end)
    end
  end

  defp under_root?(path, root) do
    expanded_path = Path.expand(path)
    expanded_path == root or String.starts_with?(expanded_path, root <> "/")
  end
end
```

- [ ] **Step 4: Run the focused tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug/cache/file_system_test.exs
```

Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add lib/image_plug/cache/file_system.ex test/image_plug/cache/file_system_test.exs
git commit -m "feat: add filesystem cache adapter"
```

### Task 5: Add Cache Property Tests

**Files:**
- Create: `test/image_plug/cache/key_property_test.exs`
- Create: `test/image_plug/cache/entry_property_test.exs`
- Create: `test/image_plug/cache/file_system_property_test.exs`
- Modify: `lib/image_plug/cache/file_system.ex`

- [ ] **Step 1: Write cache key property tests**

Create `test/image_plug/cache/key_property_test.exs`:

```elixir
defmodule ImagePlug.Cache.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  property "cache key serialization is deterministic for canonical material" do
    check all material <- key_material(),
              max_runs: 100 do
      assert Key.serialize_material(material) == Key.serialize_material(material)
    end
  end

  property "nested map ordering does not affect serialized key material" do
    check all origin <- origin_identity(),
              width <- pixel_dimension(),
              height <- pixel_dimension(),
              max_runs: 100 do
      material_one = [
        schema_version: 1,
        origin_identity: origin,
        operations: [
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          width: width,
          height: height,
          extra: %{b: 2, a: 1}
        ],
        output: [format: :webp, accept: nil],
        selected_headers: [],
        selected_cookies: []
      ]

      material_two = [
        selected_cookies: [],
        selected_headers: [],
        output: [accept: nil, format: :webp],
        operations: [
          extra: %{a: 1, b: 2},
          height: height,
          width: width,
          source_path: ["images", "cat.jpg"],
          source_kind: :plain
        ],
        origin_identity: origin,
        schema_version: 1
      ]

      assert Key.serialize_material(material_one) == Key.serialize_material(material_two)
    end
  end

  property "excluded request fields do not affect the cache key" do
    check all request <- cacheable_request(),
              signature <- string(:alphanumeric, min_length: 1, max_length: 24),
              query <- string(:alphanumeric, max_length: 24),
              ignored_header_value <- string(:alphanumeric, max_length: 24),
              ignored_cookie_value <- string(:alphanumeric, max_length: 24),
              max_runs: 100 do
      origin = "https://origin.test/images/cat.jpg"

      conn_one = conn(:get, "/_/plain/images/cat.jpg")

      conn_two =
        :get
        |> conn("/#{signature}/plain/changed/path.jpg?#{query}")
        |> put_req_header("x-ignored", ignored_header_value)
        |> put_req_header("cookie", "ignored=#{ignored_cookie_value}")

      request_two = %ProcessingRequest{request | signature: signature}

      assert Key.build(conn_one, request, origin).hash == Key.build(conn_two, request_two, origin).hash
    end
  end

  property "included origin identity and output format change the cache key" do
    check all request <- cacheable_request(format: :webp),
              origin_a <- origin_identity(),
              origin_b <- origin_identity(),
              origin_a != origin_b,
              max_runs: 100 do
      conn = conn(:get, "/_/format:webp/plain/images/cat.jpg")

      origin_key_a = Key.build(conn, request, origin_a)
      origin_key_b = Key.build(conn, request, origin_b)
      png_key = Key.build(conn, %ProcessingRequest{request | format: :png}, origin_a)

      refute origin_key_a.hash == origin_key_b.hash
      refute origin_key_a.hash == png_key.hash
    end
  end

  property "selected headers and cookies affect the cache key when configured" do
    check all header_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_a != header_value_b,
              cookie_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_a != cookie_value_b,
              max_runs: 100 do
      request = request(format: :webp)
      origin = "https://origin.test/images/cat.jpg"

      conn_a =
        :get
        |> conn("/_/format:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_a)
        |> put_req_header("cookie", "tenant=#{cookie_value_a}")

      conn_b =
        :get
        |> conn("/_/format:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_b)
        |> put_req_header("cookie", "tenant=#{cookie_value_b}")

      opts = [key_headers: ["accept-language"], key_cookies: ["tenant"]]

      refute Key.build(conn_a, request, origin, opts).hash == Key.build(conn_b, request, origin, opts).hash
    end
  end

  property "Accept normalization is idempotent" do
    check all accept <- accept_header(),
              max_runs: 100 do
      assert Key.normalize_accept(Key.normalize_accept(accept)) == Key.normalize_accept(accept)
    end
  end

  property "Accept normalization preserves distinct media-range order" do
    check all first <- media_range(),
              second <- media_range(),
              first != second,
              max_runs: 100 do
      first_order = Key.normalize_accept("#{first},#{second}")
      second_order = Key.normalize_accept("#{second},#{first}")

      refute first_order == second_order
    end
  end

  defp key_material do
    map({origin_identity(), cacheable_request(), member_of([:auto, :webp, :avif, :jpeg, :png])}, fn
      {origin, request, format} ->
        [
          schema_version: 1,
          origin_identity: origin,
          operations: [
            source_kind: request.source_kind,
            source_path: request.source_path,
            width: request.width,
            height: request.height,
            fit: request.fit,
            focus: request.focus
          ],
          output: [format: format, accept: nil],
          selected_headers: [],
          selected_cookies: []
        ]
    end)
  end

  defp cacheable_request(overrides \\ []) do
    map({source_path(), maybe_dimension(), maybe_dimension(), member_of([nil, :cover, :contain, :fill, :inside])}, fn
      {source_path, width, height, fit} ->
        request(Keyword.merge([source_path: source_path, width: width, height: height, fit: fit], overrides))
    end)
  end

  defp request(attrs) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          format: :webp
        ],
        attrs
      )
    )
  end

  defp origin_identity do
    map(source_path(), fn path -> "https://origin.test/#{Enum.join(path, "/")}" end)
  end

  defp source_path, do: list_of(path_segment(), min_length: 1, max_length: 4)
  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
  defp maybe_dimension, do: one_of([constant(nil), pixel_dimension()])
  defp pixel_dimension, do: map(integer(1..10_000), &{:pixels, &1})

  defp accept_header do
    map(list_of(media_range_with_optional_quality(), min_length: 0, max_length: 5), &Enum.join(&1, ","))
  end

  defp media_range_with_optional_quality do
    one_of([
      media_range(),
      map({media_range(), integer(0..10)}, fn {range, q} -> "#{range}; q=#{q / 10}" end)
    ])
  end

  defp media_range do
    member_of(["image/avif", "image/webp", "image/jpeg", "image/png", "image/*", "*/*"])
  end
end
```

- [ ] **Step 2: Write cache entry property tests**

Create `test/image_plug/cache/entry_property_test.exs`:

```elixir
defmodule ImagePlug.Cache.EntryPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.Cache.Entry

  property "entry stores only lowercase allowlisted headers" do
    check all headers <- list_of(header(), max_length: 30),
              max_runs: 100 do
      {:ok, entry} =
        Entry.new(
          body: "body",
          content_type: "image/webp",
          headers: headers,
          created_at: ~U[2026-04-29 10:15:00Z]
        )

      assert Enum.all?(entry.headers, fn {name, _value} -> name in ["vary", "cache-control"] end)
      assert Enum.all?(entry.headers, fn {name, _value} -> name == String.downcase(name) end)
    end
  end

  property "allowed headers preserve relative input order" do
    check all headers <- list_of(header(), max_length: 30),
              max_runs: 100 do
      {:ok, entry} =
        Entry.new(
          body: "body",
          content_type: "image/webp",
          headers: headers,
          created_at: ~U[2026-04-29 10:15:00Z]
        )

      expected =
        headers
        |> Enum.flat_map(fn {name, value} ->
          normalized_name = String.downcase(name)

          if normalized_name in ["vary", "cache-control"] do
            [{normalized_name, value}]
          else
            []
          end
        end)

      assert entry.headers == expected
    end
  end

  defp header do
    map({header_name(), string(:alphanumeric, max_length: 24)}, fn {name, value} -> {name, value} end)
  end

  defp header_name do
    one_of([
      member_of(["vary", "Vary", "VARY", "cache-control", "Cache-Control", "CACHE-CONTROL"]),
      string(:alphanumeric, min_length: 1, max_length: 16)
    ])
  end
end
```

- [ ] **Step 3: Write filesystem property tests**

Create `test/image_plug/cache/file_system_property_test.exs`:

```elixir
defmodule ImagePlug.Cache.FileSystemPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.FileSystem
  alias ImagePlug.Cache.Key

  property "generated cache paths stay under the configured root" do
    check all hash <- sha256_hex(),
              prefix <- safe_prefix(),
              max_runs: 100 do
      root = unique_root()
      key = key(hash)

      assert {:ok, paths} = FileSystem.paths(key, root: root, path_prefix: prefix)

      assert Enum.all?(
               Map.values(Map.take(paths, [:dir, :body_path, :meta_path, :body_tmp_path, :meta_tmp_path])),
               &under_root?(&1, root)
             )
    end
  end

  property "unsafe path prefixes are rejected" do
    check all prefix <- unsafe_prefix(),
              max_runs: 100 do
      assert {:error, {:invalid_path_prefix, ^prefix}} =
               FileSystem.paths(key(), root: unique_root(), path_prefix: prefix)
    end
  end

  property "put followed by get round-trips valid entries" do
    check all hash <- sha256_hex(),
              body <- binary(max_length: 2_048),
              content_type <- member_of(["image/avif", "image/webp", "image/jpeg", "image/png"]),
              headers <- list_of(allowed_header(), max_length: 6),
              max_runs: 50 do
      root = unique_root()
      File.rm_rf!(root)

      try do
        cache_key = key(hash)

        entry =
          Entry.new!(
            body: body,
            content_type: content_type,
            headers: headers,
            created_at: ~U[2026-04-29 10:15:00Z]
          )

        assert :ok = FileSystem.put(cache_key, entry, root: root)
        assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
        assert cached_entry == entry
      after
        File.rm_rf!(root)
      end
    end
  end

  property "arbitrary metadata bytes do not crash get" do
    check all metadata_bytes <- binary(max_length: 2_048),
              body <- binary(max_length: 128),
              fail_on_cache_error? <- boolean(),
              max_runs: 100 do
      root = unique_root()
      File.rm_rf!(root)

      try do
        cache_key = key()
        assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
        File.mkdir_p!(paths.dir)
        File.write!(paths.body_path, body)
        File.write!(paths.meta_path, metadata_bytes)

        result = FileSystem.get(cache_key, root: root, fail_on_cache_error: fail_on_cache_error?)

        assert result == :miss or match?({:error, _reason}, result)
      after
        File.rm_rf!(root)
      end
    end
  end

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  defp sha256_hex do
    map(binary(length: 32), &Base.encode16(&1, case: :lower))
  end

  defp safe_prefix do
    one_of([
      constant(""),
      map(list_of(path_segment(), min_length: 1, max_length: 4), &Enum.join(&1, "/"))
    ])
  end

  defp unsafe_prefix do
    one_of([
      constant("../outside"),
      constant("processed/../outside"),
      constant("processed/./images"),
      constant("processed//images"),
      constant("/absolute"),
      constant("~/cache")
    ])
  end

  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)

  defp allowed_header do
    map({member_of(["vary", "Vary", "cache-control", "Cache-Control"]), string(:alphanumeric, max_length: 24)}, fn
      {name, value} -> {name, value}
    end)
  end

  defp unique_root do
    Path.join(System.tmp_dir!(), "image_plug_fs_cache_prop_#{System.unique_integer([:positive, :monotonic])}")
  end

  defp under_root?(path, root) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end
end
```

- [ ] **Step 4: Run the property tests to verify they fail or expose missing API**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_property_test.exs test/image_plug/cache/entry_property_test.exs test/image_plug/cache/file_system_property_test.exs
```

Expected: filesystem property tests fail if `ImagePlug.Cache.FileSystem.paths/2` is still private.

- [ ] **Step 5: Expose filesystem path construction for focused safety tests**

If `ImagePlug.Cache.FileSystem.paths/2` is not public yet, change this function in `lib/image_plug/cache/file_system.ex`:

```elixir
  defp paths(%Key{hash: hash}, opts) do
```

to:

```elixir
  @doc false
  def paths(%Key{hash: hash}, opts) do
```

Keep the existing `get/2`, `put/3`, and temp cleanup callers using `paths/2`.

- [ ] **Step 6: Run the property tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_property_test.exs test/image_plug/cache/entry_property_test.exs test/image_plug/cache/file_system_property_test.exs
```

Expected: all cache property tests pass.

- [ ] **Step 7: Run the full cache test slice**

Run:

```bash
mise exec -- mix test test/image_plug/cache test/image_plug/cache_test.exs
```

Expected: all cache tests and cache property tests pass.

- [ ] **Step 8: Commit Task 5**

Run:

```bash
git add lib/image_plug/cache/file_system.ex test/image_plug/cache/key_property_test.exs test/image_plug/cache/entry_property_test.exs test/image_plug/cache/file_system_property_test.exs
git commit -m "test: add cache property coverage"
```

### Task 6: Refactor ImagePlug For Cache-Enabled Pipeline

**Files:**
- Modify: `test/image_plug_test.exs`
- Modify: `lib/image_plug.ex`

- [ ] **Step 1: Add integration helpers and cache pipeline tests**

Append these helper modules near the existing helper modules in `test/image_plug_test.exs`:

```elixir
  defmodule CacheProbe do
    alias ImagePlug.Cache.Entry
    alias ImagePlug.Cache.Key

    def get(%Key{} = key, opts) do
      send(self(), {:cache_get, key})
      Keyword.get(opts, :get_result, :miss)
    end

    def put(%Key{} = key, %Entry{} = entry, opts) do
      send(self(), {:cache_put, key, entry})
      Keyword.get(opts, :put_result, :ok)
    end
  end

  defmodule CountingOriginImage do
    def call(conn, _) do
      send(self(), :origin_was_called)
      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule StreamingOnlyImage do
    def stream!(_image, suffix: ".jpg") do
      send(self(), :stream_encoder_called)
      ["streamed jpeg"]
    end

    def write!(_image, :memory, suffix: ".jpg") do
      send(self(), :memory_encoder_called)
      raise "cache-enabled memory encoder should not be called"
    end
  end
```

Append these tests to `test/image_plug_test.exs`:

```elixir
  test "no cache configured preserves the streaming response path" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        image_module: StreamingOnlyImage
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "streamed jpeg"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :origin_was_called
    assert_received :stream_encoder_called
    refute_received :memory_encoder_called
  end

  test "does not touch cache when parser validation fails" do
    conn = conn(:get, "/_/w:0/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled],
        cache: {CacheProbe, []}
      )

    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache when planner validation fails" do
    conn = conn(:get, "/_/fit:cover/w:100/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled],
        cache: {CacheProbe, []}
      )

    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "serves cache hits without fetching origin" do
    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached image",
      content_type: "image/webp",
      headers: [{"Vary", "Accept"}, {"connection", "close"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/format:webp/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled],
        cache: {CacheProbe, get_result: {:hit, cached_entry}}
      )

    assert conn.status == 200
    assert conn.resp_body == "cached image"
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert get_resp_header(conn, "connection") == []
    assert_received {:cache_get, key}
    assert key.material[:origin_identity] == "http://origin.test/images/cat-300.jpg"
    refute_received :origin_was_called
  end

  test "cache misses process origin response, write entry, and send encoded body" do
    conn =
      :get
      |> conn("/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, []}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received :origin_was_called
    assert_received {:cache_get, key}
    assert_received {:cache_put, ^key, entry}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == []
    assert entry.body == conn.resp_body
  end

  test "cache misses for auto output store vary header and selected content type" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, []}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received {:cache_put, _key, entry}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == [{"vary", "Accept"}]
  end
```

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: cache tests fail because `ImagePlug.call/2` ignores `:cache`.

- [ ] **Step 3: Refactor `ImagePlug` aliases and top-level call flow**

In `lib/image_plug.ex`, add these aliases with the existing aliases:

```elixir
  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
```

Replace `call/2` with this version:

```elixir
  def call(%Plug.Conn{} = conn, opts) do
    param_parser = Keyword.fetch!(opts, :param_parser)
    pipeline_planner = Keyword.get(opts, :pipeline_planner, PipelinePlanner)

    with {:ok, request} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, chain} <- pipeline_planner.plan(request) |> wrap_planner_error(),
         {:ok, origin_identity} <- origin_identity(request, opts) |> wrap_origin_error() do
      dispatch_request(conn, request, chain, origin_identity, opts)
    else
      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:planner, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)
    end
  end
```

- [ ] **Step 4: Add dispatch, origin identity, and normal processing helpers**

Add these private functions below `call/2`:

```elixir
  defp dispatch_request(conn, request, chain, origin_identity, opts) do
    case Cache.lookup(conn, request, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, request, chain, origin_identity, opts)

      {:hit, _key, %Entry{} = entry} ->
        send_cache_entry(conn, entry)

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, request, chain, origin_identity, key, opts)

      {:error, {:cache_read, error}} ->
        send_cache_error(conn, error)
    end
  end

  defp process_uncached(conn, request, chain, origin_identity, opts) do
    with {:ok, final_state} <- process_origin(request, chain, origin_identity, opts) do
      send_image(conn, final_state, opts)
    else
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)

      {:error, {:input_limit, error}} ->
        send_input_limit_error(conn, error)
    end
  end

  defp process_cache_miss(conn, request, chain, origin_identity, key, opts) do
    with {:ok, final_state} <- process_origin(request, chain, origin_identity, opts),
         {:ok, entry} <- encode_cache_entry(conn, final_state, opts),
         :ok <- Cache.put(key, entry, opts) do
      send_cache_entry(conn, entry)
    else
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)

      {:error, {:input_limit, error}} ->
        send_input_limit_error(conn, error)

      {:error, :not_acceptable} ->
        send_not_acceptable(conn)

      {:error, {:encode, exception, stacktrace}} ->
        handle_encode_exception(exception, stacktrace, conn)

      {:error, {:cache_write, error}} ->
        send_cache_error(conn, error)
    end
  end

  defp origin_identity(%ProcessingRequest{source_kind: :plain, source_path: source_path}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    Origin.build_url(root_url, source_path)
  end

  defp origin_identity(%ProcessingRequest{source_kind: source_kind}, _opts) do
    {:error, {:unsupported_source_kind, source_kind}}
  end

  defp process_origin(request, chain, origin_identity, opts) do
    with {:ok, origin_response} <- fetch_origin(request, origin_identity, opts) |> wrap_origin_error(),
         {:ok, image} <-
           Image.from_binary(origin_response.body, access: :random, fail_on: :error)
           |> wrap_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain) do
      {:ok, final_state}
    end
  end
```

- [ ] **Step 5: Replace origin fetch helper**

Replace the existing `fetch_origin/2` clauses in `lib/image_plug.ex` with:

```elixir
  defp fetch_origin(%ProcessingRequest{source_kind: :plain}, origin_identity, opts) do
    Origin.fetch(origin_identity, origin_req_options(opts))
  end
```

- [ ] **Step 6: Add cache entry encoding and sending helpers**

Add these private functions near `send_image/3`:

```elixir
  defp encode_cache_entry(%Plug.Conn{} = conn, %TransformState{image: image} = state, opts) do
    with {:ok, mime_type} <- output_mime_type(conn, state) do
      suffix = OutputNegotiation.suffix!(mime_type)
      image_module = Keyword.get(opts, :image_module, Image)

      try do
        {:ok,
         Entry.new!(
           body: image_module.write!(image, :memory, suffix: suffix),
           content_type: mime_type,
           headers: response_headers_for_state(state),
           created_at: DateTime.utc_now()
         )}
      rescue
        exception -> {:error, {:encode, exception, __STACKTRACE__}}
      end
    end
  end

  defp response_headers_for_state(%TransformState{output: :auto}), do: [{"vary", "Accept"}]
  defp response_headers_for_state(%TransformState{}), do: []

  defp send_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry) do
    {:ok, headers} = Entry.normalize_headers(entry.headers)

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn ->
        put_resp_header(conn, key, value)
      end)

    conn
    |> put_resp_content_type(entry.content_type, nil)
    |> send_resp(200, entry.body)
  end

  defp send_cache_error(%Plug.Conn{} = conn, error) do
    Logger.error("cache_error: #{inspect(error)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "cache error")
  end
```

- [ ] **Step 7: Run the focused integration tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: all `ImagePlug.ImagePlugTest` tests pass.

- [ ] **Step 8: Commit Task 6**

Run:

```bash
git add lib/image_plug.ex test/image_plug_test.exs
git commit -m "feat: integrate cache pipeline"
```

### Task 7: Add Cache Error Policy Integration Tests

**Files:**
- Modify: `test/image_plug_test.exs`
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/cache.ex`

- [ ] **Step 1: Add integration tests for fail-open and fail-closed policy**

Append these tests to `test/image_plug_test.exs`:

```elixir
  test "cache read errors fail open by default and continue to origin" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, get_result: {:error, :read_failed}}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache read errors fail before origin when fail_on_cache_error is true" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, get_result: {:error, :read_failed}, fail_on_cache_error: true}
      )

    assert conn.status == 500
    assert conn.resp_body == "cache error"
    refute_received :origin_was_called
  end

  test "cache write errors fail open by default and still return response" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, put_result: {:error, :write_failed}}
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received :origin_was_called
  end

  test "cache write errors fail before response when fail_on_cache_error is true" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, put_result: {:error, :write_failed}, fail_on_cache_error: true}
      )

    assert conn.status == 500
    assert conn.resp_body == "cache error"
    assert_received :origin_was_called
  end

  test "cache writes over max_body_bytes are skipped and still return response" do
    conn =
      conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, max_body_bytes: 1}
      )

    assert conn.status == 200
    assert byte_size(conn.resp_body) > 1
    refute_received {:cache_put, _key, _entry}
  end

  test "unsuccessful processed responses are not cached" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/*;q=0")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache: {CacheProbe, []}
      )

    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
    assert_received :origin_was_called
    refute_received {:cache_put, _key, _entry}
  end
```

- [ ] **Step 2: Run the focused integration tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: tests pass if Tasks 3 and 5 already applied the required policy. If a test fails, inspect the failure before editing.

- [ ] **Step 3: Fix policy mismatch if the focused tests fail**

If `cache writes over max_body_bytes are skipped` fails because `process_cache_miss/6` only accepts `:ok`, change this line in `lib/image_plug.ex`:

```elixir
         :ok <- Cache.put(key, entry, opts) do
```

to:

```elixir
         put_result when put_result in [:ok, :skipped] <- Cache.put(key, entry, opts) do
```

If fail-open read or write tests fail, confirm `lib/image_plug/cache.ex` has these exact branches:

```elixir
  defp handle_read_error(reason, key, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_read, reason}}
    else
      Logger.warning("cache read error: #{inspect(reason)}")
      {:miss, key}
    end
  end

  defp handle_write_error(reason, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_write, reason}}
    else
      Logger.warning("cache write error: #{inspect(reason)}")
      :ok
    end
  end
```

- [ ] **Step 4: Run the focused integration tests again**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: all `ImagePlug.ImagePlugTest` tests pass.

- [ ] **Step 5: Commit Task 7**

Run:

```bash
git add lib/image_plug.ex lib/image_plug/cache.ex test/image_plug_test.exs
git commit -m "test: cover cache error policy"
```

### Task 8: Wire Real Filesystem Cache Through Integration

**Files:**
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Add an integration test using `ImagePlug.Cache.FileSystem`**

Append this test to `test/image_plug_test.exs`:

```elixir
  test "filesystem cache persists processed responses across requests" do
    cache_root = Path.join(System.tmp_dir!(), "image_plug_integration_cache_#{System.unique_integer([:positive])}")
    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    try do
      opts = [
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CountingOriginImage],
        cache:
          {ImagePlug.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: [],
           fail_on_cache_error: false}
      ]

      first_conn =
        conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
        |> ImagePlug.call(opts)

      assert first_conn.status == 200
      assert_received :origin_was_called

      second_conn =
        conn(:get, "/_/format:jpeg/plain/images/cat-300.jpg")
        |> ImagePlug.call(opts)

      assert second_conn.status == 200
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_was_called
    after
      File.rm_rf!(cache_root)
    end
  end
```

- [ ] **Step 2: Run the focused integration test**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: all `ImagePlug.ImagePlugTest` tests pass.

- [ ] **Step 3: Commit Task 8**

Run:

```bash
git add test/image_plug_test.exs
git commit -m "test: cover filesystem cache integration"
```

### Task 9: Document Public Cache Configuration

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add README cache documentation**

In `README.md`, after the usage example section, add:

````markdown
## Filesystem Cache

ImagePlug can cache processed image responses on the local filesystem:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    param_parser: ImagePlug.ParamParser.Native,
    cache: {ImagePlug.Cache.FileSystem,
      root: "/var/cache/image_plug",
      path_prefix: "processed",
      max_body_bytes: 10_000_000,
      key_headers: [],
      key_cookies: [],
      fail_on_cache_error: false
    }
  ]
```

The cache stores complete encoded responses after successful processing. Cache lookup happens only after the request parses, the pipeline plans, and the origin URL is resolved. Invalid requests still return `400` before origin fetch and before cache access. Parser, planner, origin fetch, decode, transform, negotiation, and encode errors are never cached.

Cache keys include the resolved origin URL, canonical processing request fields, configured key headers, configured key cookies, and normalized `Accept` material for `format:auto`. Cache keys exclude request signatures, the raw request path, query strings, and unconfigured headers or cookies.

Cache key material includes a schema version and is serialized as plain primitive keyword data with recursive canonicalization plus deterministic Erlang external term encoding before hashing. This keeps key ordering, header casing, cookie ordering, and future key changes explicit. `format:auto` `Accept` normalization preserves media-range order and q-values.

Cached response headers are restricted to `vary` and `cache-control`, and header names are normalized to lowercase before storage and before sending cached responses. Duplicate allowed headers are preserved in input order.

`ImagePlug.Cache.FileSystem` requires an absolute `:root`. The optional `:path_prefix` must be relative and must not contain backslashes, empty segments from duplicate slashes, `.`, `..`, or `~`-prefixed path segments. Cache file paths are derived from ImagePlug-generated hashes, not from request paths, origin URLs, headers, or cookies.

Filesystem metadata has its own `metadata_version`, independent of the cache key schema version. Invalid metadata is treated as a miss by default and as a cache read error when `fail_on_cache_error: true`.

The filesystem cache root is trusted local configuration. ImagePlug expands and validates generated paths under the configured root, but it does not protect against a local actor replacing directories inside the cache root with symlinks.

By default, cache read and write errors are logged and the request continues without cached data. Set `fail_on_cache_error: true` to fail closed on cache read or write errors. Bodies larger than `max_body_bytes` are returned to the client but skipped for cache storage.
````

- [ ] **Step 2: Run all tests**

Run:

```bash
mise exec -- mix test
```

Expected: the full test suite passes.

- [ ] **Step 3: Run formatter**

Run:

```bash
mise exec -- mix format
```

Expected: formatter completes without errors.

- [ ] **Step 4: Run all tests again after formatting**

Run:

```bash
mise exec -- mix test
```

Expected: the full test suite passes.

- [ ] **Step 5: Commit Task 9**

Run:

```bash
git add README.md
git commit -m "docs: document filesystem cache"
```

## Final Verification

- [ ] **Step 1: Confirm the worktree only contains intended changes**

Run:

```bash
git status --short
```

Expected: no uncommitted changes.

- [ ] **Step 2: Run the full suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 3: Run compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: compilation succeeds with no warnings.

## Self-Review

- Spec coverage: Tasks 1-3 define adapter-independent entries, entry field validation, duplicate header preservation, cached header allowlisting, deterministic primitive cache-key serialization, key schema versioning, order-preserving `Accept` normalization, and fail-open/fail-closed policy through `fail_on_cache_error`. Task 4 covers filesystem path safety, trusted-root symlink posture, independent metadata versioning, metadata/body validity, invalid metadata policy, atomic rename order, missing/invalid entry misses, concurrent puts, temp cleanup, and traversal-shaped configuration. Task 5 adds property coverage for key determinism/exclusions/inclusions, `Accept` normalization, header normalization, path safety, filesystem round-trips, and corrupt metadata. Tasks 6-8 cover default no-cache streaming behavior, pipeline placement, origin identity, cache hit/miss behavior, `format:auto` `Accept` keying, non-success response cache skips, max-body write skips, and fail-open/fail-closed behavior. Task 9 documents public configuration and operational semantics.
- Placeholder scan: the plan uses concrete tests, modules, commands, expected outputs, and commit points. It does not use unresolved placeholders.
- Type consistency: `ImagePlug.Cache.Key.build/4`, `ImagePlug.Cache.lookup/4`, `ImagePlug.Cache.put/3`, `ImagePlug.Cache.FileSystem.get/2`, and `ImagePlug.Cache.FileSystem.put/3` are used consistently across tests and implementation snippets.
