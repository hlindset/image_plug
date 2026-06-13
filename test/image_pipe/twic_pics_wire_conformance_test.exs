defmodule ImagePipe.TwicPicsWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias TwicPicsWireConformanceTest.ExifOrientedOrigin
  alias TwicPicsWireConformanceTest.OriginImage
  alias TwicPicsWireConformanceTest.OriginShouldNotFetch

  @opts [
    parser: ImagePipe.Parser.TwicPics,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  defp call(path, opts \\ @opts) do
    :get |> conn(path) |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp dimensions(%Plug.Conn{} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(image), Image.height(image)}
  end

  defp exif_opts do
    Keyword.put(@opts, :sources,
      path:
        {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: ExifOrientedOrigin]}
    )
  end

  test "auto-orients an EXIF-tagged source by default, without any geometry" do
    conn = call("/images/oriented.jpg?twic=v1/output=jpeg", exif_opts())
    assert conn.status == 200
    # Stored 40x80 portrait tagged EXIF orientation 6 displays as 80x40. Real
    # TwicPics bakes EXIF orientation into the output by default, so the served
    # frame is the upright 80x40 landscape, not the stored 40x80 portrait.
    assert dimensions(conn) == {80, 40}
  end

  test "a chained resize composes against the auto-oriented (upright) frame" do
    conn = call("/images/oriented.jpg?twic=v1/resize=40/output=jpeg", exif_opts())
    assert conn.status == 200
    # Auto-orient runs first, so resize fits width 40 against the upright 80x40
    # frame -> 40x20 (landscape), not the stored 40x80 portrait.
    assert dimensions(conn) == {40, 20}
  end

  test "single resize reaches the intermediate dimension (not clamped on a large source)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/output=jpeg")
    assert {340, _} = dimensions(conn)
  end

  test "chained relative resize resolves against running dimensions (340 then 50%)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/output=jpeg")
    assert conn.status == 200
    assert {170, _} = dimensions(conn)
  end

  test "three-hop relative chain compounds against the running width" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/resize=50p/output=jpeg")
    assert {85, _} = dimensions(conn)
  end

  test "bare percent resolves against the source width (4000) -> 2000" do
    conn = call("/images/beach.jpg?twic=v1/resize=50p/output=jpeg")
    assert {2000, _} = dimensions(conn)
  end

  test "malformed chain is rejected before any source fetch" do
    opts =
      Keyword.put(@opts, :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
      )

    # OriginShouldNotFetch raises if the origin is ever reached, so a clean 400
    # (rather than a 500) is itself the proof that the parser rejected the chain
    # before source resolution.
    conn = call("/images/beach.jpg?twic=v1/zoom=2", opts)
    assert conn.status == 400
  end

  defp average(%Plug.Conn{} = conn) do
    conn.resp_body
    |> Image.open!(access: :random, fail_on: :error)
    |> Image.average!()
  end

  test "focus anchor steers the cover crop (decoded pixels differ from centered baseline)" do
    centered = call("/images/beach.jpg?twic=v1/cover=200x200/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=200x200/output=jpeg")

    assert dimensions(centered) == {200, 200}
    assert dimensions(topleft) == {200, 200}
    refute average(centered) == average(topleft)
  end

  test "cover ratio crops to the target ratio without scaling" do
    conn = call("/images/beach.jpg?twic=v1/cover=16:9/output=jpeg")
    {w, h} = dimensions(conn)
    assert_in_delta w / h, 16 / 9, 0.02
  end

  test "contain fits inside; inside letterboxes to exact dims with a transparent border" do
    contain = call("/images/beach.jpg?twic=v1/contain=200x200/output=png")
    inside = call("/images/beach.jpg?twic=v1/inside=200x200/output=png")

    {cw, ch} = dimensions(contain)
    assert cw == 200
    assert ch < 200

    assert dimensions(inside) == {200, 200}
    img = Image.open!(inside.resp_body, access: :random, fail_on: :error)
    assert Image.has_alpha?(img)
  end

  test "inside with a non-alpha output flattens (no error, exact dims)" do
    conn = call("/images/beach.jpg?twic=v1/inside=200x200/output=jpeg")
    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
  end

  test "explicit output bypasses negotiation; auto sets Vary: Accept" do
    explicit = call("/images/beach.jpg?twic=v1/resize=100/output=avif")
    assert Plug.Conn.get_resp_header(explicit, "content-type") == ["image/avif"]

    auto =
      :get
      |> conn("/images/beach.jpg?twic=v1/resize=100/output=auto")
      |> Plug.Conn.put_req_header("accept", "image/webp")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(@opts))

    vary = auto |> Plug.Conn.get_resp_header("vary") |> Enum.flat_map(&String.split(&1, ", "))
    assert Enum.any?(vary, &(String.downcase(&1) == "accept"))
  end

  test "oversized chained upscale is clamped to the result limit after fetch" do
    opts = Keyword.put(@opts, :max_result_pixels, 1_000_000)
    conn = call("/images/beach.jpg?twic=v1/resize=4s/resize=4s/output=jpeg", opts)
    # The 16x chained upscale of a 4000px source overshoots the host pixel cap.
    # ImagePipe clamps an oversized result down to the caps (imgproxy fixSize
    # parity, #150/#165) rather than rejecting it — a 200 with the result pinned
    # under the cap proves the request reached the post-fetch result-size guard.
    assert conn.status == 200
    {w, h} = dimensions(conn)
    assert w * h <= 1_000_000
  end

  test "two semantically-equivalent requests reuse the same cache entry" do
    cache_root =
      Path.join(System.tmp_dir!(), "twicpics_wire_cache_#{System.unique_integer([:positive])}")

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)
    on_exit(fn -> File.rm_rf!(cache_root) end)

    opts =
      @opts
      |> Keyword.put(
        :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {OriginImage, test_pid: self()}]}
      )
      |> Keyword.put(
        :cache,
        {ImagePipe.Cache.FileSystem,
         root: cache_root,
         path_prefix: "processed",
         max_body_bytes: 10_000_000,
         key_headers: [],
         key_cookies: []}
      )

    first = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert first.status == 200
    assert_received :origin_fetch

    second = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    refute_received :origin_fetch
  end
end
