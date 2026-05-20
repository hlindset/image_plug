defmodule ImagePlug.ImgproxyWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.SourceTest.CredentialProvider
  alias ImagePlug.SourceTest.FoobarTranslator
  alias ImagePlug.SourceTest.PlugCustomAdapter
  alias ImagePlug.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch
  alias Vix.Vips.Image, as: VipsImage

  defmodule SvgOriginImage do
    @moduledoc false

    def init(opts), do: opts

    def call(conn, opts) do
      opts
      |> Keyword.fetch!(:test_pid)
      |> send(:origin_fetch)

      body = """
      <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 20 20">
        <rect width="20" height="20" fill="red"/>
      </svg>
      """

      conn
      |> Plug.Conn.put_resp_content_type("image/svg+xml")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  @default_opts [
    parser: ImagePlug.Parser.Imgproxy,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  test "equivalent imgproxy option order shares filesystem cache through real Plug requests" do
    {opts, cache_root} = cached_opts()

    try do
      first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

      assert first_conn.status == 200
      assert content_type(first_conn) == ["image/jpeg"]
      assert dimensions(first_conn) == {120, 90}
      assert_received :origin_fetch

      second_conn = call_imgproxy("/_/f:jpeg/h:90/rt:force/w:120/plain/images/beach.jpg", opts)

      assert second_conn.status == 200
      assert content_type(second_conn) == ["image/jpeg"]
      assert dimensions(second_conn) == {120, 90}
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "encoded path source succeeds through a real Plug request" do
    encoded = encoded_source("images/beach.jpg")

    conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}", @default_opts)

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {120, 90}
    assert byte_size(conn.resp_body) > 0
  end

  test "automatic output negotiates modern formats from Accept and sets Vary" do
    cases = [
      {"image/avif,image/webp", "image/avif"},
      {"image/webp", "image/webp"},
      {"image/avif;q=0,image/*;q=1", "image/webp"}
    ]

    for {accept, expected_content_type} <- cases do
      conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(@default_opts, accept)

      assert conn.status == 200
      assert content_type(conn) == [expected_content_type]
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert byte_size(conn.resp_body) > 0
    end
  end

  test "explicit output formats bypass Accept and do not set Vary" do
    cases = [
      {"/_/f:webp/plain/images/beach.jpg", "image/webp"},
      {"/_/f:jpeg/plain/images/beach.jpg", "image/jpeg"},
      {"/_/plain/images/beach.jpg@webp", "image/webp"}
    ]

    for {path, expected_content_type} <- cases do
      conn = call_imgproxy(path, @default_opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == [expected_content_type]
      assert get_resp_header(conn, "vary") == []
      assert byte_size(conn.resp_body) > 0
    end
  end

  test "encoded output suffix bypasses Accept negotiation and does not set Vary" do
    encoded = encoded_source("images/beach.jpg")

    conn = call_imgproxy("/_/f:jpeg/#{encoded}.webp", @default_opts, "image/avif,image/webp")

    assert conn.status == 200
    assert content_type(conn) == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
    assert byte_size(conn.resp_body) > 0
  end

  test "automatic output rejects decoded SVG source responses as unsupported images" do
    if svg_supported?() do
      conn =
        "/_/plain/images/vector.svg"
        |> call_imgproxy(svg_origin_opts(), "image/avif,image/webp")

      assert conn.status == 415
      assert conn.resp_body == "source response is not a supported image"
      assert get_resp_header(conn, "vary") == ["Accept"]
      assert_received {:cache_lookup, _key}
      assert_received :origin_fetch
      refute_received {:cache_put, _key, _entry}
    end
  end

  test "explicit output rejects decoded SVG source responses without Vary" do
    if svg_supported?() do
      for path <- ["/_/f:png/plain/images/vector.svg", "/_/plain/images/vector.svg@png"] do
        conn = call_imgproxy(path, svg_origin_opts(), "image/avif,image/webp")

        assert conn.status == 415
        assert conn.resp_body == "source response is not a supported image"
        assert get_resp_header(conn, "vary") == []
        assert_received {:cache_lookup, _key}
        assert_received :origin_fetch
        refute_received {:cache_put, _key, _entry}
      end
    end
  end

  test "representative geometry options produce expected decoded dimensions" do
    cases = [
      {"/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg", {120, 80}},
      {"/_/rs:fill:120:90/g:ce/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/c:120:90/f:jpeg/plain/images/beach.jpg", {120, 90}},
      {"/_/g:soea/rs:fill:120:90/f:jpeg/plain/images/beach.jpg", {120, 90}}
    ]

    for {path, expected_dimensions} <- cases do
      conn = call_imgproxy(path, @default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
      assert dimensions(conn) == expected_dimensions
    end
  end

  test "invalid signatures, paths, options, and expiry stop before cache and origin access" do
    signed_opts =
      Keyword.merge(@default_opts,
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ]
      )

    cases = [
      {"/invalid/w:120/plain/images/beach.jpg", 403, signed_opts},
      {"/", 400, @default_opts},
      {"/_/w:-1/plain/images/beach.jpg", 400, @default_opts},
      {"/_/exp:100/plain/images/beach.jpg", 400,
       Keyword.put(@default_opts, :clock, fn -> DateTime.from_unix!(101) end)}
    ]

    for {path, expected_status, opts} <- cases do
      conn =
        call_imgproxy(
          path,
          Keyword.merge(opts,
            cache: {CacheProbe, []},
            sources: [
              path:
                {RootHTTPAdapter,
                 root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
            ]
          )
        )

      assert conn.status == expected_status
      refute_received :cache_lookup
      refute_received :cache_put
      refute_received :origin_fetch
    end
  end

  test "malformed encoded source stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_plug_wire_safety]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
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

  test "unsupported decoded source scheme stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_plug_wire_safety]

    attach_source_resolve_telemetry(telemetry_prefix)

    encoded = encoded_source("ftp://example.com/cat.jpg")

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
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

  test "encrypted source marker stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_plug_wire_safety]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/enc/payload", opts)

    assert conn.status == 400
    refute_received {:telemetry_event, [:image_plug, :source, :resolve, :start], _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "filesystem cache reuses normalized automatic Accept candidates" do
    {opts, cache_root} = cached_opts()

    try do
      first_conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(opts, "image/webp;q=1,image/avif;q=0.1")

      assert first_conn.status == 200
      assert content_type(first_conn) == ["image/avif"]
      assert get_resp_header(first_conn, "vary") == ["Accept"]
      assert_received :origin_fetch

      second_conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(opts, "image/avif,image/webp")

      assert second_conn.status == 200
      assert content_type(second_conn) == ["image/avif"]
      assert get_resp_header(second_conn, "vary") == ["Accept"]
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

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

  test "custom imgproxy scheme translator and custom source adapter fetch only on cache miss" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{
            "foobar" => {FoobarTranslator, []}
          }
        ],
        sources: [
          foobar: {PlugCustomAdapter, adapter: :foobar}
        ],
        cache: {CacheProbe, []}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:foobar_translate, "foobar://asset/cat.jpg"}
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
  end

  test "cache hit resolves custom source but does not fetch" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: {:hit, cache_entry()}}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    refute_received {:custom_fetch, _fetch}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup]
  end

  test "cache miss fetches custom source and writes successful encoded response" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    assert_received {:custom_fetch, :cat}
    assert_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup, :fetch, :cache_put]
  end

  test "cache skip fetches custom source without cache lookup or write" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [
          foobar: {PlugCustomAdapter, adapter: :foobar, cache: :skip}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :fetch]
  end

  test "S3 cache hit resolves identity without asking credential providers" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePlug.Source.S3,
             default: [
               endpoint: "https://minio.test",
               region: "eu-west-1",
               credentials: {:provider, CredentialProvider, []}
             ],
             buckets: %{
               "tenant-a" => [
                 credentials: {:provider, CredentialProvider, []}
               ]
             }}
        ],
        cache: {CacheProbe, result: {:hit, cache_entry()}}
      )

    conn =
      conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:cache_lookup, _key}
    refute_received {:fetch_credentials, _, _, _}
  end

  test "S3 cache miss asks only the selected bucket credential provider before fetch" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, File.read!("priv/static/images/beach.jpg"))
    end

    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePlug.Source.S3,
             default: [
               endpoint: "https://minio.test",
               region: "eu-west-1",
               credentials: {:provider, CredentialProvider, role: "default"},
               req_options: [plug: plug]
             ],
             buckets: %{
               "tenant-a" => [
                 credentials: {:provider, CredentialProvider, role: "tenant-a"}
               ],
               "tenant-b" => [
                 credentials: {:provider, CredentialProvider, role: "tenant-b"}
               ]
             }}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/s3://tenant-a/images/cat.jpg%3Fabc")
      |> ImagePlug.call(opts)

    assert conn.status == 200
    assert_received {:fetch_credentials, "tenant-a", [role: "tenant-a"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-a", [role: "default"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-b", [role: "tenant-b"], _runtime_opts}
  end

  defp cached_opts do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_plug_imgproxy_wire_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    opts =
      Keyword.merge(@default_opts,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingOriginImage, test_pid: self()}]}
        ],
        cache:
          {ImagePlug.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: [],
           fail_on_cache_error: false}
      )

    {opts, cache_root}
  end

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

  defp attach_source_resolve_telemetry(telemetry_prefix) do
    handler_id = {__MODULE__, self(), :source_resolve}

    :telemetry.attach_many(
      handler_id,
      [
        telemetry_prefix ++ [:source, :resolve, :start],
        telemetry_prefix ++ [:source, :resolve, :stop],
        telemetry_prefix ++ [:source, :resolve, :exception]
      ],
      &__MODULE__.handle_telemetry_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp svg_origin_opts do
    Keyword.merge(@default_opts,
      cache: {CacheProbe, result: :miss},
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {SvgOriginImage, test_pid: self()}]}
      ]
    )
  end

  defp call_imgproxy(path, opts, accept \\ nil) do
    conn =
      :get
      |> conn(path)
      |> put_accept(accept)

    ImagePlug.call(conn, ImagePlug.init(opts))
  end

  defp put_accept(conn, nil), do: conn
  defp put_accept(conn, accept), do: put_req_header(conn, "accept", accept)

  defp content_type(conn), do: get_resp_header(conn, "content-type")

  defp svg_supported? do
    case VipsImage.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end

  defp dimensions(conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(image), Image.height(image)}
  end

  defp cache_entry do
    %Entry{
      body: File.read!("priv/static/images/beach.jpg"),
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }
  end

  defp source_order, do: receive_source_order([])

  defp receive_source_order(events) do
    receive do
      {:source_order, event} -> receive_source_order([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
