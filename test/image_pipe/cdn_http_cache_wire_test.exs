defmodule ImagePipe.CDNHTTPCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  defmodule StableSource do
    @behaviour ImagePipe.Source

    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :stable_test)}

    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :path, root: "wire", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{
           byte_identity: {:strong, [kind: :path, root: "wire", path: path]},
           stable?: true
         },
         fetch: [path: path]
       }}
    end

    def fetch(_resolved, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test_pid), :source_fetch_called)
      {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
    end
  end

  defmodule CacheProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      :miss
    end

    def open_sink(%Key{}, metadata, opts),
      do: {:ok, %{metadata: metadata, chunks: [], opts: opts}}

    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = %Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }

      send(Keyword.fetch!(state.opts, :test_pid), {:cache_put, entry})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CacheHitProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def open_sink(_key, _metadata, _opts), do: raise("cache hit should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache hit should not write")
    def commit_sink(_state, _opts), do: raise("cache hit should not write")
    def abort_sink(_state, _opts), do: :ok
  end

  setup do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        test_pid: self(),
        http_cache: [mode: :enabled]
      )

    [opts: opts]
  end

  test "stable public route emits cache-control and etag", %{opts: opts} do
    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "matching if-none-match returns before cache lookup and source fetch", %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    [etag] = get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [etag]
    assert get_resp_header(conn, "content-type") == []
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "existing vary is merged in the final response", %{opts: opts} do
    conn =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("accept", "image/webp")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
  end

  test "request cookie does not change generated headers or source fetch", %{opts: opts} do
    without_cookie = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)
    [etag] = get_resp_header(without_cookie, "etag")

    flush_messages()

    with_cookie =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_req_header("cookie", "session=private")
      |> ImagePipe.Plug.call(opts)

    assert get_resp_header(with_cookie, "etag") == [etag]
    refute "cookie" in vary_tokens(with_cookie)
    assert_received :source_fetch_called
  end

  test "response cookies suppress generated public cache headers", %{opts: opts} do
    conn =
      :get
      |> conn("/_/plain/beach.jpg")
      |> put_resp_cookie("session", "abc")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["max-age=0, private, must-revalidate"]
    assert get_resp_header(conn, "etag") == []
    assert get_resp_header(conn, "set-cookie") != []
  end

  test "internal cache hit returns 200 with current prepared etag" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn = ImagePipe.Plug.call(conn(:get, "/_/plain/beach.jpg"), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert [etag] = get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"ip1-")
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    refute_received :source_fetch_called
  end

  test "transform option order variants produce the same etag", %{opts: opts} do
    left =
      ImagePipe.Plug.call(
        conn(:get, "/_/rs:fill:0:400:0/c:0.5:0.5/plain/beach.jpg"),
        opts
      )

    right =
      ImagePipe.Plug.call(
        conn(:get, "/_/c:0.5:0.5/rs:fill:0:400:0/plain/beach.jpg"),
        opts
      )

    assert get_resp_header(left, "etag") == get_resp_header(right, "etag")
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp vary_tokens(conn) do
    conn
    |> get_resp_header("vary")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
  end
end
