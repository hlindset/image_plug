# imgproxy Visual-Diff HTML Report — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `mix imgproxy.gen_report` task that renders ImagePipe live for every differential constellation and writes a single self-contained `report.html` putting imgproxy vs ImagePipe side by side with a comparison slider, two diff heatmaps, and the live-recomputed conformance metric/verdict/triage per case.

**Architecture:** A `Mix.Task` (`check: [out: false]`, always compiled, no Docker) orchestrates: load the committed manifest → render each constellation through the *same* plug wiring the conformance test uses → compute the same per-group metric → build two libvips diff heatmaps → assemble card data → hand it to a pure HTML renderer. Two genuinely-pure pieces (opts→prose summary, HTML assembly) are isolated as `deps: []` support modules so they're unit-testable without the heavy render pass; the heatmap/render orchestration lives in the task. It reads only committed fixtures + live renders and writes nothing the test lane depends on.

**Tech Stack:** Elixir, Mix.Task, Plug.Test, Req (via `RootHTTPAdapter`), Vix/libvips (`Vix.Vips.Operation`, `Vix.Vips.Image`), the `image` library (`Image.*`), `Boundary`, ExUnit.

**Spec:** `docs/superpowers/specs/2026-06-11-imgproxy-gen-report-design.md`

---

## File structure

- **Create** `test/support/image_pipe/test/imgproxy_differential/opts_summary.ex` — pure `opts`-string → human prose. `use Boundary, top_level?: true, deps: []`.
- **Create** `test/support/image_pipe/test/imgproxy_differential/report_html.ex` — pure card-data + provenance → self-contained HTML string. `use Boundary, top_level?: true, deps: []`.
- **Create** `test/support/mix/tasks/imgproxy.gen_report.ex` — the task: args, manifest, render, metric, heatmaps, card assembly, write. `use Boundary, top_level?: true, check: [out: false]`.
- **Create** `test/image_pipe/imgproxy_gen_report_test.exs` — OptsSummary tests, ReportHtml tests, one full-task smoke test.
- **Modify** `.gitignore` — ignore the default `report.html` output.
- **Modify** `test/support/image_pipe/test/imgproxy_differential/README.md` — document the on-demand task.

