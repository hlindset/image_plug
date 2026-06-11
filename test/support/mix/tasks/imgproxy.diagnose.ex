defmodule Mix.Tasks.Imgproxy.Diagnose do
  @shortdoc "Triage table (dims/bands/maxΔ/histogram) for differential constellations — no Docker"
  @moduledoc """
  Renders the named constellations live and prints a one-line triage summary for
  each against the committed imgproxy fixture: output dims, band layout, the
  maximum band-byte delta, a band-byte count over Δ2/Δ16/Δ32, and PASS/over-budget
  against the constellation's authored tolerance. No Docker — fixtures are committed
  and the render is live (the same `Harness` the conformance test uses).

  `maxΔ` is the skew-vs-structural signal: a diffuse libvips-version resampling seam
  stays low (tens), while a placement/crop shift misaligns high-contrast edges
  toward ~255. A band/dim mismatch can't be pixel-compared and is flagged FINDING
  (it is itself a divergence — see #220).

      # specific constellations (e.g. triaging a failing bake)
      mise exec -- mix imgproxy.diagnose exif_extend_south trim_resize_high_freq

      # the whole suite
      mise exec -- mix imgproxy.diagnose

      # only cases needing attention (over budget / FINDING)
      mise exec -- mix imgproxy.diagnose --failing

  Auto-selects `MIX_ENV=test` via `mix.exs` `preferred_envs`.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Harness, Manifest, PixelCompare}

  @base "test/support/image_pipe/test/imgproxy_differential"
  @manifest_path "#{@base}/manifest.exs"
  @thresholds [2, 16, 32]

  @impl Mix.Task
  def run(args) do
    {opts, ids, _} = OptionParser.parse(args, strict: [failing: :boolean])
    failing_only? = Keyword.get(opts, :failing, false)

    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), &{&1.id, &1})

    selected =
      case ids do
        [] -> Constellations.all() |> Enum.map(& &1.id)
        chosen -> chosen
      end

    plug_opts = Harness.plug_opts()

    Enum.each(selected, fn id ->
      {attention?, line} =
        case Map.fetch(by_id, id) do
          {:ok, c} -> diagnose_line(c, manifest, plug_opts)
          :error -> {true, "#{pad(id)}unknown constellation id"}
        end

      unless failing_only? and not attention?, do: Mix.shell().info(line)
    end)
  end

  # Returns `{attention?, line}` — attention? marks a case worth eyeballing after a bake
  # (over budget, a band/dim FINDING, or an unknown id); `--failing` prints only those.
  defp diagnose_line(%{group: :lossy} = c, _manifest, plug_opts) do
    {body, content_type} = Harness.render(c, plug_opts)
    img = Image.open!(body, access: :random, fail_on: :error)

    {false,
     "#{pad(c.id)}lossy — dims #{Image.width(img)}×#{Image.height(img)}, type #{content_type}"}
  end

  defp diagnose_line(%{group: :transform} = c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    out = Harness.render_image(c, plug_opts)
    fixture = Harness.fixture_image(entry)
    tol = c.tol || Constellations.default_tol()
    d = PixelCompare.diagnose(out, fixture, Enum.uniq([tol.threshold | @thresholds]))
    attention? = not d.comparable or Map.fetch!(d.over, tol.threshold) > tol.budget

    {attention?, pad(c.id) <> body_for(d, tol)}
  end

  defp body_for(%{comparable: false} = d, _tol) do
    {{wa, ha}, {wb, hb}} = d.dims
    {ba, bb} = d.bands
    dims = if {wa, ha} == {wb, hb}, do: "#{wa}×#{ha}", else: "#{wa}×#{ha}≠#{wb}×#{hb}"
    "FINDING — bands #{ba}/#{bb}, dims #{dims} (not pixel-comparable)"
  end

  defp body_for(%{comparable: true} = d, tol) do
    {{w, h}, _} = d.dims
    {ba, _} = d.bands
    over = d.over
    hist = Enum.map_join(@thresholds, " ", fn t -> ">Δ#{t}=#{Map.fetch!(over, t)}" end)
    pass? = Map.fetch!(over, tol.threshold) <= tol.budget

    "dims #{w}×#{h}  bands #{ba}  maxΔ=#{d.max_delta}  #{hist}  " <>
      "tol Δ#{tol.threshold}/#{tol.budget} → #{if pass?, do: "PASS", else: "OVER BUDGET"}"
  end

  defp pad(id), do: String.pad_trailing(id, 34)
end
