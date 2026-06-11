defmodule ImagePipe.Test.ImgproxyDifferential.Harness do
  @moduledoc """
  Shared live-render machinery for the imgproxy differential harness. Builds the
  `ImagePipe.Plug` pipeline that serves the committed sources over a local function
  plug and renders a constellation's live output, so the conformance test,
  `mix imgproxy.gen_report`, and `mix imgproxy.diagnose` all render identically
  instead of each carrying its own copy of the plug wiring.
  """

  use Boundary, top_level?: true, check: [out: false]

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.ImgproxyDifferential.Constellations

  @base "test/support/image_pipe/test/imgproxy_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"

  @doc """
  `ImagePipe.Plug` opts wired to serve the committed sources locally. Build once and
  thread it through repeated `render/2` calls to avoid re-initializing per render.
  """
  def plug_opts do
    ImagePipe.Plug.init(
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: &source_plug/1]}
      ]
    )
  end

  @doc "Live ImagePipe render for a constellation → `{body_bytes, content_type}`."
  def render(constellation, plug_opts \\ plug_opts()) do
    conn =
      :get
      |> conn(Constellations.imgproxy_path(constellation))
      |> ImagePipe.Plug.call(plug_opts)

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {conn.resp_body, content_type}
  end

  @doc "Live ImagePipe render decoded to a `Vix.Vips.Image`."
  def render_image(constellation, plug_opts \\ plug_opts()) do
    {body, _content_type} = render(constellation, plug_opts)
    Image.open!(body, access: :random, fail_on: :error)
  end

  @doc "Absolute path to a manifest entry's committed fixture PNG."
  def fixture_path(%{fixture_filename: filename}), do: Path.join(@fixtures_dir, filename)

  @doc "Open a manifest entry's committed fixture PNG to a `Vix.Vips.Image`."
  def fixture_image(entry),
    do: Image.open!(File.read!(fixture_path(entry)), access: :random, fail_on: :error)

  # Function plug serving the committed source bytes for the requested basename.
  # RootHTTPAdapter forwards `req_options` straight into Req.get, so this wires
  # identically to a module plug.
  defp source_plug(conn) do
    file = Path.basename(conn.request_path)

    conn
    |> Plug.Conn.put_resp_content_type(content_type(file))
    |> Plug.Conn.send_resp(200, File.read!(Path.join(@sources_dir, file)))
  end

  defp content_type(file) do
    case Path.extname(file) do
      ".jpg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end
end