Card-data map shape (the contract between the task (producer) and `ReportHtml` (consumer); a plain map, documented in `ReportHtml`'s `@moduledoc`):

```elixir
%{
  id: String.t(),
  group: :transform | :diverges | :lossy,
  verdict: :equal | :diverges,
  url: String.t(),            # Constellations.imgproxy_path/1
  summary: String.t(),        # OptsSummary.describe/1
  status: :pass | :over_budget | :diverges_ok | :diverges_below_floor
          | :dims_mismatch | :contract_ok | :contract_mismatch,
  attention?: boolean(),
  hash_drift?: boolean(),
  triage: nil | %{reason: String.t(), issue: String.t()},
  tol: nil | %{threshold: non_neg_integer(), budget: non_neg_integer()},
  metric_text: String.t(),
  imgproxy_img: nil | String.t(),   # data: URI (nil for lossy)
  pipe_img: String.t(),             # data: URI
  heat_banded: nil | String.t(),    # data: URI (nil for lossy / dims-mismatch)
  heat_raw: nil | String.t(),       # data: URI (nil for lossy / dims-mismatch)
  pipe_dims: {pos_integer(), pos_integer()},
  fixture_dims: nil | {pos_integer(), pos_integer()}
}
```

---

## Task 1: OptsSummary — opts string → human prose

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/opts_summary.ex`
- Test: `test/image_pipe/imgproxy_gen_report_test.exs`

- [ ] **Step 1: Write the failing tests**

Create `test/image_pipe/imgproxy_gen_report_test.exs` with just the OptsSummary block for now:

```elixir
defmodule ImagePipe.ImgproxyGenReportTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.OptsSummary

  describe "OptsSummary.describe/1" do
    test "resize + gravity" do
      assert OptsSummary.describe("rs:fill:240:180/g:ce") ==
               "resize fill 240×180; gravity center"
    end

    test "compound gravity codes and absolute offset" do
      assert OptsSummary.describe("c:120:90/g:nowe") == "crop 120×90; gravity north-west"
      assert OptsSummary.describe("rs:fill:120:120/g:no:10:20") ==
               "resize fill 120×120; gravity north +10,+20"
    end

    test "trim, min-dims, zoom, dpr" do
      assert OptsSummary.describe("t:10") == "trim (threshold 10)"
      assert OptsSummary.describe("rs:fit:300:300/mw:280/mh:280") ==
               "resize fit 300×300; min-width 280; min-height 280"
      assert OptsSummary.describe("z:0.5") == "zoom 0.5"
      assert OptsSummary.describe("rs:fit:80:80/dpr:2") == "resize fit 80×80; dpr 2"
    end

    test "extend variants" do
      assert OptsSummary.describe("rs:fit:300:200/ex:1") == "resize fit 300×200; extend"
      assert OptsSummary.describe("rs:fit:300:200/ex:1:so") ==
               "resize fit 300×200; extend (south)"
      assert OptsSummary.describe("rs:fit:400:150/ex:1:we:5:0") ==
               "resize fit 400×150; extend (west +5,+0)"
      assert OptsSummary.describe("rs:fit:300:200/exar:1") ==
               "resize fit 300×200; extend-aspect-ratio"
    end

    test "background, blur, sharpen, strip, format, quality" do
      assert OptsSummary.describe("rs:fit:64:64/bg:255:0:0") ==
               "resize fit 64×64; background rgb(255,0,0)"
      assert OptsSummary.describe("rs:fit:240:240/bl:3") == "resize fit 240×240; blur 3"
      assert OptsSummary.describe("rs:fit:240:240/sh:2") == "resize fit 240×240; sharpen 2"
      assert OptsSummary.describe("rs:fit:120:120/sm:1") ==
               "resize fit 120×120; strip-metadata on"
      assert OptsSummary.describe("rs:fit:200:200/scp:0") ==
               "resize fit 200×200; strip-color-profile off"
      assert OptsSummary.describe("rs:fill:240:180/q:40/f:jpg") ==
               "resize fill 240×180; quality 40; format jpg"
    end

    test "unknown segments echo verbatim" do
      assert OptsSummary.describe("rs:fit:64:64/wat:9") == "resize fit 64×64; wat:9"
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: FAIL — `OptsSummary` is undefined.

- [ ] **Step 3: Implement OptsSummary**

Create `test/support/image_pipe/test/imgproxy_differential/opts_summary.ex`:

```elixir
defmodule ImagePipe.Test.ImgproxyDifferential.OptsSummary do
  @moduledoc """
  Renders an imgproxy `opts` string (as stored on a constellation) into a short
  human-readable summary for the visual-diff report's card labels. Self-contained
  on purpose — a tiny dedicated formatter, not a reach into the parser — covering
  the option codes used in `constellations.ex`, with unknown segments echoed
  verbatim so it never hides syntax it doesn't recognize.
  """

  use Boundary, top_level?: true, deps: []

  @doc "Human-readable summary of a slash-separated imgproxy opts string."
  @spec describe(String.t()) :: String.t()
  def describe(opts) do
    opts
    |> String.split("/", trim: true)
    |> Enum.map_join("; ", &segment/1)
  end

  defp segment(seg) do
    case String.split(seg, ":") do
      ["rs", mode, w, h] -> "resize #{mode} #{w}×#{h}"
      ["rs", mode, w] -> "resize #{mode} #{w}"
      ["c", w, h] -> "crop #{w}×#{h}"
      ["t", n] -> "trim (threshold #{n})"
      ["g" | rest] -> "gravity #{gravity(rest)}"
      ["mw", n] -> "min-width #{n}"
      ["mh", n] -> "min-height #{n}"
      ["z", f] -> "zoom #{f}"
      ["pd" | vals] -> "padding #{Enum.join(vals, ",")}"
      ["ex" | rest] -> "extend#{extend_suffix(rest)}"
      ["exar" | _] -> "extend-aspect-ratio"
      ["dpr", n] -> "dpr #{n}"
      ["bg", r, g, b] -> "background rgb(#{r},#{g},#{b})"
      ["bl", n] -> "blur #{n}"
      ["sh", n] -> "sharpen #{n}"
      ["sm", f] -> "strip-metadata #{onoff(f)}"
      ["scp", f] -> "strip-color-profile #{onoff(f)}"
      ["el", f] -> "enlarge #{onoff(f)}"
      ["q", n] -> "quality #{n}"
      ["f", fmt] -> "format #{fmt}"
      _ -> seg
    end
  end

  defp gravity([code]), do: gravity_name(code)
  defp gravity([code, x, y]), do: "#{gravity_name(code)} +#{x},+#{y}"
  defp gravity(other), do: Enum.join(other, ":")

  defp gravity_name("ce"), do: "center"
  defp gravity_name("no"), do: "north"
  defp gravity_name("so"), do: "south"
  defp gravity_name("ea"), do: "east"
  defp gravity_name("we"), do: "west"
  defp gravity_name("noea"), do: "north-east"
  defp gravity_name("nowe"), do: "north-west"
  defp gravity_name("soea"), do: "south-east"
  defp gravity_name("sowe"), do: "south-west"
  defp gravity_name("sm"), do: "smart"
  defp gravity_name(other), do: other

  defp extend_suffix([_flag]), do: ""
  defp extend_suffix([_flag, code]), do: " (#{gravity_name(code)})"
  defp extend_suffix([_flag, code, x, y]), do: " (#{gravity_name(code)} +#{x},+#{y})"
  defp extend_suffix(_), do: ""

  defp onoff("0"), do: "off"
  defp onoff("1"), do: "on"
  defp onoff(x), do: x
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS (all OptsSummary tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/opts_summary.ex test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "test(imgproxy): opts-string human summary for visual-diff report (#202)"
```

---

## Task 2: Task skeleton — args, manifest, live render, stub HTML, gitignore

This establishes the full pipeline end-to-end with a throwaway one-line HTML body (replaced in Task 5), proving renders work before any metric/heatmap/template work.

**Files:**
- Create: `test/support/mix/tasks/imgproxy.gen_report.ex`
- Modify: `.gitignore`
- Test: `test/image_pipe/imgproxy_gen_report_test.exs`

- [ ] **Step 1: Add `.gitignore` entry**

Append to `.gitignore` (the file ends with a `tmp/` line):

```gitignore

# Generated imgproxy differential visual-diff report (regenerate on demand)
test/support/image_pipe/test/imgproxy_differential/report.html
```

- [ ] **Step 2: Write the failing smoke test**

Append to `test/image_pipe/imgproxy_gen_report_test.exs`, inside the module, after the `describe` block:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.Constellations

  test "gen_report renders every constellation to a self-contained file" do
    out =
      Path.join(System.tmp_dir!(), "imgproxy_report_#{System.unique_integer([:positive])}.html")

    on_exit(fn -> File.rm_rf(out) end)

    Mix.Tasks.Imgproxy.GenReport.run(["--out", out])

    assert File.exists?(out)
    html = File.read!(out)

    for c <- Constellations.all() do
      assert html =~ ~s(id="#{c.id}"), "report missing card anchor for #{c.id}"
    end
  end
```

Add `alias Mix.Tasks.Imgproxy.GenReport` is NOT needed (fully-qualified call used).

- [ ] **Step 3: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs:LINE` (the smoke test line)
Expected: FAIL — `Mix.Tasks.Imgproxy.GenReport` is undefined.

- [ ] **Step 4: Implement the task skeleton**

Create `test/support/mix/tasks/imgproxy.gen_report.ex`:

```elixir
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
  @fixtures_dir "#{@base}/fixtures"
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

  # Throwaway placeholder body — replaced by ReportHtml.render/1 in Task 5.
  defp stub_html(cards) do
    body = Enum.map_join(cards, "\n", fn c -> ~s(<div id="#{c.id}">#{c.id}</div>) end)
    "<!doctype html><meta charset=\"utf-8\"><body>#{body}</body>"
  end

  # Card assembly stub — fleshed out in Tasks 3 & 4. For now just render the pipe
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
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: &source_plug/1]}
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
```

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS — all cards render; the file contains every constellation id anchor.

- [ ] **Step 6: Commit**

```bash
git add test/support/mix/tasks/imgproxy.gen_report.ex .gitignore test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "feat(imgproxy): gen_report task skeleton + live render pipeline (#202)"
```

---

## Task 3: Card computation — metric, status, dims guard, hash drift

Fill in `build_card/3` with the real per-group computation, status/attention derivation, and authored-hash drift. No heatmaps yet (Task 4); image data URIs still absent.

**Files:**
- Modify: `test/support/mix/tasks/imgproxy.gen_report.ex`
- Test: `test/image_pipe/imgproxy_gen_report_test.exs`

- [ ] **Step 1: Extend the smoke test with status assertions**

In the smoke test (Task 2), after the `for c <- ...` loop, append:

```elixir
    # The two quarantined cases must surface their live over-budget divergence
    # (the triage badge annotates, it does not suppress the metric).
    assert html =~ "extend_offset_east_marker"
    assert html =~ "extend_ar_dpr_marker"

    # A status atom is emitted for at least the known-divergence case.
    assert html =~ "scp0_colorspace_124"
```

(These pass once cards carry status text rendered by the stub — see Step 3, which makes the stub echo status.)

- [ ] **Step 2: Run to confirm current state**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS already (ids are present). This step just re-baselines before changing internals.

- [ ] **Step 3: Implement real card computation**

Replace `build_card/3` (and add helpers + the `alias`) in `imgproxy.gen_report.ex`. First extend the alias line:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, OptsSummary, PixelCompare, Skew}
```

Add module attribute near the others:

```elixir
  @default_tol %{threshold: 2, budget: 64}
