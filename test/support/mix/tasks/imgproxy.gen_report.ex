defmodule Mix.Tasks.Imgproxy.GenReport do
  @shortdoc "Generate a self-contained visual-diff HTML report for the imgproxy differential suite"
  @moduledoc """
  Renders ImagePipe live for every constellation in `constellations.ex`, compares
  against the committed imgproxy fixtures, and writes a single self-contained
  `report.html` (images base64-inlined, slider + fonts from CDN). No Docker — the
  imgproxy fixtures are already committed and ImagePipe renders are live. A DX /
  inspection tool only: it touches no fixtures, manifest, or the `mix test` lane.

      MIX_ENV=test mise exec -- mix imgproxy.gen_report [--out PATH]

  `--out` defaults to `report.html` beside the harness (gitignored).
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  import Plug.Test, only: [conn: 2]

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest}

  @base "test/support/image_pipe/test/imgproxy_differential"
  @sources_dir "#{@base}/sources"
  @manifest_path "#{@base}/manifest.exs"
  @default_out "#{@base}/report.html"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    out = Keyword.get(opts, :out, @default_out)

    {:ok, _} = Application.ensure_all_started(:image)
    {:ok, _} = Application.ensure_all_started(:req)

    manifest = Manifest.load!(@manifest_path)
    plug_opts = plug_opts()

    cards = Enum.map(Constellations.all(), fn c -> build_card(c, manifest, plug_opts) end)

    File.write!(out, stub_html(cards))
    Mix.shell().info("Wrote visual-diff report (#{length(cards)} cards) to #{Path.expand(out)}")
  end

  # Throwaway placeholder body — replaced by the real HTML renderer in a later task.
  defp stub_html(cards) do
    body = Enum.map_join(cards, "\n", fn c -> ~s(<div id="#{c.id}">#{c.id}</div>) end)
    "<!doctype html><meta charset=\"utf-8\"><body>#{body}</body>"
  end

  # Card assembly stub — fleshed out in later tasks. For now just render the pipe
  # output so the end-to-end render path is exercised.
  defp build_card(c, _manifest, plug_opts) do
    {_body, _ct} = render(c, plug_opts)
    %{id: c.id}
  end

  defp render(c, plug_opts) do
    conn =
      :get
      |> conn(Constellations.imgproxy_path(c))
      |> ImagePipe.Plug.call(plug_opts)

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {conn.resp_body, content_type}
  end

  defp plug_opts do
    ImagePipe.Plug.init(
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: &source_plug/1]}
      ]
    )
  end

  # Function plug mirroring the conformance test's inline SourceOrigin: serve the
  # committed source bytes for the requested basename. RootHTTPAdapter forwards
  # `req_options` straight into Req.get, so a function plug wires identically to
  # the test's module plug.
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
