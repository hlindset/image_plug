defmodule ImagePipe.ImgproxyDifferentialConformanceTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, PixelCompare, Skew}

  @base "test/support/image_pipe/test/imgproxy_differential"
  @fixtures_dir "#{@base}/fixtures"
  @manifest_path "#{@base}/manifest.exs"

  @default_tol %{threshold: 2, budget: 64}

  defmodule SourceOrigin do
    @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"
    def init(opts), do: opts

    def call(conn, _opts) do
      file = Path.basename(conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(content_type(file))
      |> Plug.Conn.send_resp(200, File.read!(Path.join(@sources_dir, file)))
    end

    defp content_type(f) do
      case Path.extname(f) do
        ".jpg" -> "image/jpeg"
        ".webp" -> "image/webp"
        _ -> "image/png"
      end
    end
  end

  setup_all do
    manifest = if File.exists?(@manifest_path), do: Manifest.load!(@manifest_path), else: nil

    # Warn-and-attempt: ImagePipe tracks bleeding-edge libvips while imgproxy lags,
    # so the versions rarely match. Empirically the ✅ stages still agree to
    # tolerance across minor libvips gaps, so we compare anyway and warn once — a
    # failure may reflect a libvips version difference rather than a regression.
    if manifest && not Skew.aligned?(manifest) do
      IO.puts(
        :stderr,
        "[imgproxy-differential] libvips skew: fixtures baked on #{manifest.imgproxy_libvips}, " <>
          "running #{Skew.runtime_libvips()}. Comparing anyway."
      )
    end

    {:ok, manifest: manifest}
  end

  for constellation <- Constellations.all() do
    @c constellation
    # Recorded-but-unresolved imgproxy discrepancies are quarantined: excluded by
    # default, runnable via `--include imgproxy_triage` (see the constellation's
    # `:triage` reason + tracking issue).
    if constellation[:triage], do: @tag(:imgproxy_triage)

    test "#{@c.id} (#{@c.verdict}/#{@c.group})", %{manifest: manifest} do
      if is_nil(manifest) do
        flunk(
          "No manifest at #{@manifest_path}. Bootstrap: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
        )
      end

      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed since generation — run `mix imgproxy.reauthor` " <>
               "(tol/verdict-only edits) or regenerate fixtures."

      run_constellation(@c, entry)
    end
  end

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} ->
        entry

      :error ->
        flunk(
          "#{id}: no manifest entry. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
        )
    end
  end

  defp run_constellation(%{verdict: :diverges} = c, entry) do
    out = imagepipe_image(c)
    fixture = fixture_image(c, entry)
    assert_same_dims!(c, out, fixture)

    %{metric: :fraction_over, threshold: threshold, floor: floor} = c.divergence
    frac = PixelCompare.fraction_over(out, fixture, threshold)

    assert frac >= floor,
           "#{c.id}: expected ≥ #{floor} fraction of band-bytes over Δ#{threshold}, got #{Float.round(frac, 4)}. " <>
             "If ImagePipe now matches imgproxy, flip this constellation to :equal and update the matrix."
  end

  defp run_constellation(%{group: :transform} = c, entry) do
    out = imagepipe_image(c)
    fixture = fixture_image(c, entry)
    assert_same_dims!(c, out, fixture)

    tol = c.tol || @default_tol
    outliers = PixelCompare.outliers(out, fixture, tol.threshold)

    assert outliers <= tol.budget,
           "#{c.id}: #{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
  end

  defp run_constellation(%{group: :lossy} = c, entry) do
    {out, content_type} = imagepipe_response(c)

    assert {Image.width(out), Image.height(out)} == {entry.width, entry.height},
           "#{c.id}: dims #{inspect({Image.width(out), Image.height(out)})} != #{inspect({entry.width, entry.height})}"

    assert content_type == entry.content_type,
           "#{c.id}: content-type #{inspect(content_type)} != #{inspect(entry.content_type)}"
  end

  defp assert_same_dims!(c, out, fixture) do
    assert PixelCompare.same_dims?(out, fixture),
           "#{c.id}: dims #{inspect(PixelCompare.dims(out))} != fixture #{inspect(PixelCompare.dims(fixture))}"
  end

  defp imagepipe_response(c) do
    conn =
      :get
      |> conn(Constellations.imgproxy_path(c))
      |> ImagePipe.Plug.call(plug_opts())

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {Image.open!(conn.resp_body, access: :random, fail_on: :error), content_type}
  end

  defp imagepipe_image(c), do: elem(imagepipe_response(c), 0)

  defp fixture_image(c, entry) do
    path = Path.join(@fixtures_dir, entry.fixture_filename)

    unless File.exists?(path) do
      flunk(
        "#{c.id}: missing fixture #{path}. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures"
      )
    end

    assert Manifest.file_sha256(path) == entry.fixture_sha256,
           "#{c.id}: fixture #{path} sha256 mismatch — corrupted or edited; regenerate."

    Image.open!(File.read!(path), access: :random, fail_on: :error)
  end

  defp plug_opts do
    ImagePipe.Plug.init(
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: SourceOrigin]}
      ]
    )
  end
end