```

Replace `build_card/3` and the stub helpers. `group_fields/4` takes `content_type` (used only by the lossy clause; the others ignore it) and returns only `fixture_dims`, `status`, `metric_text` — no image structs (Task 4 reads images from locals/the entry, not the card):

```elixir
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
  defp group_fields(%{group: group} = c, entry, pipe, _content_type)
       when group in [:transform, :diverges] do
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
      metric_text:
        "#{Float.round(frac, 4)} fraction over Δ#{threshold} (floor #{floor})"
    }
  end

  defp metric_fields(%{verdict: :equal} = c, pipe, fixture) do
    tol = c.tol || @default_tol
    outliers = PixelCompare.outliers(pipe, fixture, tol.threshold)

    %{
      status: if(outliers <= tol.budget, do: :pass, else: :over_budget),
      metric_text:
        "#{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
    }
  end

  defp finalize_attention(card) do
    attention? =
      card.hash_drift? or
        card.status in [
          :over_budget,
          :diverges_below_floor,
          :dims_mismatch,
          :contract_mismatch
        ]

    Map.put(card, :attention?, attention?)
  end

  defp fixture_image(entry) do
    Image.open!(File.read!(Path.join(@fixtures_dir, entry.fixture_filename)),
      access: :random,
      fail_on: :error
    )
  end

  defp pipe_ct?(_pipe, entry), do: is_binary(entry.content_type)

  defp dims(image), do: {Image.width(image), Image.height(image)}
  defp fmt_dims({w, h}), do: "#{w}×#{h}"
