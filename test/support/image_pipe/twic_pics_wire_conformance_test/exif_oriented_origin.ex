defmodule TwicPicsWireConformanceTest.ExifOrientedOrigin do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts

  # A 40x80 portrait frame (red square in the top-left) tagged with EXIF
  # orientation 6 (90 clockwise), so it *displays* as an 80x40 landscape.
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
