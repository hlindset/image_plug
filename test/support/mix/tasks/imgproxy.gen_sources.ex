defmodule Mix.Tasks.Imgproxy.GenSources do
  @shortdoc "Build committed synthetic source images for imgproxy differential conformance"
  @moduledoc """
  One-shot builder for the committed source images. No Docker. Run once; commit
  the outputs. Regenerating sources is a deliberate act (a libvips bump must not
  silently change inputs).

      mise exec -- mix imgproxy.gen_sources
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias Vix.Vips.Image, as: VipsImage

  @dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @w 1600
  @h 1200

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:image)
    File.mkdir_p!(@dir)

    chirp = chirp_image(@w, @h)
    write!(chirp, "high_freq.jpg", suffix: ".jpg", quality: 92)
    write!(chirp, "high_freq.webp", suffix: ".webp", quality: 92)

    marker =
      @w
      |> Image.new!(@h, color: [30, 30, 30])
      |> Image.Draw.rect!(div(@w, 8), div(@h, 8), div(@w, 6), div(@h, 6), color: [240, 40, 40])

    write!(marker, "marker.png", suffix: ".png")

    border =
      @w
      |> Image.new!(@h, color: [255, 255, 255])
      |> Image.Draw.rect!(120, 90, @w - 240, @h - 180, color: [20, 30, 200])

    write!(border, "border.png", suffix: ".png")

    {:ok, alpha} = Image.new(256, 256, color: [0, 200, 100, 128], bands: 4)
    write!(alpha, "alpha.png", suffix: ".png")

    exif_base =
      400
      |> Image.new!(300, color: [200, 180, 60])
      |> Image.Draw.rect!(0, 0, 200, 150, color: [40, 40, 200])

    for o <- [2, 3, 4, 5, 6, 7, 8] do
      exif_base
      |> Image.set_orientation!(o)
      |> write!("exif_#{o}.jpg", suffix: ".jpg", quality: 95)
    end

    icc =
      512
      |> Image.new!(512, color: [200, 50, 50])
      |> Image.Draw.rect!(0, 0, 64, 64, color: [255, 255, 255])
      |> Image.Draw.rect!(256, 0, 6, 512, color: [0, 255, 0])
      |> Image.Draw.rect!(0, 256, 512, 6, color: [0, 0, 255])

    {:ok, p3} = Image.to_colorspace(icc, :p3, [])
    write!(p3, "icc_p3.png", suffix: ".png")

    small =
      120
      |> Image.new!(90, color: [70, 130, 180])
      |> Image.Draw.rect!(10, 10, 40, 30, color: [255, 220, 0])

    write!(small, "small.png", suffix: ".png")

    Mix.shell().info("Wrote sources to #{@dir}")
  end

  @doc "Deterministic radial-chirp pixel buffer: `w*h*3` uchar bytes, row-major."
  def chirp_pixels(w, h) do
    cx = w / 2
    cy = h / 2
    k = 0.00025

    # Build an iolist then flatten once — avoids O(n^2) binary re-copy that a
    # `for … into: <<>>` accumulation incurs over millions of pixels.
    for y <- 0..(h - 1) do
      for x <- 0..(w - 1) do
        dx = x - cx
        dy = y - cy
        v = trunc(127.5 * (1.0 + :math.cos(k * (dx * dx + dy * dy))))
        <<v, v, v>>
      end
    end
    |> IO.iodata_to_binary()
  end

  defp chirp_image(w, h) do
    {:ok, img} = VipsImage.new_from_binary(chirp_pixels(w, h), w, h, 3, :VIPS_FORMAT_UCHAR)
    img
  end

  defp write!(image, filename, opts) do
    body = Image.write!(image, :memory, opts)
    File.write!(Path.join(@dir, filename), body)
  end
end
