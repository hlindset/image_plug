defmodule ImagePipe.ImgproxyWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.SourceTest.CredentialProvider
  alias ImagePipe.SourceTest.FoobarTranslator
  alias ImagePipe.SourceTest.PlugCustomAdapter
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch
  alias Vix.Vips.Image, as: VipsImage

  @source_url_encryption_key "000102030405060708090a0b0c0d0e0f"
  @source_url_encryption_iv <<16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31>>
  @alternate_source_url_encryption_iv <<31, 30, 29, 28, 27, 26, 25, 24, 23, 22, 21, 20, 19, 18,
                                        17, 16>>

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

  defmodule ExifOrientationOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        40
        |> Image.new!(80, color: :white)
        |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
        |> Image.set_orientation!(6)
        |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule EffectOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      body =
        64
        |> Image.new!(64, color: :black)
        |> Image.Draw.rect!(0, 0, 32, 64, color: :white)
        |> Image.Draw.rect!(16, 0, 16, 64, color: :red)
        |> Image.Draw.rect!(32, 0, 16, 64, color: :green)
        |> Image.Draw.rect!(48, 0, 16, 64, color: :blue)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule AvifOriginImage do
    @moduledoc false

    # Serves a committed 64x64 AVIF fixture rather than encoding at request
    # time, so the source is available even on libvips builds without AVIF
    # *write* support (decoding an AVIF source needs only AVIF read).
    def call(conn, _opts) do
      body = File.read!("test/support/image_pipe/imgproxy_wire_conformance_test/cat.avif")

      conn
      |> Plug.Conn.put_resp_content_type("image/avif")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  @default_opts [
    parser: ImagePipe.Parser.Imgproxy,
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

  test "automatic output treats missing empty and wildcard-only Accept as source fallback" do
    cases = [
      nil,
      "",
      "*/*",
      "*/*;q=1",
      "application/json,*/*;q=1"
    ]

    for accept <- cases do
      conn =
        "/_/plain/images/beach.jpg"
        |> call_imgproxy(@default_opts, accept)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
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

  test "encrypted path source succeeds through a real Plug request" do
    encrypted = encrypted_source("images/beach.jpg")

    conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}", encrypted_opts())

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {120, 90}
    assert byte_size(conn.resp_body) > 0
  end

  test "encrypted output suffix bypasses Accept negotiation and does not set Vary" do
    encrypted = encrypted_source("images/beach.jpg")

    conn =
      call_imgproxy(
        "/_/f:jpeg/enc/#{encrypted}.webp",
        encrypted_opts(),
        "image/avif,image/webp"
      )

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

  test "exar:1 under fit extends the canvas to the resize aspect ratio" do
    # beach.jpg is 4000x2667 (landscape). rs:fit:300:300 scales it to 300x200 (width
    # is the binding axis). exar:1 extends the canvas to the 1:1 requested ratio,
    # padding the deficient axis: height grows from 200 to 300, giving a 300x300 output.
    conn = call_imgproxy("/_/rs:fit:300:300/exar:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {300, 300}
  end

  test "exar:1 under force is a no-op when the image already matches the requested ratio" do
    # beach.jpg is 4000x2667. rs:force:300:200 hard-scales it to exactly 300x200.
    # exar:1 would extend to the requested 300:200 (3:2) ratio, but the canvas is
    # already 3:2, so no padding is added and output dimensions are identical.
    base = call_imgproxy("/_/rs:force:300:200/f:jpeg/plain/images/beach.jpg", @default_opts)

    with_exar =
      call_imgproxy("/_/rs:force:300:200/exar:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert base.status == 200
    assert with_exar.status == 200
    assert dimensions(base) == {300, 200}
    assert dimensions(with_exar) == {300, 200}
    # A true no-op must produce byte-identical output, not merely the same size.
    assert with_exar.resp_body == base.resp_body
  end

  test "effect options change decoded response pixels without geometry options" do
    baseline =
      "/_/f:png/plain/images/effects.png"
      |> call_imgproxy(effect_origin_opts())
      |> decoded_image()

    cases = [
      "/_/bl:4/f:png/plain/images/effects.png",
      "/_/sh:10/f:png/plain/images/effects.png",
      "/_/pix:8/f:png/plain/images/effects.png",
      "/_/mc:1:ffcc00/f:png/plain/images/effects.png",
      "/_/dt:1:112233:ffeecc/f:png/plain/images/effects.png",
      "/_/br:25/f:png/plain/images/effects.png",
      "/_/co:10/f:png/plain/images/effects.png",
      "/_/sa:-30/f:png/plain/images/effects.png"
    ]

    for path <- cases do
      image =
        path
        |> call_imgproxy(effect_origin_opts())
        |> decoded_image()

      assert dimensions(image) == dimensions(baseline)
      assert sampled_pixels(image) != sampled_pixels(baseline)
    end
  end

  test "imgproxy auto_rotate config and URL options control EXIF autorotation" do
    default_conn =
      "/_/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts())

    assert default_conn.status == 200
    assert content_type(default_conn) == ["image/jpeg"]
    assert dimensions(default_conn) == {80, 40}

    configured_disabled_conn =
      "/_/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: false]))

    assert configured_disabled_conn.status == 200
    assert dimensions(configured_disabled_conn) == {40, 80}

    url_enabled_conn =
      "/_/ar:true/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: false]))

    assert url_enabled_conn.status == 200
    assert dimensions(url_enabled_conn) == {80, 40}

    url_disabled_conn =
      "/_/ar:false/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert url_disabled_conn.status == 200
    assert dimensions(url_disabled_conn) == {40, 80}
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
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

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
      refute_received {:telemetry_event, ^source_resolve_start, _, _}
      refute_received {:cache_lookup, _key}
      refute_received {:cache_put, _key, _entry}
      refute_received :origin_fetch
    end
  end

  test "unsupported decoded source scheme stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

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
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "encrypted unsupported decoded source scheme stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    encrypted = encrypted_source("ftp://example.com/cat.jpg")

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/enc/#{encrypted}", opts)

    assert conn.status == 400
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "encrypted source marker without configured key stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

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
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "malformed encrypted source collapses parser errors and stops before cache lookup and origin fetch" do
    telemetry_prefix = [:image_pipe_wire_encrypted_safety]
    parse_stop = telemetry_prefix ++ [:parse, :stop]
    parse_exception = telemetry_prefix ++ [:parse, :exception]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_safety_telemetry(telemetry_prefix)

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    malformed_paths = [
      "/_/enc/not+base64",
      "/_/enc/#{Base.url_encode64(String.duplicate("x", 31), padding: false)}",
      "/_/enc/#{Base.url_encode64(@source_url_encryption_iv <> String.duplicate("x", 17), padding: false)}",
      "/_/enc/#{Base.url_encode64(@source_url_encryption_iv <> String.duplicate("x", 16), padding: false)}"
    ]

    bodies =
      for path <- malformed_paths do
        conn = call_imgproxy(path, opts)

        assert conn.status == 400

        assert_received {:telemetry_event, ^parse_stop, _measurements,
                         %{result: :error, error: :error}}

        conn.resp_body
      end

    assert Enum.uniq(bodies) == ["invalid image request: :invalid_encrypted_source"]
    refute_received {:telemetry_event, ^parse_exception, _, _}
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
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

  test "plain encoded encrypted and SEO filename spellings share the same filesystem cache entry" do
    {opts, cache_root} =
      cached_opts(
        imgproxy: [
          source_url_encryption_key: @source_url_encryption_key,
          base64_url_includes_filename: true
        ]
      )

    try do
      first_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/plain/images/beach.jpg", opts)

      assert first_conn.status == 200
      assert_received :origin_fetch

      encoded = encoded_source("images/beach.jpg")
      encoded_conn = call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/#{encoded}/puppy.jpg", opts)

      assert encoded_conn.status == 200
      assert encoded_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch

      encrypted = encrypted_source("images/beach.jpg")

      encrypted_conn =
        call_imgproxy("/_/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}/kitten.jpg", opts)

      assert encrypted_conn.status == 200
      assert encrypted_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch

      alternate_encrypted =
        encrypted_source("images/beach.jpg", iv: @alternate_source_url_encryption_iv)

      alternate_conn =
        call_imgproxy(
          "/_/rt:force/w:120/h:90/f:jpeg/enc/#{alternate_encrypted}/puppy.jpg",
          opts
        )

      assert alternate_conn.status == 200
      assert alternate_conn.resp_body == first_conn.resp_body
      refute_received :origin_fetch
    after
      File.rm_rf!(cache_root)
    end
  end

  test "signed encrypted URLs verify the SEO filename before decrypting the source" do
    telemetry_prefix = [:image_pipe_signed_encrypted_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    encrypted = encrypted_source("images/beach.jpg")
    signed_path = "/rt:force/w:120/h:90/f:jpeg/enc/#{encrypted}.webp/puppy.jpg"

    imgproxy =
      [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ],
        source_url_encryption_key: @source_url_encryption_key,
        base64_url_includes_filename: true
      ]

    assert call_imgproxy(
             signed_request_path(signed_path),
             Keyword.put(@default_opts, :imgproxy, imgproxy)
           ).status ==
             200

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        imgproxy: imgproxy
      )

    tampered_path =
      signed_path
      |> signed_request_path()
      |> String.replace_suffix("puppy.jpg", "kitten.jpg")

    conn = call_imgproxy(tampered_path, opts)

    assert conn.status == 403
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  test "signed encrypted URLs reject invalid signatures before malformed source decryption" do
    telemetry_prefix = [:image_pipe_signed_malformed_encrypted_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    imgproxy =
      [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ],
        source_url_encryption_key: @source_url_encryption_key,
        base64_url_includes_filename: true
      ]

    opts =
      encrypted_opts(
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        imgproxy: imgproxy
      )

    conn =
      call_imgproxy(
        "/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/rt:force/w:120/h:90/f:jpeg/enc/not+base64.webp/puppy.jpg",
        opts
      )

    assert conn.status == 403
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
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
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
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
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:foobar_translate, "foobar://asset/cat.jpg"}
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
  end

  test "cache hit resolves custom source but does not fetch" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: {:hit, cache_entry()}}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    refute_received {:custom_fetch, _fetch}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup]
  end

  test "cache miss fetches custom source and writes successful encoded response" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [foobar: {PlugCustomAdapter, adapter: :foobar}],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:cache_lookup, _key}
    assert_received {:custom_fetch, :cat}
    assert_received {:cache_open_sink, _key, %{cost_us: cost_us}}
    assert cost_us > 0
    assert_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :cache_lookup, :fetch, :cache_put]
  end

  test "cache skip fetches custom source without cache lookup or write" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        imgproxy: [
          source_schemes: %{"foobar" => {FoobarTranslator, []}}
        ],
        sources: [
          foobar: {PlugCustomAdapter, adapter: :foobar, internal_cache: :disabled}
        ],
        cache: {CacheProbe, result: :miss}
      )

    conn =
      conn(:get, "/_/plain/foobar://asset/cat.jpg")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:custom_resolve, _source}
    assert_received {:custom_fetch, :cat}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    assert source_order() == [:resolve, :fetch]
  end

  test "S3 cache hit resolves identity without asking credential providers" do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePipe.Source.S3,
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
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:cache_lookup, _key}
    refute_received {:fetch_credentials, _, _, _}
  end

  test "car corrects the crop area aspect ratio (enlarge)" do
    # beach.jpg is 4000x2667. c:100:200:ce crops a 100x200 region (centered).
    # car:1:1 (ratio=1, enlarge) grows the short axis: 100 -> 200, giving 200x200.
    # Because gravity is unchanged, the corrected crop must sample the same region
    # as a direct 200x200 centered crop, so the decoded bytes are identical.
    conn = call_imgproxy("/_/c:100:200:ce/car:1:1/f:jpeg/plain/images/beach.jpg", @default_opts)
    direct = call_imgproxy("/_/c:200:200:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
    assert conn.resp_body == direct.resp_body
  end

  test "car works without a resize (no-geometry-resize case)" do
    # beach.jpg is 4000x2667. c:100:200:ce crops a 100x200 region.
    # car:1 (ratio=1, default reduce) shrinks the long axis: 200 -> 100, giving 100x100.
    # The corrected crop must equal a direct 100x100 centered crop, pixel for pixel.
    conn = call_imgproxy("/_/c:100:200:ce/car:1/f:jpeg/plain/images/beach.jpg", @default_opts)
    direct = call_imgproxy("/_/c:100:100:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert dimensions(conn) == {100, 100}
    assert conn.resp_body == direct.resp_body
  end

  test "car leaves gravity placement unchanged" do
    # c:200:400:no + car:1:1 (enlarge) grows short axis: 200 -> 400, giving 400x400 anchored north.
    # c:400:400:no directly crops 400x400 anchored north. The decoded bytes must be
    # identical, proving the correction changed only the size and kept the gravity region.
    via_car =
      call_imgproxy("/_/c:200:400:no/car:1:1/f:jpeg/plain/images/beach.jpg", @default_opts)

    direct = call_imgproxy("/_/c:400:400:no/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert via_car.status == 200
    assert direct.status == 200
    assert dimensions(via_car) == dimensions(direct)
    assert via_car.resp_body == direct.resp_body
  end

  test "S3 cache miss asks only the selected bucket credential provider before fetch" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, File.read!("priv/static/images/beach.jpg"))
    end

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          s3:
            {ImagePipe.Source.S3,
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
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert_received {:fetch_credentials, "tenant-a", [role: "tenant-a"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-a", [role: "default"], _runtime_opts}
    refute_received {:fetch_credentials, "tenant-b", [role: "tenant-b"], _runtime_opts}
  end

  describe "output capability handling" do
    test "automatic negotiation drops avif when the build cannot write it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: false, webp: true})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]
      assert get_resp_header(conn, "vary") == ["Accept"]
    end

    test "automatic negotiation keeps avif when the build supports it" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true, webp: true})

      conn = call_imgproxy("/_/plain/images/beach.jpg", opts, "image/avif,image/webp")

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
    end

    test "an avif source with a jpeg-only Accept transcodes to raster regardless of capability" do
      base = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: AvifOriginImage]}
        ]
      ]

      for capability <- [%{avif: true}, %{avif: false}] do
        opts = Keyword.put(base, :output_capabilities, capability)

        conn = call_imgproxy("/_/plain/images/cat.avif", opts, "image/jpeg")

        assert conn.status == 200
        # 64x64 solid red has no alpha -> JPEG, never AVIF, for either build.
        assert content_type(conn) == ["image/jpeg"]
        # Decode confirms valid raster output at the source dimensions.
        assert dimensions(conn) == {64, 64}
      end
    end

    test "an avif-capable and avif-less build caches distinct variants for the same Accept" do
      {base, cache_root} = cached_opts()

      try do
        capable = Keyword.put(base, :output_capabilities, %{avif: true, webp: true})
        incapable = Keyword.put(base, :output_capabilities, %{avif: false, webp: true})
        accept = "image/avif,image/webp"
        path = "/_/plain/images/beach.jpg"

        capable_conn = call_imgproxy(path, capable, accept)
        assert content_type(capable_conn) == ["image/avif"]
        assert_received :origin_fetch

        incapable_conn = call_imgproxy(path, incapable, accept)
        assert content_type(incapable_conn) == ["image/webp"]
        # Distinct filtered candidate list -> distinct key -> a second origin fetch.
        assert_received :origin_fetch

        # A repeat under the capable profile is served from cache without
        # re-fetching the origin, proving the filtered candidate list keys the two
        # variants apart (no cross-contamination from the webp entry).
        repeat_capable = call_imgproxy(path, capable, accept)
        assert content_type(repeat_capable) == ["image/avif"]
        assert repeat_capable.resp_body == capable_conn.resp_body
        refute_received :origin_fetch
      after
        File.rm_rf!(cache_root)
      end
    end

    test "a jpeg source with a jpeg-only Accept passes through as jpeg" do
      conn = call_imgproxy("/_/plain/images/beach.jpg", @default_opts, "image/jpeg")

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]
    end

    test "explicit avif is rejected before source fetch on an avif-less build" do
      opts = [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ],
        output_capabilities: %{avif: false}
      ]

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 501
      # OriginShouldNotFetch flunks/raises if the source is fetched; reaching 501
      # without that proves the rejection happened pre-fetch.
    end

    test "explicit avif succeeds on a capable build" do
      opts = Keyword.put(@default_opts, :output_capabilities, %{avif: true})

      conn = call_imgproxy("/_/f:avif/plain/images/beach.jpg", opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]
      assert get_resp_header(conn, "vary") == []
    end
  end

  defp cached_opts(overrides \\ []) do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_pipe_imgproxy_wire_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    opts =
      @default_opts
      |> Keyword.merge(
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingOriginImage, test_pid: self()}]}
        ],
        cache:
          {ImagePipe.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: []}
      )
      |> Keyword.merge(overrides)

    {opts, cache_root}
  end

  defp encrypted_opts(overrides \\ []) do
    @default_opts
    |> Keyword.merge(imgproxy: [source_url_encryption_key: @source_url_encryption_key])
    |> Keyword.merge(overrides)
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

  defp encrypted_source(source, opts \\ []) do
    iv = Keyword.get(opts, :iv, @source_url_encryption_iv)

    {:ok, segment} =
      Imgproxy.encrypt_source_url(source, @source_url_encryption_key, iv: iv)

    segment
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

  defp attach_safety_telemetry(telemetry_prefix) do
    handler_id = {__MODULE__, self(), :safety}

    :telemetry.attach_many(
      handler_id,
      [
        telemetry_prefix ++ [:parse, :stop],
        telemetry_prefix ++ [:parse, :exception],
        telemetry_prefix ++ [:source, :resolve, :start],
        telemetry_prefix ++ [:source, :resolve, :stop],
        telemetry_prefix ++ [:source, :resolve, :exception]
      ],
      &__MODULE__.handle_telemetry_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp signed_request_path(signed_path) do
    key = Base.decode16!("746573742d6b6579", case: :lower)
    salt = Base.decode16!("746573742d73616c74", case: :lower)

    signature =
      :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
      |> Base.url_encode64(padding: false)

    "/" <> signature <> signed_path
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

  defp exif_orientation_origin_opts(overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: ExifOrientationOriginImage]}
        ]
      ],
      overrides
    )
  end

  defp effect_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: EffectOriginImage]}
      ]
    ]
  end

  defp call_imgproxy(path, opts, accept \\ nil) do
    conn =
      :get
      |> conn(path)
      |> put_accept(accept)

    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
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

  defp dimensions(%Plug.Conn{} = conn) do
    conn
    |> decoded_image()
    |> dimensions()
  end

  defp dimensions(%VipsImage{} = image) do
    {Image.width(image), Image.height(image)}
  end

  defp decoded_image(%Plug.Conn{} = conn) do
    Image.open!(conn.resp_body, access: :random, fail_on: :error)
  end

  defp sampled_pixels(image) do
    for x <- [8, 16, 24, 32, 40, 48, 56],
        y <- [8, 24, 40, 56] do
      Image.get_pixel!(image, x, y)
    end
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