```

Update the stub HTML to echo status so the in-progress report shows something meaningful and the smoke assertions hold:

```elixir
  defp stub_html(cards) do
    body =
      Enum.map_join(cards, "\n", fn c ->
        ~s(<div id="#{c.id}">#{c.id} — #{c.status} — #{c.metric_text}</div>)
      end)

    "<!doctype html><meta charset=\"utf-8\"><body>#{body}</body>"
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS. The stub now shows `id — status — metric`. The two triage cases appear as `over_budget` (their default-tol divergence), `scp0_colorspace_124` as `diverges_ok`.

- [ ] **Step 5: Manually eyeball the statuses (sanity, optional)**

Run: `MIX_ENV=test mise exec -- mix imgproxy.gen_report --out /tmp/r.html && grep -o 'extend_ar_dpr_marker — [a-z_]*' /tmp/r.html`
Expected: `extend_ar_dpr_marker — over_budget` (its 1-column Δ255 blows the default budget). Confirms triage cards surface live divergence.

- [ ] **Step 6: Commit**

```bash
git add test/support/mix/tasks/imgproxy.gen_report.ex test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "feat(imgproxy): per-group metric, status, dims-guard, hash-drift in gen_report (#202)"
```

---

## Task 4: Heatmaps — RGB-aligned banded + raw amplified, base64 data URIs

Add the two libvips heatmaps and convert every card image to a `data:` URI. Heatmaps only for transform/`:diverges` cards with matching dims.

**Files:**
- Modify: `test/support/mix/tasks/imgproxy.gen_report.ex`
- Test: `test/image_pipe/imgproxy_gen_report_test.exs`

- [ ] **Step 1: Extend the smoke test to assert inlined images + heatmaps**

In the smoke test, after the existing assertions, append:

```elixir
    assert html =~ "data:image/png;base64,", "no inlined PNG images in report"
    # alpha_resize / background_alpha exercise RGB band-alignment in the heatmap
    # path; the run must not crash on a band-count mismatch.
    assert html =~ "alpha_resize"
    assert html =~ "background_alpha"
```

- [ ] **Step 2: Run to confirm it currently fails the new assertion**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: FAIL on `data:image/png;base64,` (stub emits no images yet).

- [ ] **Step 3: Implement heatmaps + data URIs**

Add the alias for Vix Operation near the top:

```elixir
  alias Vix.Vips.Operation
```

Module attribute for the raw amplification factor:

```elixir
  @raw_amp 8
```

In `build_card/3`, after computing `base |> Map.merge(group_fields(...)) |> finalize_attention()`, pipe the card through image-attachment. Rename the existing terminal expression so it's bound, then attach images:

```elixir
  defp build_card(c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    {body, content_type} = render(c, plug_opts)
    pipe = Image.open!(body, access: :random, fail_on: :error)

    card =
      %{
        id: c.id,
        group: c.group,
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

    attach_images(card, body, content_type, pipe, entry)
  end
```

(The decoded `pipe` image and the fixture are locals — used only to build the metric/images, never stored on the card. `attach_images/5` re-reads the fixture via the entry. The card map already carries only `fixture_dims`/`status`/`metric_text` from Task 3's `group_fields/4`, so nothing needs stripping.)

Add `attach_images/5` and the heatmap helpers:

```elixir
  # Attach base64 data URIs. Images are displayed from ORIGINAL bytes (no
  # re-encode): the imgproxy fixture from its on-disk PNG, the pipe render from
  # the response body. Decoded images feed the diff/heatmaps only.
  defp attach_images(%{group: :lossy} = card, body, content_type, _pipe, _entry) do
    Map.merge(card, %{
      imgproxy_img: nil,
      pipe_img: data_uri(content_type, body),
      heat_banded: nil,
      heat_raw: nil
    })
  end

  defp attach_images(%{status: :dims_mismatch} = card, body, content_type, _pipe, entry) do
    Map.merge(card, %{
      imgproxy_img: data_uri("image/png", File.read!(Path.join(@fixtures_dir, entry.fixture_filename))),
      pipe_img: data_uri(content_type, body),
      heat_banded: nil,
      heat_raw: nil
    })
  end

  defp attach_images(card, body, content_type, pipe, entry) do
    fixture = fixture_image(entry)
    a = to_rgb(fixture)
    b = to_rgb(pipe)
    threshold = (card.tol || @default_tol).threshold

    Map.merge(card, %{
      imgproxy_img: data_uri("image/png", File.read!(Path.join(@fixtures_dir, entry.fixture_filename))),
      pipe_img: data_uri(content_type, body),
      heat_banded: data_uri("image/png", png(banded_heatmap(a, b, threshold))),
      heat_raw: data_uri("image/png", png(raw_heatmap(a, b)))
    })
  end

  defp data_uri(content_type, bytes), do: "data:#{content_type};base64,#{Base.encode64(bytes)}"

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  # Align to a common 3-band RGB frame so the diff never raises on band-count
  # mismatch (RGB vs RGBA, e.g. alpha_resize / background_alpha). Visualizes RGB
  # deltas; the verdict metric (PixelCompare) still counts all bands incl. alpha.
  defp to_rgb(image) do
    case Image.bands(image) do
      3 -> image
      n when n > 3 -> ok!(Operation.extract_band(image, 0, n: 3))
      _ -> image
    end
  end

  # Banded: per-pixel max |Δ| across RGB → 256-entry LUT that dims pixels at/under
  # the case's own threshold and ramps over-threshold pixels hot.
  defp banded_heatmap(a, b, threshold) do
    delta = abs_diff(a, b)
    maxd = band_max(delta)
    idx = ok!(Operation.cast(maxd, :VIPS_FORMAT_UCHAR))
    ok!(Operation.maplut(idx, heat_lut(threshold)))
  end

  # Raw: |Δ| amplified for visibility, clamped to uchar (no threshold).
  defp raw_heatmap(a, b) do
    delta = abs_diff(a, b)
    amped = ok!(Operation.linear(delta, [@raw_amp * 1.0], [0.0]))
    ok!(Operation.cast(amped, :VIPS_FORMAT_UCHAR))
  end

  # subtract promotes uchar→signed short (no wrap); abs makes it non-negative.
  defp abs_diff(a, b), do: ok!(Operation.abs(ok!(Operation.subtract(a, b))))

  defp band_max(delta) do
    b0 = ok!(Operation.extract_band(delta, 0))
    b1 = ok!(Operation.extract_band(delta, 1))
    b2 = ok!(Operation.extract_band(delta, 2))
    ok!(Operation.maxpair(ok!(Operation.maxpair(b0, b1)), b2))
  end

  # 256×1 3-band uchar LUT: indices ≤ threshold → dim; above → cool→hot ramp.
  defp heat_lut(threshold) do
    bin =
      for i <- 0..255, into: <<>> do
        if i <= threshold do
          <<24, 24, 28>>
        else
          t = (i - threshold) / max(255 - threshold, 1)
          <<round(60 + t * 195), round(20 + t * 60), round(40 - t * 40)>>
        end
      end

    {:ok, lut} = Vix.Vips.Image.new_from_binary(bin, 256, 1, 3, :VIPS_FORMAT_UCHAR)
    lut
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("vips operation failed: #{inspect(reason)}")
```

`fixture_image/1` stays as defined in Task 3 (reused by `attach_images/5`).

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS — report contains `data:image/png;base64,` and renders `alpha_resize`/`background_alpha` without raising.

- [ ] **Step 5: Manually verify a heatmap is a valid PNG (sanity)**

Run:
```bash
MIX_ENV=test mise exec -- mix run -e '
  alias Mix.Tasks.Imgproxy.GenReport
  GenReport.run(["--out", "/tmp/r.html"])
' 2>&1 | tail -1
```
Expected: prints the "Wrote visual-diff report (… cards)" line with no crash. (The heatmap path ran for all transform/diverges cases including the band-mismatch ones.)

- [ ] **Step 6: Commit**

```bash
git add test/support/mix/tasks/imgproxy.gen_report.ex test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "feat(imgproxy): banded + raw diff heatmaps and base64 image inlining (#202)"
```

---

## Task 5: ReportHtml — full self-contained template

Replace the stub with a pure renderer: head (Geist fonts + slider CDN), provenance/skew header, counts summary, global heatmap toggle + filter controls, and per-card markup (badges, metric, side-by-side, slider, heatmap panel), all styled with the fiddle's CSS tokens.

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/report_html.ex`
- Modify: `test/support/mix/tasks/imgproxy.gen_report.ex`
- Test: `test/image_pipe/imgproxy_gen_report_test.exs`

- [ ] **Step 1: Write ReportHtml unit tests**

Append a new `describe` block to `test/image_pipe/imgproxy_gen_report_test.exs`:

```elixir
  describe "ReportHtml.render/1" do
    alias ImagePipe.Test.ImgproxyDifferential.ReportHtml

    defp sample_doc do
      %{
        provenance: %{
          imgproxy_digest: "sha256:abc",
          imgproxy_libvips: "42.20.2",
          pipe_libvips_at_gen: "8.18.2",
          runtime_libvips: "8.18.2",
          skew?: false
        },
        cards: [
          %{
            id: "rs_fill_zone",
            group: :transform,
            verdict: :equal,
            url: "/unsafe/rs:fill:240:180/f:png/plain/local:///high_freq.jpg",
            summary: "resize fill 240×180",
            status: :pass,
            attention?: false,
            hash_drift?: false,
            triage: nil,
            tol: nil,
            metric_text: "0 band-bytes over Δ2 (budget 64)",
            imgproxy_img: "data:image/png;base64,AAAA",
            pipe_img: "data:image/png;base64,BBBB",
            heat_banded: "data:image/png;base64,CCCC",
            heat_raw: "data:image/png;base64,DDDD",
            pipe_dims: {240, 180},
            fixture_dims: {240, 180}
          },
          %{
            id: "extend_offset_east_marker",
            group: :transform,
            verdict: :equal,
            url: "/unsafe/rs:fit:400:150/ex:1:ea:20:0/f:png/plain/local:///marker.png",
            summary: "resize fit 400×150; extend (east +20,+0)",
            status: :over_budget,
            attention?: true,
            hash_drift?: false,
            triage: %{reason: "extend east offset sign", issue: "#200"},
            tol: nil,
            metric_text: "9001 band-bytes over Δ2 (budget 64)",
            imgproxy_img: "data:image/png;base64,EEEE",
            pipe_img: "data:image/png;base64,FFFF",
            heat_banded: "data:image/png;base64,GGGG",
            heat_raw: "data:image/png;base64,HHHH",
            pipe_dims: {400, 150},
            fixture_dims: {400, 150}
          },
          %{
            id: "lossy_avif",
            group: :lossy,
            verdict: :equal,
            url: "/unsafe/rs:fill:240:180/f:avif/plain/local:///high_freq.jpg",
            summary: "resize fill 240×180; format avif",
            status: :contract_ok,
            attention?: false,
            hash_drift?: false,
            triage: nil,
            tol: nil,
            metric_text: "dims 240×180 (expected 240×180); type \"image/avif\"",
            imgproxy_img: nil,
            pipe_img: "data:image/avif;base64,IIII",
            heat_banded: nil,
            heat_raw: nil,
            pipe_dims: {240, 180},
            fixture_dims: nil
          }
        ]
      }
    end

    test "emits a self-contained document with fonts + slider CDN" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "<!doctype html>"
      assert html =~ "fonts.googleapis.com"
      assert html =~ "img-comparison-slider"
      assert html =~ "Geist"
    end

    test "renders a card anchor and metric per case" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(id="rs_fill_zone")
      assert html =~ "0 band-bytes over Δ2 (budget 64)"
      assert html =~ "resize fill 240×180"
    end

    test "triage issue is a clickable repo link" do
      html = ReportHtml.render(sample_doc())
      assert html =~ ~s(href="https://github.com/hlindset/image_pipe/issues/200")
      assert html =~ "extend east offset sign"
    end

    test "counts summary reflects groups and attention" do
      html = ReportHtml.render(sample_doc())
      # 2 transform, 0 diverges, 1 lossy; 1 attention (over_budget)
      assert html =~ "2 transform"
      assert html =~ "1 lossy"
      assert html =~ "1 attention"
    end

    test "lossy card omits imgproxy panel and heatmaps" do
      html = ReportHtml.render(sample_doc())
      # The lossy card has no second slider image / no heatmap data beyond its pipe img.
      refute html =~ "data:image/png;base64,IIII"
      assert html =~ "data:image/avif;base64,IIII"
    end

    test "global heatmap toggle + filter controls present" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "data-heat"
      assert html =~ "data-filter"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: FAIL — `ReportHtml` undefined.

- [ ] **Step 3: Implement ReportHtml**

Create `test/support/image_pipe/test/imgproxy_differential/report_html.ex`:

```elixir
defmodule ImagePipe.Test.ImgproxyDifferential.ReportHtml do
  @moduledoc """
  Pure renderer: card data + provenance → a single self-contained HTML string for
  the imgproxy differential visual-diff report. All images arrive pre-encoded as
  `data:` URIs; the only view-time network deps are the img-comparison-slider CDN
  and Google Fonts (both degrade: the side-by-side panels are the source of truth,
  fonts fall back to system stacks). Card-data shape is documented in the plan and
  produced by `Mix.Tasks.Imgproxy.GenReport`.
  """

  use Boundary, top_level?: true, deps: []

  @slider_css "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/styles.css"
  @slider_js "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/index.js"
  @fonts "https://fonts.googleapis.com/css2?family=Geist+Mono:wght@100..900&family=Geist:wght@100..900&display=swap"
  @issue_base "https://github.com/hlindset/image_pipe/issues/"

  @spec render(%{provenance: map(), cards: [map()]}) :: String.t()
  def render(%{provenance: prov, cards: cards}) do
    ordered = Enum.sort_by(cards, fn c -> {if(c.attention?, do: 0, else: 1)} end)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>imgproxy differential — visual diff</title>
    <link rel="stylesheet" href="#{@slider_css}">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="stylesheet" href="#{@fonts}">
    <script defer src="#{@slider_js}"></script>
    <style>#{css()}</style>
    </head>
    <body data-heat="banded" data-filter="all">
    #{header(prov, cards)}
    <main class="cards">
    #{Enum.map_join(ordered, "\n", &card/1)}
    </main>
    #{script()}
    </body>
    </html>
    """
  end

  defp header(prov, cards) do
    skew =
      if prov.skew? do
        ~s(<div class="banner skew">libvips skew: fixtures baked on #{esc(prov.imgproxy_libvips)}, running #{esc(prov.runtime_libvips)} — compare with care.</div>)
      else
        ""
      end

    """
    <header class="report-header">
      <h1>imgproxy differential — visual diff</h1>
      <p class="provenance">imgproxy <code>#{esc(prov.imgproxy_digest)}</code> · imgproxy libvips <code>#{esc(prov.imgproxy_libvips)}</code> · ImagePipe libvips at gen <code>#{esc(prov.pipe_libvips_at_gen)}</code> · runtime <code>#{esc(prov.runtime_libvips)}</code></p>
      #{skew}
      <p class="counts">#{counts(cards)}</p>
      <div class="controls">
        <span class="control-group" role="group" aria-label="heatmap mode">
          heatmap:
          <button data-heat-set="banded">banded</button>
          <button data-heat-set="raw">raw</button>
        </span>
        <span class="control-group" role="group" aria-label="filter">
          show:
          <button data-filter-set="all">all</button>
          <button data-filter-set="attention">attention</button>
          <button data-filter-set="transform">transform</button>
          <button data-filter-set="diverges">diverges</button>
          <button data-filter-set="lossy">lossy</button>
        </span>
      </div>
    </header>
    """
  end

  defp counts(cards) do
    by_group = Enum.frequencies_by(cards, & &1.group)
    attention = Enum.count(cards, & &1.attention?)
    drift = Enum.count(cards, & &1.hash_drift?)

    "#{Map.get(by_group, :transform, 0)} transform · " <>
      "#{Map.get(by_group, :diverges, 0)} diverges · " <>
      "#{Map.get(by_group, :lossy, 0)} lossy — " <>
      "#{attention} attention · #{drift} hash-drift"
  end

  defp card(c) do
    classes =
      ["card", "group-#{c.group}", "status-#{c.status}"] ++
        if(c.attention?, do: ["attention"], else: [])

    """
    <section id="#{esc(c.id)}" class="#{Enum.join(classes, " ")}" data-group="#{c.group}" data-attention="#{c.attention?}">
      <div class="card-head">
        <h2>#{esc(c.id)}</h2>
        #{badges(c)}
      </div>
      <p class="summary">#{esc(c.summary)}</p>
      <p class="url"><code>#{esc(c.url)}</code></p>
      #{triage(c)}
      #{drift_banner(c)}
      <p class="metric #{metric_class(c)}">#{esc(c.metric_text)}</p>
      #{visuals(c)}
    </section>
    """
  end

  defp badges(c) do
    base = [
      ~s(<span class="badge verdict">#{c.verdict}</span>),
      ~s(<span class="badge group">#{c.group}</span>)
    ]

    tol = if c.tol, do: [~s(<span class="badge tol">tol Δ#{c.tol.threshold}/#{c.tol.budget}</span>)], else: []
    triage = if c.triage, do: [~s(<span class="badge triage">quarantined</span>)], else: []

    Enum.join(base ++ tol ++ triage, " ")
  end

  defp triage(%{triage: nil}), do: ""

  defp triage(%{triage: %{reason: reason, issue: issue}}) do
    n = String.trim_leading(issue, "#")

    ~s(<p class="triage-note">⚠ quarantined: #{esc(reason)} — <a href="#{@issue_base}#{esc(n)}">#{esc(issue)}</a></p>)
  end

  defp drift_banner(%{hash_drift?: true}),
    do: ~s(<p class="banner drift">authored fields changed since generation — run <code>mix imgproxy.reauthor</code> or regenerate.</p>)

  defp drift_banner(_), do: ""

  defp metric_class(c) do
    if c.status in [:pass, :diverges_ok, :contract_ok], do: "ok", else: "bad"
  end

  # Lossy: pipe render alone + contract.
  defp visuals(%{group: :lossy} = c) do
    """
    <div class="lossy-only">
      <figure><img src="#{c.pipe_img}" alt="ImagePipe #{esc(c.id)}"><figcaption>ImagePipe (no imgproxy reference — contract only)</figcaption></figure>
    </div>
    """
  end

  # Dims mismatch: side-by-side only, no slider/heatmap.
  defp visuals(%{status: :dims_mismatch} = c) do
    side_by_side(c)
  end

  defp visuals(c) do
    """
    #{side_by_side(c)}
    <div class="slider">
      <img-comparison-slider>
        <img slot="first" src="#{c.imgproxy_img}" alt="imgproxy">
        <img slot="second" src="#{c.pipe_img}" alt="ImagePipe">
      </img-comparison-slider>
    </div>
    <div class="heatmaps">
      <figure class="heat-banded"><img src="#{c.heat_banded}" alt="banded diff"><figcaption>banded (Δ#{heat_threshold(c)})</figcaption></figure>
      <figure class="heat-raw"><img src="#{c.heat_raw}" alt="raw diff"><figcaption>raw ×8</figcaption></figure>
    </div>
    """
  end

  defp heat_threshold(%{tol: %{threshold: t}}), do: t
  defp heat_threshold(_), do: 2

  defp side_by_side(c) do
    """
    <div class="pair">
      <figure><img src="#{c.imgproxy_img}" alt="imgproxy"><figcaption>imgproxy #{fmt(c.fixture_dims)}</figcaption></figure>
      <figure><img src="#{c.pipe_img}" alt="ImagePipe"><figcaption>ImagePipe #{fmt(c.pipe_dims)}</figcaption></figure>
    </div>
    """
  end

  defp fmt(nil), do: ""
  defp fmt({w, h}), do: "#{w}×#{h}"

  defp esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp script do
    """
    <script>
    (function () {
      var body = document.body;
      function bind(attr, setAttr) {
        document.querySelectorAll("[" + setAttr + "]").forEach(function (btn) {
          btn.addEventListener("click", function () {
            body.setAttribute(attr, btn.getAttribute(setAttr));
          });
        });
      }
      bind("data-heat", "data-heat-set");
      bind("data-filter", "data-filter-set");
    })();
    </script>
    """
  end

  defp css do
    """
    :root, :root[data-theme="dark"] {
      color-scheme: dark;
      --surface-app:#0b0d10; --surface-bar:#0d1015; --surface-control:#202733;
      --border-subtle:#242b36; --text-primary:#f6f1e7; --text-muted:#8fa0b3;
      --accent:#ffb84d; --danger:#ff6b6b; --checker-square:#1b222b;
      --image-shadow:0 22px 80px rgb(0 0 0 / 38%);
    }
    @media (prefers-color-scheme: light) {
      :root {
        color-scheme: light;
        --surface-app:#f4f6f8; --surface-bar:#fff; --surface-control:#eef2f7;
        --border-subtle:#d9e0ea; --text-primary:#11151b; --text-muted:#687586;
        --accent:#d48100; --danger:#c62828; --checker-square:#dfe5ee;
        --image-shadow:0 22px 80px rgb(10 16 24 / 18%);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin:0; background:var(--surface-app); color:var(--text-primary);
      font-family:"Geist",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;
    }
    code, .url, .metric { font-family:"Geist Mono",ui-monospace,"SFMono-Regular","Menlo",monospace; }
    .report-header { position:sticky; top:0; z-index:2; padding:16px 24px;
      background:var(--surface-bar); border-bottom:1px solid var(--border-subtle); }
    .report-header h1 { margin:0 0 6px; font-size:18px; }
    .provenance, .counts { margin:4px 0; color:var(--text-muted); font-size:12px; }
    .counts { color:var(--text-primary); font-weight:600; }
    .banner { margin:8px 0; padding:8px 10px; border-radius:6px; font-size:12px; }
    .banner.skew { background:color-mix(in srgb, var(--accent) 18%, transparent); }
    .banner.drift { background:color-mix(in srgb, var(--danger) 18%, transparent); }
    .controls { display:flex; gap:18px; flex-wrap:wrap; margin-top:10px; }
    .control-group { font-size:12px; color:var(--text-muted); }
    .controls button { margin-left:4px; padding:3px 8px; border:1px solid var(--border-subtle);
      background:var(--surface-control); color:var(--text-primary); border-radius:5px; cursor:pointer; }
    .cards { padding:24px; display:flex; flex-direction:column; gap:24px; }
    .card { background:var(--surface-bar); border:1px solid var(--border-subtle);
      border-radius:10px; padding:16px; }
    .card.attention { border-color:var(--danger); }
    .card-head { display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
    .card-head h2 { margin:0; font-size:15px; }
    .badge { font-size:11px; padding:2px 7px; border-radius:999px;
      background:var(--surface-control); color:var(--text-muted); }
    .badge.triage { background:color-mix(in srgb, var(--danger) 25%, transparent); color:var(--text-primary); }
    .summary { margin:8px 0 2px; }
    .url { margin:0 0 8px; color:var(--text-muted); font-size:12px; word-break:break-all; }
    .triage-note { font-size:12px; color:var(--text-primary); margin:6px 0; }
    .metric { font-weight:600; }
    .metric.ok { color:var(--accent); }
    .metric.bad { color:var(--danger); }
    .pair, .heatmaps { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:12px; }
    .lossy-only { margin-top:12px; max-width:420px; }
    figure { margin:0; }
    figure img, .slider img, .slider img-comparison-slider {
      max-width:100%; display:block; border-radius:6px;
      background:repeating-conic-gradient(var(--checker-square) 0 25%, transparent 0 50%) 50% / 20px 20px;
    }
    figcaption { font-size:11px; color:var(--text-muted); margin-top:4px; }
    .slider { margin-top:12px; max-width:520px; box-shadow:var(--image-shadow); border-radius:6px; }
    /* global heatmap toggle */
    body[data-heat="banded"] .heat-raw { display:none; }
    body[data-heat="raw"] .heat-banded { display:none; }
    body[data-heat="banded"] .heatmaps, body[data-heat="raw"] .heatmaps { grid-template-columns:1fr; max-width:420px; }
    /* filters */
    body[data-filter="attention"] .card:not(.attention) { display:none; }
    body[data-filter="transform"] .card:not(.group-transform) { display:none; }
    body[data-filter="diverges"] .card:not(.group-diverges) { display:none; }
    body[data-filter="lossy"] .card:not(.group-lossy) { display:none; }
    """
  end
end
```

- [ ] **Step 4: Wire the task to ReportHtml; remove the stub**

In `imgproxy.gen_report.ex`:

1. Add to the alias: `ReportHtml` →
   `alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, OptsSummary, PixelCompare, ReportHtml, Skew}`
2. Replace `File.write!(out, stub_html(cards))` with:

```elixir
    doc = %{provenance: provenance(manifest), cards: cards}
    File.write!(out, ReportHtml.render(doc))
```

3. Delete `stub_html/1`.
4. Add `provenance/1`:

```elixir
  defp provenance(manifest) do
    runtime = Skew.runtime_libvips()

    %{
      imgproxy_digest: manifest.imgproxy_digest,
      imgproxy_libvips: manifest.imgproxy_libvips,
      pipe_libvips_at_gen: manifest.pipe_libvips_at_gen,
      runtime_libvips: runtime,
      skew?: not Skew.aligned?(manifest)
    }
  end
```

- [ ] **Step 5: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS — ReportHtml unit tests + the full-task smoke test (now asserting `id="..."` anchors against the real template) all green.

- [ ] **Step 6: Generate and eyeball the real report**

Run: `MIX_ENV=test mise exec -- mix imgproxy.gen_report`
Expected: writes `test/support/image_pipe/test/imgproxy_differential/report.html` and prints the path. Open it in a browser: verify side-by-side, slider drags, heatmap toggle flips banded/raw across all cards, filter buttons work, triage cards show their over-budget metric + clickable issue link, lossy cards show a single image + contract pill.

- [ ] **Step 7: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/report_html.ex test/support/mix/tasks/imgproxy.gen_report.ex test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "feat(imgproxy): self-contained visual-diff report HTML renderer (#202)"
```

---

## Task 6: Docs + full gate

**Files:**
- Modify: `test/support/image_pipe/test/imgproxy_differential/README.md`

- [ ] **Step 1: Document the task in the harness README**

Add this section to `README.md` after the "Regenerate (requires Docker)" section (before "libvips skew"):

```markdown
## Visual-diff report (no Docker)

Generate a self-contained `report.html` for eyeball triage — imgproxy vs ImagePipe
side by side, a comparison slider, two diff heatmaps (banded over the case threshold,
and raw amplified), and the live-recomputed metric/verdict/triage per constellation:

```shell
MIX_ENV=test mise exec -- mix imgproxy.gen_report          # writes report.html here
MIX_ENV=test mise exec -- mix imgproxy.gen_report --out /tmp/r.html
```

It renders ImagePipe live and reads the committed fixtures — no Docker, no fixture or
manifest changes. The default `report.html` is gitignored (it inlines ImagePipe PNGs as
base64; regenerate on demand). Cases needing attention (over-budget, quarantined,
dims-mismatch, a `:diverges` case that now matches, or authored-hash drift) sort to the
top, and a top-of-page counts line summarizes them. The slider and Geist fonts load from
a CDN; with no network the side-by-side panels remain the source of truth.
```

- [ ] **Step 2: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass. (No fiddle changes, so `precommit:demo` is not required.)

If `mix format` rewrites the new files, re-stage them. If credo flags anything, fix to satisfy `--strict`.

- [ ] **Step 3: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/README.md
git commit -m "docs(imgproxy): document gen_report visual-diff task (#202)"
```

---

## Notes for the implementer

- **`Vix.Vips.Operation.*` return `{:ok, _}`/`{:error, _}`** — always unwrap via `ok!/1`. The `Image.*` helpers (`open!`, `write!`, `width`, `height`, `bands`) are the bang-style `image`-library API and raise on their own.
- **No uchar wrap to worry about:** `subtract` auto-promotes uchar→signed short, and `cast(_, :VIPS_FORMAT_UCHAR)` clamps (it does not wrap). Verified against this repo's Vix during spec review.
- **Band-max is `extract_band` + `maxpair`-fold — not** `bandbool` (boolean only), `bandrank` (across a list of images), or `max` (global scalar). Those are the wrong primitives.
- **Display images come from original bytes** (`File.read!` the fixture PNG; the response `body` for the pipe render). Decode only to feed the metric/heatmap. Never re-encode the decoded image for display.
- **The smoke test runs the full task** (≈31 live renders + heatmaps). It runs on the default `mix test` lane like the conformance test. If it noticeably slows CI later, gate it behind a tag in `test_helper.exs` — but do not pre-optimize.
- **Heatmap pixel-correctness is verified visually** (the tool's purpose), not by deep pixel assertions; the smoke test only guards that the path produces valid inlined PNGs without crashing, including the band-mismatch cases.

---

## Self-review checklist (completed during planning)

- **Spec coverage:** task (T2/T5), no-Docker/always-compiled (T2), `--out`+gitignore (T2), full `plug_opts`/`RootHTTPAdapter` reuse (T2), per-group metric + dims-guard + triage-not-suppressed + hash-drift (T3), `:diverges`-below-floor + dims-mismatch attention triggers (T3), banded+raw heatmaps with RGB band-alignment (T4), original-bytes display (T4), counts summary + attention-first sort + filter + anchors (T5), clickable issue link (T5), global heatmap toggle (T5), offline degradation via independent side-by-side (T5), distinct lossy contract pill (T5), Geist fonts + slider CDN + fiddle palette/checkerboard (T5), README + no matrix change (T6). All mapped.
- **Placeholder scan:** none — every code step is complete.
- **Type consistency:** card-data keys are identical across T3 producer, T4 image-attachment, and T5 `ReportHtml` consumer + its sample fixtures; `status`/`group`/`verdict` atom sets match; `ok!/1`, `to_rgb/1`, `abs_diff/2`, `band_max/1`, `heat_lut/1` signatures are self-consistent.
```
