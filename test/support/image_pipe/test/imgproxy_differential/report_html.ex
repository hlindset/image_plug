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
    ordered = Enum.sort_by(cards, fn c -> if(c.attention?, do: 0, else: 1) end)

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
          <button data-heat-set="normalized">normalized</button>
        </span>
        <span class="control-group" role="group" aria-label="filter">
          show:
          <button data-filter-set="all">all</button>
          <button data-filter-set="failing">failing</button>
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
    failing = Enum.count(cards, & &1.failing?)
    drift = Enum.count(cards, & &1.hash_drift?)

    "#{Map.get(by_group, :transform, 0)} transform · " <>
      "#{Map.get(by_group, :diverges, 0)} diverges · " <>
      "#{Map.get(by_group, :lossy, 0)} lossy — " <>
      "#{attention} attention · #{failing} failing · #{drift} hash-drift"
  end

  defp card(c) do
    classes =
      ["card", "group-#{c.group}", "status-#{c.status}"] ++
        if(c.attention?, do: ["attention"], else: []) ++
        if(c.failing?, do: ["failing"], else: [])

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

    tol =
      if c.tol,
        do: [~s(<span class="badge tol">tol Δ#{c.tol.threshold}/#{c.tol.budget}</span>)],
        else: []

    triage = if c.triage, do: [~s(<span class="badge triage">quarantined</span>)], else: []

    Enum.join(base ++ tol ++ triage, " ")
  end

  defp triage(%{triage: nil}), do: ""

  defp triage(%{triage: %{reason: reason, issue: issue}}) do
    n = String.trim_leading(issue, "#")

    ~s(<p class="triage-note">⚠ quarantined: #{esc(reason)} — <a href="#{@issue_base}#{esc(n)}">#{esc(issue)}</a></p>)
  end

  defp drift_banner(%{hash_drift?: true}),
    do:
      ~s(<p class="banner drift">authored fields changed since generation — run <code>mix imgproxy.reauthor</code> or regenerate.</p>)

  defp drift_banner(_), do: ""

  defp metric_class(c) do
    if c.status in [:pass, :diverges_ok, :contract_ok], do: "ok", else: "bad"
  end

  defp visuals(%{group: :lossy} = c) do
    """
    <div class="lossy-only">
      <figure><img src="#{c.pipe_img}" alt="ImagePipe #{esc(c.id)}"><figcaption>ImagePipe (no imgproxy reference — contract only)</figcaption></figure>
    </div>
    """
  end

  defp visuals(%{status: :dims_mismatch} = c) do
    side_by_side(c)
  end

  defp visuals(c) do
    """
    #{side_by_side(c)}
    <div class="slider" style="width:#{elem(c.pipe_dims, 0)}px;max-width:100%">
      <img-comparison-slider>
        <img slot="first" src="#{c.imgproxy_img}" alt="imgproxy">
        <img slot="second" src="#{c.pipe_img}" alt="ImagePipe">
      </img-comparison-slider>
    </div>
    <div class="heatmaps">
      <figure class="heat-banded"><img src="#{c.heat_banded}" alt="banded diff"><figcaption>banded (Δ#{heat_threshold(c)})</figcaption></figure>
      <figure class="heat-raw"><img src="#{c.heat_raw}" alt="raw diff"><figcaption>raw ×8</figcaption></figure>
      <figure class="heat-normalized"><img src="#{c.heat_normalized}" alt="normalized diff"><figcaption>normalized (per-case)</figcaption></figure>
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
    :root {
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
    .pair { display:grid; grid-template-columns:1fr 1fr; gap:12px; margin-top:12px; }
    /* one heatmap shows at a time (global toggle), so the panel is single-column */
    .heatmaps { display:grid; grid-template-columns:1fr; gap:12px; margin-top:12px; max-width:420px; }
    .lossy-only { margin-top:12px; max-width:420px; }
    figure { margin:0; }
    figure img, .slider img, .slider img-comparison-slider {
      max-width:100%; display:block; border-radius:6px;
      background:repeating-conic-gradient(var(--checker-square) 0 25%, transparent 0 50%) 50% / 20px 20px;
    }
    figcaption { font-size:11px; color:var(--text-muted); margin-top:4px; }
    /* slider wrapper is capped to the render's own width (inline style) so the drag
       divider never extends past the images; it still shrinks on narrow screens */
    .slider { margin-top:12px; box-shadow:var(--image-shadow); border-radius:6px; }
    .slider img, .slider img-comparison-slider { width:100%; }
    body[data-heat="banded"] .heat-raw, body[data-heat="banded"] .heat-normalized { display:none; }
    body[data-heat="raw"] .heat-banded, body[data-heat="raw"] .heat-normalized { display:none; }
    body[data-heat="normalized"] .heat-banded, body[data-heat="normalized"] .heat-raw { display:none; }
    body[data-filter="failing"] .card:not(.failing) { display:none; }
    body[data-filter="attention"] .card:not(.attention) { display:none; }
    body[data-filter="transform"] .card:not(.group-transform) { display:none; }
    body[data-filter="diverges"] .card:not(.group-diverges) { display:none; }
    body[data-filter="lossy"] .card:not(.group-lossy) { display:none; }
    """
  end
end
