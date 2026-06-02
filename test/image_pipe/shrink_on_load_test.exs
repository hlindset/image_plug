defmodule ImagePipe.ShrinkOnLoadTest do
  # Real file I/O — don't run async
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  # ──────────────────────────────────────────────────────────────────────────────
  # Origin plugs
  # ──────────────────────────────────────────────────────────────────────────────

  defmodule BeachJpegOrigin do
    @moduledoc false
    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule PngOrigin do
    @moduledoc false
    # Serves a 400×300 RGBA solid-colour PNG generated in the module attribute
    # so the body is built once per test run.
    @png_body (fn ->
                 {:ok, img} = Image.new(400, 300, color: [0, 200, 100, 255], bands: 4)
                 Image.write!(img, :memory, suffix: ".png")
               end).()

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, @png_body)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────────

  defp file_source_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}]
    ]
  end

  defp http_source_opts(origin_plug) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {ImagePipe.SourceTest.RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  defp call_pipe(path, opts) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp decoded_image(conn) do
    Image.open!(conn.resp_body, access: :random, fail_on: :error)
  end

  # Mean absolute error across all pixels/bands between two equally-sized images,
  # after downsampling both to ~32px wide (coarse comparison that is insensitive
  # to minor sub-pixel differences between decode kernels).
  defp coarse_mae(img_a, img_b) do
    target_w = 32
    scale_a = target_w / Image.width(img_a)
    scale_b = target_w / Image.width(img_b)

    {:ok, ds_a} = Image.resize(img_a, scale_a)
    {:ok, ds_b} = Image.resize(img_b, scale_b)

    w = Image.width(ds_a)
    h = Image.height(ds_a)
    bands = length(Image.get_pixel!(ds_a, 0, 0))

    total =
      for x <- 0..(w - 1), y <- 0..(h - 1) do
        pa = Image.get_pixel!(ds_a, x, y)
        pb = Image.get_pixel!(ds_b, x, y)
        Enum.zip(pa, pb) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.sum()
      end
      |> Enum.sum()

    total / (w * h * bands)
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Tests
  # ──────────────────────────────────────────────────────────────────────────────

  # beach.jpg is 4000×2667.  Requesting w:444 → load_shrink = 4000/444 ≈ 9.0
  # → largest power-of-2 ≤ 9 is 8, so the JPEG is shrunk to 500×333 at decode
  # and subsequently resized by vips to 444×296.  We assert the exact final size
  # and that the aspect ratio is preserved within ±2 px.
  test "JPEG shrink-on-load produces correct output dimensions" do
    conn = call_pipe("/_/w:444/f:jpeg/plain/images/beach.jpg", file_source_opts())

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    assert String.starts_with?(ct, "image/jpeg")

    img = decoded_image(conn)
    assert Image.width(img) == 444

    # Aspect ratio: 4000/2667 ≈ 1.499; expected height ≈ 296
    expected_h = round(444 / (4000 / 2667))
    actual_h = Image.height(img)

    assert abs(actual_h - expected_h) <= 2,
           "expected height ~#{expected_h}, got #{actual_h}"
  end

  # Coarse MAE between the shrink-on-load pipeline and a direct
  # Image.thumbnail/2 baseline, downsampled to 32px wide.
  #
  # Observed MAE on this machine: ~0.336
  # Threshold is set to 2.0 (≈ 6× observed) to accommodate minor cross-platform
  # kernel variation while catching gross decode errors.
  test "JPEG shrink-on-load MAE versus thumbnail baseline is within tolerance" do
    conn = call_pipe("/_/w:444/f:jpeg/plain/images/beach.jpg", file_source_opts())
    assert conn.status == 200

    result_img = decoded_image(conn)

    # Direct thumbnail as a reference; both should be 444×296
    {:ok, baseline} = Image.thumbnail("priv/static/images/beach.jpg", 444)

    mae = coarse_mae(result_img, baseline)

    # Observed ~0.336; threshold 2.0 (≈ 6× observed)
    assert mae < 2.0,
           "coarse MAE #{mae} exceeds 2.0 — shrink-on-load result drifted too far from thumbnail baseline"
  end

  # PNG is not JPEG-shrink-eligible; the decode planner must NOT inject a shrink
  # option.  We use a synthesized 400×300 RGBA PNG and request a 50px-wide
  # result.  Because there is no shrink, the decoded image goes through a normal
  # vips resize, so the output should have alpha and be pixel-exact to a direct
  # resize baseline.
  test "PNG decode is not shrunk; output preserves alpha" do
    conn = call_pipe("/_/w:50/plain/images/png", http_source_opts(PngOrigin))

    assert conn.status == 200
    assert [ct] = get_resp_header(conn, "content-type")
    # automatic negotiation may pick webp/avif; we just check it is an image
    assert String.starts_with?(ct, "image/")

    img = decoded_image(conn)

    assert Image.width(img) == 50
    assert Image.has_alpha?(img)
  end

  # PNG MAE vs direct resize baseline should be effectively zero (same kernel,
  # no shrink path involved).
  test "PNG pixel values match direct resize baseline" do
    conn = call_pipe("/_/w:50/f:png/plain/images/png", http_source_opts(PngOrigin))

    assert conn.status == 200
    result_img = decoded_image(conn)

    {:ok, src} = Image.new(400, 300, color: [0, 200, 100, 255], bands: 4)
    {:ok, baseline} = Image.resize(src, 50 / 400)

    mae = coarse_mae(result_img, baseline)

    assert mae < 1.0,
           "PNG MAE #{mae} unexpectedly high — shrink may have been applied to a PNG"
  end

  # max_input_pixels is checked against the *original* JPEG header dimensions,
  # not the shrunk-decode result.  Setting the limit 1 pixel below the beach.jpg
  # pixel count must return 413 before any encoding.
  test "oversized JPEG is rejected when max_input_pixels < source pixel count" do
    orig_pixels = 4000 * 2667

    opts =
      Keyword.merge(
        http_source_opts(BeachJpegOrigin),
        max_input_pixels: orig_pixels - 1
      )

    conn = call_pipe("/_/w:444/f:jpeg/plain/images/beach.jpg", opts)

    assert conn.status == 413
    assert conn.resp_body =~ "too large"
  end

  # Animated GIF shrink-on-load path:
  # Skipped for now — animated GIF handling is complex to make cross-platform
  # in a fixture-free test.  Will be added when a minimal test GIF fixture is
  # committed.
end
