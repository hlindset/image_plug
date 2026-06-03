defmodule ImagePipe.DeferredOrientationPropertyTest do
  # Real image encode/decode per case — keep it serial and bound the runs.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter

  # Deferred orientation (#146): EXIF auto-orient and user rotate/flip are applied
  # AFTER crop/resize in the canonical model, but ImagePipe defers the flush for
  # performance. This property pins the two observable invariants of that deferral:
  #
  #   * No-geometry leg — EXIF 1..8 × random user rotate/flip with no crop/resize
  #     must EXACTLY match the same-primitive `autorotate ∘ rotate ∘ flip` reference
  #     (the flush uses these exact primitives, so equality is real, not tolerant).
  #
  #   * Crop/resize leg — the SAME imgproxy request on the EXIF-oriented source and
  #     on the orientation-1 twin (same displayed pixels, no tag) must land within
  #     ±1px on each axis and match interior flat-region pixels. Identical operators
  #     on both legs ⇒ rounding cancels; the residual is the affine resize's own
  #     ±1px scale-rounding floor (the same drift `shrink_on_load_property_test`
  #     pins). This is NOT a synthesized `Image.thumbnail` reference — the pipeline
  #     resizes with affine `Image.resize`, so the only sound oracle is wire-vs-
  #     orientation-1.
  #
  # Both legs run the SAME imgproxy request, so any frame-mismatch in the
  # compensation surfaces as a twin divergence. This includes cover + min-dimension
  # (mw/mh) under a quarter turn — resolved in the display frame (#146 Bug 2) — and
  # FP crops whose separate offset rotates as a displacement vector (#146 Bug 3).

  defmodule OrientedFrameOrigin do
    @moduledoc false

    def init({base_bytes, orientation}), do: {base_bytes, orientation}

    def call(conn, {base_bytes, orientation}) do
      body =
        base_bytes
        |> Image.open!(access: :random)
        |> Image.set_orientation!(orientation)
        |> Image.write!(:memory, suffix: ".jpg")

      conn
      |> put_resp_content_type("image/jpeg")
      |> send_resp(200, body)
    end
  end

  defmodule Orientation1TwinOrigin do
    @moduledoc false

    def init({base_bytes, orientation}), do: {base_bytes, orientation}

    def call(conn, {base_bytes, orientation}) do
      oriented =
        base_bytes
        |> Image.open!(access: :random)
        |> Image.set_orientation!(orientation)
        |> Image.write!(:memory, suffix: ".jpg")

      {:ok, {displayed, _flags}} = Image.autorotate(Image.open!(oriented, access: :random))

      body =
        displayed
        |> Image.set_orientation!(1)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> put_resp_content_type("image/png")
      |> send_resp(200, body)
    end
  end

  property "no-geometry: EXIF 1..8 × user rotate/flip matches the same-primitive reference" do
    check all(
            orientation <- integer(1..8),
            user_rotate <- member_of([0, 90, 180, 270]),
            flip <- member_of([nil, :horizontal, :vertical]),
            max_runs: 60
          ) do
      base = sharp_quadrants(64, 96)
      ops = rot_flip_ops(user_rotate, flip)

      out =
        "/_/#{ops}f:png/plain/images/x.jpg"
        |> request(oriented_opts(base, orientation))
        |> decoded()

      reference = orientation_only_reference(base, orientation, user_rotate, flip)

      assert {Image.width(out), Image.height(out)} ==
               {Image.width(reference), Image.height(reference)}

      for {x, y} <- interior_points(out) do
        assert Image.get_pixel!(out, x, y) == Image.get_pixel!(reference, x, y),
               "no-geometry EXIF-#{orientation} rot:#{user_rotate} flip:#{inspect(flip)} " <>
                 "mismatch at (#{x},#{y})"
      end
    end
  end

  property "crop/resize: EXIF 1..8 stays within ±1px of the orientation-1 twin" do
    check all(
            orientation <- integer(1..8),
            geometry <- geometry_path(),
            max_runs: 80
          ) do
      base = sharp_quadrants(120, 200)
      path = "/_/#{geometry}/f:png/plain/images/x.jpg"

      oriented = path |> request(oriented_opts(base, orientation)) |> decoded()
      twin = path |> request(twin_opts(base, orientation)) |> decoded()

      label = "EXIF-#{orientation} #{path}"

      assert abs(Image.width(oriented) - Image.width(twin)) <= 1 and
               abs(Image.height(oriented) - Image.height(twin)) <= 1,
             "#{label}: dims #{Image.width(oriented)}x#{Image.height(oriented)} drifted >1px " <>
               "from twin #{Image.width(twin)}x#{Image.height(twin)}"

      for {x, y} <- shared_interior_points(oriented, twin) do
        assert pixels_close?(Image.get_pixel!(oriented, x, y), Image.get_pixel!(twin, x, y)),
               "#{label}: interior pixel mismatch at (#{x},#{y})"
      end
    end
  end

  # ── Generators ───────────────────────────────────────────────────────────────

  defp geometry_path do
    member_of([
      "c:60:40:ce",
      "c:60:40:no",
      "c:50:60:we",
      "c:90:90:fp:0.25:0.75",
      "rs:fit:91:61",
      "rs:force:91:61",
      "rs:fill:90:90/g:ce",
      "rs:fill:90:90/g:no",
      "rs:fill:90:60/g:so",
      "g:fp:0.25:0.75/rs:fill:80:80",
      # cover + min-dimension under a quarter turn (#146 Bug 2)
      "rs:fill:91:61/mw:140/g:no",
      "rs:fill:90:90/mh:130/g:ce"
    ])
  end

  # ── References & helpers ─────────────────────────────────────────────────────

  defp orientation_only_reference(base_bytes, orientation, user_rotate, flip) do
    oriented =
      base_bytes
      |> Image.open!(access: :random)
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")
      |> Image.open!(access: :random)

    {:ok, {displayed, _flags}} = Image.autorotate(oriented)

    rotated = if user_rotate != 0, do: Image.rotate!(displayed, user_rotate), else: displayed
    flipped = if flip, do: Image.flip!(rotated, flip), else: rotated

    flipped
    |> Image.write!(:memory, suffix: ".png")
    |> Image.open!(access: :random)
  end

  defp rot_flip_ops(user_rotate, flip) do
    rot = if user_rotate != 0, do: "rot:#{user_rotate}/", else: ""

    flip_seg =
      case flip do
        :horizontal -> "fl:1:0/"
        :vertical -> "fl:0:1/"
        nil -> ""
      end

    rot <> flip_seg
  end

  defp sharp_quadrants(w, h) do
    Image.new!(w, h, color: :green)
    |> Image.Draw.rect!(0, 0, w, div(h, 2), color: :red)
    |> Image.Draw.rect!(0, 0, div(w, 4), div(w, 4), color: :blue)
    |> Image.write!(:memory, suffix: ".png")
  end

  defp oriented_opts(base_bytes, orientation),
    do: opts(OrientedFrameOrigin, base_bytes, orientation)

  defp twin_opts(base_bytes, orientation),
    do: opts(Orientation1TwinOrigin, base_bytes, orientation)

  defp opts(origin, base_bytes, orientation) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: {origin, {base_bytes, orientation}}]}
      ]
    ]
  end

  defp request(path, opts) do
    :get
    |> conn(path)
    |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp decoded(%Plug.Conn{status: 200} = conn),
    do: Image.open!(conn.resp_body, access: :random, fail_on: :error)

  defp interior_points(image) do
    w = Image.width(image)
    h = Image.height(image)

    for x <- bounded(w), y <- bounded(h), do: {x, y}
  end

  defp shared_interior_points(a, b) do
    w = min(Image.width(a), Image.width(b))
    h = min(Image.height(a), Image.height(b))

    for x <- bounded(w), y <- bounded(h), do: {x, y}
  end

  # 1/8 and 7/8 sit inside the solid quadrants, away from the red/green seam where
  # a ±1px affine shift would ring.
  defp bounded(size) do
    last = max(size - 1, 0)
    Enum.uniq([div(last, 8), div(last * 7, 8)])
  end

  defp pixels_close?(a, b) when length(a) == length(b) do
    a
    |> Enum.zip(b)
    |> Enum.all?(fn {av, bv} -> abs(av - bv) <= 12 end)
  end

  defp pixels_close?(_a, _b), do: false
end
