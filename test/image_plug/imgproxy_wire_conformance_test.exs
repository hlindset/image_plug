defmodule ImagePlug.ImgproxyWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImgproxyWireConformanceTest.CacheProbe
  alias ImgproxyWireConformanceTest.CountingOriginImage
  alias ImgproxyWireConformanceTest.OriginImage
  alias ImgproxyWireConformanceTest.OriginShouldNotFetch

  @default_opts [
    root_url: "http://origin.test",
    parser: ImagePlug.Parser.Imgproxy,
    origin_req_options: [plug: OriginImage]
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
            root_url: "not-a-valid-origin-url",
            cache: {CacheProbe, []},
            origin_req_options: [plug: OriginShouldNotFetch]
          )
        )

      assert conn.status == expected_status
      refute_received :cache_lookup
      refute_received :cache_put
      refute_received :origin_fetch
    end
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
        origin_req_options: [plug: {CountingOriginImage, test_pid: self()}],
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

  defp dimensions(conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(image), Image.height(image)}
  end
end
