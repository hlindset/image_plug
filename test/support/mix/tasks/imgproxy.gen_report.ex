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
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, OptsSummary, PixelCompare}

  @base "test/support/image_pipe/test/imgproxy_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"
  @manifest_path "#{@base}/manifest.exs"
  @default_out "#{@base}/report.html"
  @default_tol %{threshold: 2, budget: 64}

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    out = Keyword.get(opts, :out, @default_out)

    {:ok, _} = Application.ensure_all_started(:image_pipe)

    manifest = Manifest.load!(@manifest_path)
    plug_opts = plug_opts()

    cards = Enum.map(Constellations.all(), fn c -> build_card(c, manifest, plug_opts) end)

    File.write!(out, stub_html(cards))
    Mix.shell().info("Wrote visual-diff report (#{length(cards)} cards) to #{Path.expand(out)}")
  end

  # Throwaway placeholder body — replaced by the real HTML renderer in a later task.
  defp stub_html(cards) do
    body =
      Enum.map_join(cards, "\n", fn c ->
        ~s(<div id="#{c.id}">#{c.id} — #{c.status} — #{c.metric_text}</div>)
      end)

    "<!doctype html><meta charset=\"utf-8\"><body>#{body}</body>"
  end

  defp build_card(c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    {body, content_type} = render(c, plug_opts)
    pipe = Image.open!(body, access: :random, fail_on: :error)

    %{
      id: c.id,
      group: display_group(c),
      verdict: c.verdict,
      url: Constellations.imgproxy_path(c),
      summary: OptsSummary.describe(c.opts),
      triage: c.triage,
      tol: c.tol,
      hash_drift?: Manifest.authored_sha256(c) != entry.authored_sha256,
      pipe_dims: dims(pipe)
    }
    |> Map.merge(group_fields(c, entry, pipe, content_type))
    |> finalize_attention()
  end

  # The `:diverges` constellation is stored as `group: :transform, verdict:
  # :diverges` (it IS a fixture pixel comparison). For the report's display
  # category/filter/counts it's its own bucket; the metric dispatch below still
  # uses the constellation's real `group`/`verdict`, so this is display-only.
  defp display_group(%{verdict: :diverges}), do: :diverges
  defp display_group(%{group: group}), do: group

  # transform / :diverges: compare against the committed fixture image.
  defp group_fields(%{group: :transform} = c, entry, pipe, _content_type) do
    fixture = fixture_image(entry)
    fixture_dims = dims(fixture)

    if fixture_dims != dims(pipe) do
      %{
        fixture_dims: fixture_dims,
        status: :dims_mismatch,
        metric_text: "dims #{fmt_dims(dims(pipe))} ≠ imgproxy #{fmt_dims(fixture_dims)}"
      }
    else
      Map.put(metric_fields(c, pipe, fixture), :fixture_dims, fixture_dims)
    end
  end

  defp group_fields(%{group: :lossy}, entry, pipe, content_type) do
    ok? = dims(pipe) == {entry.width, entry.height} and content_type == entry.content_type

    %{
      fixture_dims: nil,
      status: if(ok?, do: :contract_ok, else: :contract_mismatch),
      metric_text:
        "dims #{fmt_dims(dims(pipe))} (expected #{fmt_dims({entry.width, entry.height})}); " <>
          "type #{inspect(content_type)} (expected #{inspect(entry.content_type)})"
    }
  end

  defp metric_fields(%{verdict: :diverges} = c, pipe, fixture) do
    %{metric: :fraction_over, threshold: threshold, floor: floor} = c.divergence
    frac = PixelCompare.fraction_over(pipe, fixture, threshold)

    %{
      status: if(frac >= floor, do: :diverges_ok, else: :diverges_below_floor),
      metric_text: "#{Float.round(frac, 4)} fraction over Δ#{threshold} (floor #{floor})"
    }
  end

  defp metric_fields(%{verdict: :equal} = c, pipe, fixture) do
    tol = c.tol || @default_tol
    outliers = PixelCompare.outliers(pipe, fixture, tol.threshold)

    %{
      status: if(outliers <= tol.budget, do: :pass, else: :over_budget),
      metric_text: "#{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
    }
  end

  defp finalize_attention(card) do
    attention? =
      card.hash_drift? or
        card.status in [:over_budget, :diverges_below_floor, :dims_mismatch, :contract_mismatch]

    Map.put(card, :attention?, attention?)
  end

  defp fixture_image(entry) do
    Image.open!(File.read!(Path.join(@fixtures_dir, entry.fixture_filename)),
      access: :random,
      fail_on: :error
    )
  end

  defp dims(image), do: {Image.width(image), Image.height(image)}
  defp fmt_dims({w, h}), do: "#{w}×#{h}"

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
