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

  # Deferred-orientation gate (#146) origins. Both serve the SAME displayed
  # pixels: `OrientedFrameOrigin` tags a stored image with an EXIF orientation
  # (so the pipeline must autorotate it), while `Orientation1TwinOrigin` decodes
  # that same tagged image, applies the autorotate in pixels, strips the tag, and
  # serves the result as a lossless orientation-1 PNG. Running an identical
  # imgproxy request against both is the wire-vs-orientation-1 oracle: the same
  # operators run on the same displayed content, so the decoded outputs match.
  #
  # The base content is a 120×200 portrait with sharp solid quadrants and a
  # corner marker; large enough that a ±1px affine-resize seam shift never reaches
  # the interior flat-region samples the oracle compares.
  defmodule OrientationFixture do
    @moduledoc false

    def base do
      120
      |> Image.new!(200, color: :green)
      |> Image.Draw.rect!(0, 0, 120, 100, color: :red)
      |> Image.Draw.rect!(0, 0, 30, 30, color: :blue)
    end

    def oriented_jpeg(orientation) do
      base()
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")
    end

    # The orientation-1 twin: the EXIF source's displayed pixels, stored untagged.
    # Derived from the re-decoded JPEG (not the in-memory image) so the displayed
    # frame exactly matches what the pipeline decodes from the oriented source.
    def twin_png(orientation) do
      reopened = Image.open!(oriented_jpeg(orientation), access: :random)
      {:ok, {displayed, _flags}} = Image.autorotate(reopened)

      displayed
      |> Image.set_orientation!(1)
      |> Image.write!(:memory, suffix: ".png")
    end
  end

  defmodule OrientedFrameOrigin do
    @moduledoc false

    def init(orientation), do: orientation

    def call(conn, orientation) do
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, OrientationFixture.oriented_jpeg(orientation))
    end
  end

  defmodule Orientation1TwinOrigin do
    @moduledoc false

    def init(orientation), do: orientation

    def call(conn, orientation) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, OrientationFixture.twin_png(orientation))
    end
  end

  defmodule MetadataOriginImage do
    @moduledoc false

    alias Vix.Vips.Image, as: VixImage
    alias Vix.Vips.MutableImage, as: VixMutableImage

    # Generates a JPEG carrying EXIF (Copyright + ImageDescription) and XMP so
    # wire tests can assert that sm/kcr strip or retain them as expected.
    def init(opts), do: opts

    def call(conn, opts) do
      if pid = Keyword.get(List.wrap(opts), :test_pid), do: send(pid, :origin_fetch)

      img = Image.new!(100, 100, color: :white)

      {:ok, with_metadata} =
        VixImage.mutate(img, fn mut ->
          VixMutableImage.set(mut, "exif-ifd0-Copyright", :gchararray, "(c) ACME")
          VixMutableImage.set(mut, "exif-ifd0-ImageDescription", :gchararray, "A test image")
          VixMutableImage.set(mut, "xmp-data", :VipsBlob, "<x:xmpmeta/>")
          :ok
        end)

      body = Image.write!(with_metadata, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule WideGamutOriginImage do
    @moduledoc false

    # Generates a P3 wide-gamut PNG carrying an embedded ICC profile.
    # `Image.to_colorspace(_, :p3, [])` attaches a P3 ICC profile to the
    # in-memory image, and libvips embeds it in the PNG stream on write.
    # Re-opening the PNG bytes confirms "icc-profile-data" is present.
    def call(conn, _opts) do
      {:ok, base} = Image.new(40, 40, color: [200, 50, 50])
      {:ok, p3_img} = Image.to_colorspace(base, :p3, [])
      body = Image.write!(p3_img, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
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

  defmodule AlphaOriginImage do
    @moduledoc false

    # Serves a 20×20 fully-transparent RGBA PNG. Used to verify that bl: + bg:
    # on an alpha source flattens the output (no alpha channel in response).
    def call(conn, _opts) do
      body =
        Image.new!(20, 20, color: [0, 0, 0, 0], bands: 4)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule UnavailableDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_opts), do: ["face"]

    @impl true
    def detect(_image, _opts), do: {:error, {:detector, :unavailable}}

    @impl true
    def available?(_opts), do: false

    @impl true
    def identity(_opts), do: {__MODULE__, :unavailable}
  end

  defmodule FaceVerFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :face_ver, :v1)}

    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule ObjectVerFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car", "dog"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :object_ver, :v1)}

    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule VerComposite do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    alias ImagePipe.Transform.Detector.Composite

    defp c, do: Composite.new([FaceVerFake, ObjectVerFake])

    @impl true
    def supported_classes(_o), do: Composite.supported_classes(c())

    @impl true
    def detect(i, o), do: Composite.detect(c(), i, o)

    @impl true
    def available?(o), do: Composite.available?(c(), o)

    @impl true
    def identity(o), do: Composite.identity(c(), o)
  end

  # Task 10: CornerObjectDetector — places a small box near the top-left so a
  # fill-crop biases up-left, distinct from center and attention saliency.
  defmodule CornerObjectDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car", "dog", "face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, opts) do
      classes = Keyword.get(opts, :classes, :all)
      label = if classes == :all, do: "car", else: List.first(List.wrap(classes))
      {:ok, [%{label: label, score: 0.95, box: {2, 2, 20, 20}}]}
    end
  end

  # Slice 2: a large "person" box and a small "face" box, class-aware so obj:person
  # / obj:face filter to one box. Sized as large fractions of beach.jpg (4000×2667)
  # so the fill-crop window actually moves between weightings.
  defmodule WeightedSceneDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @boxes [
      %{label: "person", score: 0.95, box: {2000, 800, 800, 1000}},
      %{label: "face", score: 0.95, box: {1400, 600, 400, 400}}
    ]

    @impl true
    def supported_classes(_), do: ["face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> {:ok, @boxes}
        classes -> {:ok, Enum.filter(@boxes, &(&1.label in List.wrap(classes)))}
      end
    end
  end

  # Task 10: PartialDetector — Composite with FaceFake (available) and
  # UnavailableObjectFake (available?=false), used for the gate triad.
  defmodule GateTriadFaceFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(_), do: {__MODULE__, :face_v1}

    @impl true
    def detect(_image, opts) do
      {:ok, [%{label: "face", score: 0.9, box: {0, 0, 50, 50}}]}
      |> filter_classes(Keyword.get(opts, :classes, :all))
    end

    defp filter_classes({:ok, regions}, :all), do: {:ok, regions}

    defp filter_classes({:ok, regions}, classes) when is_list(classes) do
      wanted = MapSet.new(classes)
      {:ok, Enum.filter(regions, fn %{label: l} -> MapSet.member?(wanted, l) end)}
    end
  end

  defmodule GateTriadUnavailableObjectFake do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["car"]

    @impl true
    def available?(_), do: false

    @impl true
    def identity(_), do: {__MODULE__, :unavailable}

    @impl true
    def detect(_image, _opts), do: {:error, {:detector, :unavailable}}
  end

  defmodule PartialDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    alias ImagePipe.Transform.Detector.Composite

    defp c, do: Composite.new([GateTriadFaceFake, GateTriadUnavailableObjectFake])

    @impl true
    def supported_classes(_o), do: Composite.supported_classes(c())

    @impl true
    def detect(i, o), do: Composite.detect(c(), i, o)

    @impl true
    def available?(o), do: Composite.available?(c(), o)

    @impl true
    def identity(o), do: Composite.identity(c(), o)
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

  test "g:sm smart gravity returns a smart-cropped image of the requested size" do
    conn = call_imgproxy("/_/rs:fill:80:80/g:sm/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert conn.status == 200
    assert content_type(conn) == ["image/jpeg"]
    assert dimensions(conn) == {80, 80}

    # A silent fallback to center gravity would make smart and center crops
    # identical; assert the smart crop genuinely picks a different region.
    centered = call_imgproxy("/_/rs:fill:80:80/g:ce/f:jpeg/plain/images/beach.jpg", @default_opts)

    assert centered.status == 200
    refute conn.resp_body == centered.resp_body
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

  test "ar:0 + EXIF-6 + user rot:90 applies only the user rotation (regression guard)" do
    conn =
      "/_/ar:false/rot:90/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert conn.status == 200
    # ar:0 ignores the EXIF tag; user rot:90 on the STORED 40x80 -> 80x40.
    assert dimensions(conn) == {80, 40}
    assert_oriented_pixels_match(decoded_image(conn), reference_user_rot90_storage())
  end

  test "no-geometry: rot:90 on EXIF-6 (ar:1) = 180 deg net" do
    conn =
      "/_/rot:90/f:jpeg/plain/images/oriented.jpg"
      |> call_imgproxy(exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))

    assert conn.status == 200
    # EXIF-6 (90 deg) THEN user 90 deg = 180 deg net on the stored 40x80 -> stays 40x80.
    assert dimensions(conn) == {40, 80}
    assert_oriented_pixels_match(decoded_image(conn), reference_180_of_stored())
  end

  # ── Deferred-orientation Slice A gates (#146) ────────────────────────────────

  # Regression guard for the deferred-orientation cutover: an EXIF-oriented source
  # combined with a gravity / region / focus-point / cover crop must SUCCEED.
  # Before the offset-unit fix in PlanExecutor.compensate_crop/2, the executable
  # crop's tagged offset ({:pixels, 0.0}) reached Orientation's bare-float
  # arithmetic and raised, turning every EXIF-2..7 + crop request into a 500.
  test "EXIF-oriented source with a gravity/region/fp/cover crop succeeds (no compensation crash)" do
    paths = [
      "/_/rs:fill:90:90/g:no/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:60/g:ce/f:png/plain/images/x.jpg",
      "/_/c:60:40:no/f:png/plain/images/x.jpg",
      "/_/c:60:40:no:5:6/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:90/g:so:0:8/f:png/plain/images/x.jpg",
      "/_/g:fp:0.25:0.75/rs:fill:80:80/f:png/plain/images/x.jpg",
      "/_/c:90:90:fp:0.25:0.75/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      conn = call_imgproxy(path, oriented_frame_opts(orientation))

      assert conn.status == 200,
             "EXIF-#{orientation} #{path} returned #{conn.status} (expected 200)"
    end
  end

  # The wire-vs-orientation-1 oracle. For each EXIF orientation 1..8 (including the
  # mirrors 2/4/5/7 and the axis-swapping quarter turns 5/6/7/8), the SAME imgproxy
  # request is run against the EXIF-oriented source and against the orientation-1
  # twin carrying the same displayed pixels. Identical operators on both legs ⇒ the
  # decoded interior pixels match (lossless PNG twin; the oriented leg is JPEG, so
  # a small interior tolerance absorbs decode noise — direction is still pinned).
  #
  # Covered geometry forms (zero-offset, where the orientation-1 twin is an exact
  # equivalence): center / non-center anchor crop, focus-point crop, smart crop,
  # explicit region crop, cover/fill result crop with center AND non-center
  # gravity, plus fit / force including coprime (91×61) source-divergent targets.
  #
  # NOT covered here (see the moduledoc note and the BLOCKED report): non-zero
  # gravity OFFSETS combined with a rotation, and min-dimension (mw/mh) under a
  # quarter turn — the first because imgproxy applies offsets pre-rotation so the
  # untransformed twin is not a valid equivalence (offset compensation is pinned at
  # the unit level in OrientationTest), the second because of a real cover+min-dim
  # frame bug surfaced by this oracle.
  test "crop/resize matrix matches the orientation-1 twin across EXIF 1..8" do
    paths = [
      # anchor crops: center + non-center
      "/_/c:60:40:ce/f:png/plain/images/x.jpg",
      "/_/c:60:40:no/f:png/plain/images/x.jpg",
      "/_/c:50:60:we/f:png/plain/images/x.jpg",
      # focus-point crop (center-ish and off-center)
      "/_/c:90:90:fp:0.25:0.75/f:png/plain/images/x.jpg",
      # smart crop (attention saliency on the displayed pixels)
      "/_/rs:fill:80:80/g:sm/f:png/plain/images/x.jpg",
      # cover/fill result crop: center + non-center gravity
      "/_/rs:fill:90:90/g:ce/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:90/g:no/f:png/plain/images/x.jpg",
      "/_/rs:fill:90:60/g:so/f:png/plain/images/x.jpg",
      # fp-guided cover
      "/_/g:fp:0.25:0.75/rs:fill:80:80/f:png/plain/images/x.jpg",
      # rounding-sensitive coprime targets: fit / force / fill
      "/_/rs:fit:91:61/f:png/plain/images/x.jpg",
      "/_/rs:force:91:61/f:png/plain/images/x.jpg",
      "/_/rs:fill:91:61/g:ce/f:png/plain/images/x.jpg"
    ]

    for orientation <- 1..8, path <- paths do
      oriented = call_imgproxy(path, oriented_frame_opts(orientation))
      twin = call_imgproxy(path, orientation1_twin_opts(orientation))

      assert oriented.status == 200, "oriented EXIF-#{orientation} #{path}: #{oriented.status}"
      assert twin.status == 200, "twin EXIF-#{orientation} #{path}: #{twin.status}"

      assert_twin_oracle_match(
        decoded_image(oriented),
        decoded_image(twin),
        "EXIF-#{orientation} #{path}"
      )
    end
  end

  # Embedded EXIF orientation tag in the OUTPUT, asserted only under sm:0
  # (strip_metadata=false). The default sm:1 strips the tag regardless of ar, so
  # the ar:0-keeps-the-tag case below holds only because sm:0 disables stripping
  # — it does NOT generalize. imgproxy's autorotate consumes and removes the tag;
  # ar:0 leaves the bytes (and tag) untouched.
  test "ar/sm control the residual output orientation tag (sm:0)" do
    # (a) ar:1 + tagged source: tag absent (autorotate stripped it), pixels rotated.
    rotated = call_imgproxy("/_/sm:0/f:png/plain/images/x.jpg", oriented_frame_opts(6))
    assert rotated.status == 200
    assert output_orientation_tag(rotated) in [nil, 1]
    # EXIF-6 displays the 120×200 portrait as 200×120 landscape.
    assert dimensions(rotated) == {200, 120}

    # (b) ar:0 + tagged source under sm:0: tag PRESENT, pixels unrotated (stored).
    unrotated =
      call_imgproxy(
        "/_/ar:0/sm:0/f:png/plain/images/x.jpg",
        oriented_frame_opts(6, imgproxy: [auto_rotate: true])
      )

    assert unrotated.status == 200
    assert output_orientation_tag(unrotated) == 6
    assert dimensions(unrotated) == {120, 200}

    # (c) ar:1 + orientation-1 source: nothing to rotate, no tag introduced.
    twin = call_imgproxy("/_/sm:0/f:png/plain/images/x.jpg", orientation1_twin_opts(6))
    assert twin.status == 200
    assert output_orientation_tag(twin) in [nil, 1]
    assert dimensions(twin) == {200, 120}
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

  test "detector_required + unavailable detector rejects before source AND cache access" do
    telemetry_prefix = [:image_pipe_wire_safety]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    opts =
      Keyword.merge(@default_opts,
        telemetry_prefix: telemetry_prefix,
        detector: UnavailableDetector,
        detector_required: true,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    conn = call_imgproxy("/_/rs:fill:80:80/g:obj:face/plain/images/beach.jpg", opts)

    assert conn.status == 422
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

  describe "sm/kcr metadata stripping" do
    # Note on libvips JPEG behavior: libvips always writes a minimal EXIF block
    # on JPEG encode (with image dimensions, color space, etc.) regardless of
    # metadata stripping. Therefore "exif-data present" is always true after JPEG
    # encode and cannot be used to assert stripping. The meaningful assertions are
    # on specific EXIF field values (e.g. copyright, image_description) and on
    # xmp-data, which is only present when the source carried it.

    test "sm:0 retains EXIF copyright, ImageDescription, and XMP; default (sm on) strips them" do
      # Establish the sm:0 baseline first: if the fixture itself lacks metadata,
      # these assertions will fail loudly rather than letting the default-strips
      # assertions pass as false negatives.
      kept_conn =
        call_imgproxy(
          "/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert kept_conn.status == 200

      {kept_image, kept_fields} = response_metadata(kept_conn)
      {:ok, kept_exif} = Image.exif(kept_image)

      assert Map.get(kept_exif, :copyright) == "(c) ACME",
             "sm:0 baseline: copyright must be present; fixture is missing EXIF copyright"

      assert Map.get(kept_exif, :image_description) == "A test image",
             "sm:0 baseline: ImageDescription must be present; fixture is missing EXIF ImageDescription"

      assert "xmp-data" in kept_fields,
             "sm:0 baseline: xmp-data must be present; fixture is missing XMP metadata"

      # Default request (sm on, kcr on): XMP and non-copyright EXIF fields must
      # be stripped. Copyright is preserved by kcr:1 (the default).
      default_conn =
        call_imgproxy(
          "/_/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert default_conn.status == 200

      {default_image, default_fields} = response_metadata(default_conn)
      {:ok, default_exif} = Image.exif(default_image)

      refute "xmp-data" in default_fields,
             "default (sm on): xmp-data must be stripped from the response"

      refute Map.has_key?(default_exif, :image_description),
             "default (sm on): non-copyright EXIF field (ImageDescription) must be stripped"

      assert Map.get(default_exif, :copyright) == "(c) ACME",
             "default (kcr on): copyright must be retained"
    end

    test "sm:1/kcr:0 strips copyright along with other EXIF and XMP" do
      # Baseline: the fixture carries copyright, so the refute below is meaningful
      # even when this test runs in isolation.
      baseline =
        call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", metadata_origin_opts())

      {baseline_image, _baseline_fields} = response_metadata(baseline)
      {:ok, baseline_exif} = Image.exif(baseline_image)
      assert Map.get(baseline_exif, :copyright) == "(c) ACME"

      conn =
        call_imgproxy(
          "/_/sm:1/kcr:0/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert conn.status == 200

      {image, field_names} = response_metadata(conn)
      {:ok, exif} = Image.exif(image)

      refute Map.has_key?(exif, :copyright),
             "kcr:0: copyright must be stripped along with other metadata"

      refute "xmp-data" in field_names,
             "kcr:0: xmp-data must be stripped"
    end

    test "sm:1/kcr:1 keeps EXIF copyright while stripping non-copyright EXIF and XMP" do
      # Baseline: confirm the fixture actually carries the non-copyright EXIF
      # field, so the "stripped" refute below cannot pass vacuously even when
      # this test runs in isolation.
      baseline =
        call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", metadata_origin_opts())

      {baseline_image, _baseline_fields} = response_metadata(baseline)
      {:ok, baseline_exif} = Image.exif(baseline_image)
      assert Map.get(baseline_exif, :image_description) == "A test image"

      conn =
        call_imgproxy(
          "/_/sm:1/kcr:1/scp:0/f:jpeg/plain/images/meta.jpg",
          metadata_origin_opts()
        )

      assert conn.status == 200

      {image, field_names} = response_metadata(conn)
      {:ok, exif} = Image.exif(image)

      # Copyright must be retained.
      assert Map.get(exif, :copyright) == "(c) ACME",
             "kcr:1: copyright must equal the original value"

      # Non-copyright EXIF field (ImageDescription) must be gone.
      refute Map.has_key?(exif, :image_description),
             "kcr:1: non-copyright EXIF field (ImageDescription) must be stripped"

      # XMP must be stripped.
      refute "xmp-data" in field_names,
             "kcr:1: xmp-data must be stripped"
    end

    test "sm flag produces an isolated filesystem-cache variant" do
      {opts, cache_root} =
        cached_opts(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test",
               req_options: [plug: {MetadataOriginImage, test_pid: self()}]}
          ]
        )

      try do
        # Default (sm on): cache miss, EXIF stripped.
        stripped = call_imgproxy("/_/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert stripped.status == 200
        assert_received :origin_fetch

        # sm:0: distinct cache key -> cache miss, EXIF retained, different bytes.
        kept = call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert kept.status == 200
        assert_received :origin_fetch
        refute kept.resp_body == stripped.resp_body

        # Re-request sm:0: cache hit (no origin fetch), identical bytes — the
        # variant was cached separately, not cross-served from the default entry.
        kept_again = call_imgproxy("/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg", opts)
        assert kept_again.status == 200
        refute_received :origin_fetch
        assert kept_again.resp_body == kept.resp_body
      after
        File.rm_rf!(cache_root)
      end
    end
  end

  describe "scp color-profile normalization" do
    # Note: `Image.to_colorspace(img, :p3, [])` attaches a P3 ICC profile to the
    # in-memory image, which libvips embeds in PNG output. Re-opening the PNG bytes
    # confirms "icc-profile-data" is present, so the scp:0 baseline assertion will
    # fail loudly if the source generation ever loses the profile, preventing the
    # scp:1 "dropped" assertion from passing as a false negative.
    #
    # Unlike EXIF (which libvips regenerates minimally on JPEG encode), libvips does
    # NOT synthesize an ICC profile — it embeds one only when the image carries it.
    # Therefore "icc-profile-data" presence/absence is a meaningful scp assertion.

    test "scp:0 retains the embedded ICC profile; scp:1 (default) drops it and outputs sRGB" do
      # Establish the scp:0 baseline first: if the source lost its ICC profile,
      # these assertions fail loudly and prevent the scp:1 refute from passing
      # vacuously against a profile-less output.
      scp0_conn =
        call_imgproxy(
          "/_/scp:0/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert scp0_conn.status == 200

      {_scp0_image, scp0_fields} = response_metadata(scp0_conn)

      assert "icc-profile-data" in scp0_fields,
             "scp:0 baseline: icc-profile-data must be present; source lost its ICC profile"

      # scp:1: the NormalizeColorProfile transform converts pixels to sRGB and the
      # encoder drops the icc-profile-data header at finalize.
      scp1_conn =
        call_imgproxy(
          "/_/scp:1/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert scp1_conn.status == 200

      {scp1_image, scp1_fields} = response_metadata(scp1_conn)

      refute "icc-profile-data" in scp1_fields,
             "scp:1: icc-profile-data must be absent from the response"

      assert Image.colorspace(scp1_image) == :srgb,
             "scp:1: output colorspace must be sRGB (NormalizeColorProfile converted pixels)"
    end

    test "default request (no scp in URL) drops the ICC profile" do
      # Same as scp:1 but exercises the default plan: strip_color_profile is true
      # by default in Plan.Output, so no explicit scp option is needed.
      default_conn =
        call_imgproxy(
          "/_/f:png/plain/images/wide.png",
          wide_gamut_origin_opts()
        )

      assert default_conn.status == 200

      {_default_image, default_fields} = response_metadata(default_conn)

      refute "icc-profile-data" in default_fields,
             "default (scp on): icc-profile-data must be absent from the response"
    end
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

  # Task 10: Pixel divergence — g:obj:car crop biases toward the detected corner
  # object, distinct from both center gravity and attention (smart) gravity.
  test "g:obj:car crop biases toward the detected object, differing from center and attention" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)

    obj = call_imgproxy("/_/rs:fill:50:50/g:obj:car/f:jpeg/plain/images/beach.jpg", opts)
    centered = call_imgproxy("/_/rs:fill:50:50/g:ce/f:jpeg/plain/images/beach.jpg", opts)
    attention = call_imgproxy("/_/rs:fill:50:50/g:sm/f:jpeg/plain/images/beach.jpg", opts)

    assert obj.status == 200
    assert dimensions(obj) == {50, 50}
    refute obj.resp_body == centered.resp_body
    refute obj.resp_body == attention.resp_body
  end

  # Task 10: No-geometry — g:obj:car without resize/crop must return 200.
  test "no-geometry g:obj:car returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)

    conn = call_imgproxy("/_/g:obj:car/plain/images/beach.jpg", opts)

    assert conn.status == 200
  end

  # Task 10: Gate triad — class-aware strict gate with PartialDetector.
  # Face child: available, owns ["face"]. Object child: unavailable, owns ["car"].
  test "detector_required gate triad: face->200, unicorn->200(degrade), car->422 pre-fetch" do
    opts = Keyword.merge(@default_opts, detector: PartialDetector, detector_required: true)

    # face child available -> routes and succeeds
    face_conn = call_imgproxy("/_/rs:fill:50:50/g:obj:face/f:jpeg/plain/images/beach.jpg", opts)
    assert face_conn.status == 200

    # unknown class routes to no child -> available? vacuously true -> degrades to 200
    unicorn_conn =
      call_imgproxy("/_/rs:fill:50:50/g:obj:unicorn/f:jpeg/plain/images/beach.jpg", opts)

    assert unicorn_conn.status == 200

    # object child unavailable -> 422 BEFORE any source fetch or cache access.
    # Copy the exact setup from "detector_required + unavailable detector" test (~line 599).
    telemetry_prefix = [:image_pipe_wire_gate_triad]
    source_resolve_start = telemetry_prefix ++ [:source, :resolve, :start]

    attach_source_resolve_telemetry(telemetry_prefix)

    gate_opts =
      Keyword.merge(opts,
        telemetry_prefix: telemetry_prefix,
        cache: {CacheProbe, []},
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]}
        ]
      )

    car_conn =
      call_imgproxy("/_/rs:fill:50:50/g:obj:car/f:jpeg/plain/images/beach.jpg", gate_opts)

    assert car_conn.status == 422
    refute_received {:telemetry_event, ^source_resolve_start, _, _}
    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry}
    refute_received :origin_fetch
  end

  # Slice 2: a face weight measurably changes the crop end-to-end. Exact focal
  # math is pinned in FocalTest; here we only prove the weight reaches pixels.
  # rs:fill:2000:2000 on beach.jpg (4000×2667) scales to 3000×2000, large enough
  # that the WeightedSceneDetector boxes ({2000,800,800,1000} and {1400,600,400,400})
  # both fit and the uniform vs boosted centroids land at different crop positions.
  test "objw face weight changes the rendered crop vs uniform" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    uniform =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    boosted =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg",
        opts
      )

    assert uniform.status == 200
    assert boosted.status == 200
    assert dimensions(boosted) == {2000, 2000}
    refute boosted.resp_body == uniform.resp_body
  end

  # Slice 2: uniform-weight objw canonicalizes to obj:all (the weight scalar
  # cancels in the centroid), so it renders identically. (Cache-key identity is a
  # separate question, covered in the cache task — not asserted here.)
  test "objw with all-equal weights renders identically to obj:all" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    objw =
      call_imgproxy("/_/rs:fill:2000:2000/g:objw:all:2/f:jpeg/plain/images/beach.jpg", opts)

    obj = call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw.resp_body == obj.resp_body
  end

  # Slice 2: the c:W:H:objw crop form reaches the crop path and applies the weight.
  test "c:W:H:objw crop form applies the weight" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    weighted =
      call_imgproxy("/_/c:2000:2000:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)

    uniform = call_imgproxy("/_/c:2000:2000:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert weighted.status == 200
    refute weighted.resp_body == uniform.resp_body
  end

  # Slice 2: no-geometry objw returns 200.
  test "no-geometry g:objw returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)
    conn = call_imgproxy("/_/g:objw:all:1:face:3/plain/images/beach.jpg", opts)
    assert conn.status == 200
  end

  # Filtering: objw:face:3 must gate detection to the face class only (not all),
  # so its crop matches obj:face (face box only) and DIFFERS from obj:all (both boxes).
  # WeightedSceneDetector returns a person box (large, right-of-center) and a face box
  # (small, left-of-center), filtered by opts[:classes].
  #
  # Beach.jpg is 4000x2667. WeightedSceneDetector boxes:
  #   person: {2000,800,800,1000} center_x=2400 (60% across) — right side
  #   face:   {1400,600,400,400}  center_x=1600 (40% across) — left side
  # rs:fill:2000:2000 scales to 3000×2000, crops 1000px horizontally:
  #   face-only focal_x_scaled ≈ 1200 → crop_x=200
  #   obj:all focal_x_scaled ≈ 1614 → crop_x=614
  # These are 414px apart in a 1000px-crop range, reliably different bytes.
  test "g:objw:face:3 filters to face class — matches obj:face, differs from obj:all" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    # objw:face:3 — spec is ["face"], detects only face box (single class → weight inert)
    objw_face =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:face:3/f:jpeg/plain/images/beach.jpg",
        opts
      )

    # obj:face — spec is ["face"], same face-only detection
    obj_face =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:face/f:jpeg/plain/images/beach.jpg", opts)

    # obj:all — spec is :all, both person and face boxes counted (person dominates due to size)
    obj_all =
      call_imgproxy("/_/rs:fill:2000:2000/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw_face.status == 200
    assert obj_face.status == 200
    assert obj_all.status == 200

    # objw:face:3 detects only face -> same crop focus as obj:face
    assert objw_face.resp_body == obj_face.resp_body

    # objw:face:3 differs from obj:all because detection set differs (face-only vs all)
    # The face (left-of-center, crop_x≈200) vs all-classes (crop_x≈614) produces different crops.
    refute objw_face.resp_body == obj_all.resp_body
  end

  # Security: near-max-float objw weight must be rejected cleanly (4xx), not crash (500).
  # WeightedSceneDetector returns face and person boxes in a large region of beach.jpg
  # (4000x2667), so rs:fill:2000:2000 keeps them in-bounds after resize; without the
  # fix, weighted_centroid raises ArithmeticError with a 1e308 face weight. With the
  # fix, the weight is rejected at parse time and the source is never fetched.
  test "objw weight at 1e308 is rejected with 4xx before any source fetch" do
    opts =
      Keyword.merge(@default_opts,
        detector: WeightedSceneDetector,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {CountingOriginImage, test_pid: self()}]}
        ]
      )

    conn =
      call_imgproxy(
        "/_/rs:fill:2000:2000/g:objw:face:1e308/f:jpeg/plain/images/beach.jpg",
        opts
      )

    assert conn.status in 400..499
    refute_received :origin_fetch
  end

  # Layer 4 — wire conformance for now-sequential chains

  # Anchor crop + blur: c:40:30:no (north gravity) + bl:4 were previously forced to
  # random access by the blur; they are now fully sequential. Assert the crop
  # dimensions are preserved and the body decodes cleanly.
  test "anchor crop + blur produces the requested crop dimensions and decodes" do
    conn =
      call_imgproxy(
        "/_/c:40:30:no/bl:4/f:png/plain/images/effects.png",
        effect_origin_opts()
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]

    image = decoded_image(conn)

    assert Image.width(image) == 40
    assert Image.height(image) == 30
  end

  # Resize fill + padding + background: rs:fill:100:100/g:ce + pd:10 + bg:ffffff.
  # Each pd:10 side adds 10px → final canvas is 120×120. The corner pixel (0,0)
  # sits in the padding region and must match the background color (white).
  test "resize fill + padding + background produces padded dimensions with background fill" do
    conn =
      call_imgproxy(
        "/_/rs:fill:100:100/g:ce/pd:10/bg:ffffff/f:png/plain/images/beach.jpg",
        @default_opts
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]

    image = decoded_image(conn)

    assert Image.width(image) == 120
    assert Image.height(image) == 120

    # Corner (0,0) is in the padding region → must be the background white.
    assert Image.get_pixel!(image, 0, 0) == [255, 255, 255]
  end

  # Transparent source + blur + background: a fully-transparent RGBA source with
  # bl:2 + bg:ff0000 must produce an opaque output (no alpha channel) whose pixels
  # are the background red (the transparent source contributes 0 color, so
  # flatten fills with the background color).
  test "transparent source + blur + background flattens to background color" do
    alpha_opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {ImagePipe.SourceTest.RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: AlphaOriginImage]}
      ]
    ]

    conn =
      call_imgproxy(
        "/_/bl:2/bg:ff0000/f:png/plain/images/alpha.png",
        alpha_opts
      )

    assert conn.status == 200
    assert content_type(conn) == ["image/png"]

    image = decoded_image(conn)

    assert Image.has_alpha?(image) == false
    # Fully transparent source + red background → all pixels must be red.
    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0]
    assert Image.get_pixel!(image, 10, 10) == [255, 0, 0]
  end

  # Capture the cache key the plug looked up for one request. Uses the file's
  # existing CacheProbe (it sends {:cache_lookup, key}) and call_imgproxy/2.
  defp lookup_key(path, opts) do
    call_imgproxy(path, opts)
    assert_received {:cache_lookup, key}
    key
  end

  defp probe_opts do
    Keyword.merge(@default_opts, cache: {CacheProbe, []})
  end

  defp ver_opts(extra) do
    Keyword.merge(probe_opts(), [detector: VerComposite] ++ extra)
  end

  test "object-only request key is independent of the face model identity" do
    assert lookup_key(
             "/_/rs:fill:50:50/g:obj:car/plain/images/beach.jpg",
             ver_opts(face_ver: :v1)
           ) ==
             lookup_key(
               "/_/rs:fill:50:50/g:obj:car/plain/images/beach.jpg",
               ver_opts(face_ver: :v2)
             )
  end

  test "face-only request key is independent of the object model identity" do
    assert lookup_key(
             "/_/rs:fill:50:50/g:obj:face/plain/images/beach.jpg",
             ver_opts(object_ver: :v1)
           ) ==
             lookup_key(
               "/_/rs:fill:50:50/g:obj:face/plain/images/beach.jpg",
               ver_opts(object_ver: :v2)
             )
  end

  test "mixed request key changes when either model identity changes" do
    base =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v1, object_ver: :v1)
      )

    diff_face =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v2, object_ver: :v1)
      )

    diff_obj =
      lookup_key(
        "/_/rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg",
        ver_opts(face_ver: :v1, object_ver: :v2)
      )

    assert base != diff_face
    assert base != diff_obj
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

  defp oriented_frame_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {OrientedFrameOrigin, orientation}]}
        ]
      ],
      overrides
    )
  end

  defp orientation1_twin_opts(orientation, overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test",
             req_options: [plug: {Orientation1TwinOrigin, orientation}]}
        ]
      ],
      overrides
    )
  end

  defp output_orientation_tag(%Plug.Conn{} = conn) do
    image = decoded_image(conn)

    case VipsImage.header_value(image, "orientation") do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end

  # Wire-vs-orientation-1 oracle assertion: same dimensions, and interior flat-region
  # pixels match within a small tolerance (the oriented leg round-trips through JPEG;
  # the twin is lossless PNG). Sampling at 1/8 and 7/8 stays inside the solid
  # quadrants, away from the red/green seam where a ±1px affine shift would ring.
  defp assert_twin_oracle_match(oriented, twin, label) do
    assert {Image.width(oriented), Image.height(oriented)} ==
             {Image.width(twin), Image.height(twin)},
           "#{label}: dims #{inspect({Image.width(oriented), Image.height(oriented)})} != twin #{inspect({Image.width(twin), Image.height(twin)})}"

    xs = bounded_samples(Image.width(oriented))
    ys = bounded_samples(Image.height(oriented))

    for x <- xs, y <- ys do
      op = Image.get_pixel!(oriented, x, y)
      tp = Image.get_pixel!(twin, x, y)

      assert pixels_close?(op, tp),
             "#{label}: pixel mismatch at (#{x},#{y}): #{inspect(op)} vs twin #{inspect(tp)}"
    end
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

  defp metadata_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: MetadataOriginImage]}
      ]
    ]
  end

  defp wide_gamut_origin_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: WideGamutOriginImage]}
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

  defp response_metadata(%Plug.Conn{} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {:ok, field_names} = VipsImage.header_field_names(image)
    {image, field_names}
  end

  defp sampled_pixels(image) do
    for x <- [8, 16, 24, 32, 40, 48, 56],
        y <- [8, 24, 40, 56] do
      Image.get_pixel!(image, x, y)
    end
  end

  # The oriented.jpg fixture's STORED pixels (40w x 80h, red 40x40 at top), with NO
  # EXIF orientation tag so reference primitives never autorotate.
  defp oriented_fixture_storage do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
  end

  defp reference_user_rot90_storage,
    do: oriented_fixture_storage() |> Image.rotate!(90) |> jpeg_roundtrip()

  defp reference_180_of_stored,
    do: oriented_fixture_storage() |> Image.rotate!(180) |> jpeg_roundtrip()

  # Round-trip through JPEG so the reference carries the same lossy artifacts as the
  # pipeline output; direction is pinned by the flat-region comparison.
  defp jpeg_roundtrip(image) do
    image
    |> Image.write!(:memory, suffix: ".jpg")
    |> Image.open!(access: :random, fail_on: :error)
  end

  # Sample within the (possibly small) bounds shared by both images.
  defp assert_oriented_pixels_match(actual, reference) do
    assert dimensions(actual) == dimensions(reference)

    {w, h} = dimensions(actual)
    xs = bounded_samples(w)
    ys = bounded_samples(h)

    for x <- xs, y <- ys do
      actual_px = Image.get_pixel!(actual, x, y)
      reference_px = Image.get_pixel!(reference, x, y)

      assert pixels_close?(actual_px, reference_px),
             "pixel mismatch at (#{x},#{y}): #{inspect(actual_px)} vs #{inspect(reference_px)}"
    end
  end

  # The pipeline output is JPEG-encoded then decoded, so allow small lossy deltas;
  # direction (which corner is red vs white) is still pinned by the flat-region match.
  defp pixels_close?(a, b) when length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.all?(fn {av, bv} -> abs(av - bv) <= 12 end)
  end

  # Sample deep inside each half of the image, avoiding both the outer edges (libvips
  # rotate can leave sub-pixel artifacts there) and the geometric mid-seam between the
  # fixture's red block and white fill (JPEG ringing). 1/8 and 7/8 sit firmly in the
  # flat fill regions, so direction is still pinned without straddling a boundary.
  defp bounded_samples(size) do
    last = max(size - 1, 0)
    Enum.uniq([div(last, 8), div(last * 7, 8)])
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
