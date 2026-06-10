# imgproxy differential — visual-diff HTML report

**Issue:** [#202](https://github.com/hlindset/image_pipe/issues/202)
**Date:** 2026-06-11
**Status:** Design approved, pending implementation plan

## Problem

The imgproxy differential conformance suite (`test/image_pipe/imgproxy_differential_conformance_test.exs`)
compares ImagePipe's live render against committed imgproxy fixtures, but only
**imgproxy's** output is persisted (the fixture PNG). ImagePipe's render is generated in
the test, compared in memory, and discarded; `REPORT.md` is just a name list. A human
can't visually inspect a divergence — or sanity-check a passing/tolerance/quarantined case
— without running code and decoding bytes by hand. That makes triage, tolerance decisions,
and quarantine review (e.g. #199, #200) slow and non-visual.

## Goal

A Mix task that renders ImagePipe's output for every constellation and writes a
**single self-contained `report.html`** putting imgproxy vs ImagePipe side by side, with a
comparison slider and per-pixel diff heatmaps, plus the verdict/tolerance/triage metadata
and the live-recomputed conformance metric per case.

## Non-goals / constraints

- **DX / inspection only.** Must not change conformance behavior, fixtures, the manifest,
  `REPORT.md`, or the default `mix test` lane. It only *reads* committed fixtures + the
  manifest and renders ImagePipe live.
- **No Docker.** imgproxy fixtures are already committed; ImagePipe renders are live. The
  task is therefore **not** gated behind `IMGPROXY_DIFF`/Testcontainers (unlike
  `gen_fixtures`) and is always compiled in `MIX_ENV=test`.
- **No JS build.** The differential suite is pure Elixir/test-support; the `fiddle/` Svelte
  app stays separate. The report is a single HTML file: images base64-inlined, the slider
  loaded from a CDN, fonts from Google Fonts. No ImagePipe PNGs are committed; nothing
  couples to the fiddle build.

## The task

`Mix.Tasks.Imgproxy.GenReport` at `test/support/mix/tasks/imgproxy.gen_report.ex`.

```
MIX_ENV=test mise exec -- mix imgproxy.gen_report [--out PATH]
```

- Default `--out`: `test/support/image_pipe/test/imgproxy_differential/report.html` (beside
  `README.md`/`REPORT.md`). `report.html` is added to `.gitignore`. `--out PATH` overrides
  (e.g. CI artifact upload or a scratch location).
- Prints the absolute output path on completion.
- Reuses the conformance test's render path exactly so it renders the **same** bytes the
  test compares. That means replicating the test's full `plug_opts/0`, not just the plug: the
  source is wired as `sources: [path: {RootHTTPAdapter, root_url: "http://origin.test",
  req_options: [plug: SourceOrigin]}]` (`conformance_test.exs:160-166`) — `SourceOrigin` is a
  `req_options[:plug]` on `RootHTTPAdapter`, **not** a bare plug. The task carries its own
  `SourceOrigin` + the same adapter wiring, then `ImagePipe.Plug.call/2` and
  `Image.open!(body, access: :random, fail_on: :error)`. (The conformance test defines
  `SourceOrigin` inline; the task carries its own equivalent — two test-support consumers of
  the same public render contract, not shared internals.)
- `use Boundary, top_level?: true, check: [out: false]` — the same shape as `gen_fixtures`/
  `gen_sources`. `check: [out: false]` exempts the task from outgoing-dependency checks, so
  naming `ImagePipe.Plug` / `ImagePipe.Parser.Imgproxy` / `RootHTTPAdapter` / `Vix` is clean.

## Per-constellation computation (live, mirrors the test)

For each constellation the task loads its manifest entry, renders ImagePipe, and recomputes
the **same** metric the conformance test uses, so the report doubles as an eyeball-able
re-run of the suite:

- **transform group:** `PixelCompare.outliers/3` at the case's `tol.threshold` (default Δ2)
  vs `tol.budget` → band-byte count + within-budget / over-budget status.
- **`:diverges`:** `PixelCompare.fraction_over/3` vs the divergence floor → fraction +
  above-floor status. A `:diverges` case whose live fraction has fallen **below** its floor
  (ImagePipe now matches imgproxy where divergence was pinned) is an attention finding — it
  means the manifest needs flipping to `:equal` — and is styled/sorted as such, not as a pass.
- **lossy group:** ImagePipe's output dims + content-type vs the manifest's recorded
  contract → match / mismatch.

**Dims-mismatch guard.** `PixelCompare.outliers/3` and `fraction_over/3` **raise** on a
dimension mismatch (`pixel_compare.ex:24-26`). The report runs live and independently of the
test, so a pipe-vs-imgproxy dimension mismatch is reachable even though the test's
`assert_same_dims!` would hard-fail. The task must detect a dims mismatch up front and render
a mismatch card (the mismatch is the finding) instead of calling the metric functions — one
bad case must not crash the whole report.

**Triage cards are not suppressed.** The two quarantined cases (`extend_offset_east_marker`,
`extend_ar_dpr_marker`) are `group: :transform, verdict: :equal, tol: nil`, so they fall to
the default Δ2/budget-64 metric and render as over-budget — which is exactly the divergence a
human is adjudicating. The `:triage` badge (reason + clickable issue link) **annotates** the
card; it never replaces the live metric line or the heatmaps. Surfacing that measured
divergence is the whole point of the quarantine-review workflow (#199/#200).

Manifest authored-hash drift (`Manifest.authored_sha256/1` vs the stored
`authored_sha256`) is surfaced as a per-card warning banner — the same staleness the test
asserts on — rather than aborting the whole report. (The task trusts the manifest term:
`Manifest.load!/1` already validates shape at the serialization boundary, so the task does
not re-validate.)

### Ordering & filtering

A **counts/summary line** at the top is the triage dashboard: total per group (transform /
diverges / lossy) and the attention breakdown (over-budget · quarantined · diverges-below-floor ·
dims-mismatch · contract-mismatch · hash-drift). It's derived from the same per-card statuses
that drive the sort, so a regenerate's new attention items are visible in one glance before
scrolling.

Cases that need attention — over-budget, `:triage`-quarantined, **dims mismatch**,
**`:diverges` below floor**, contract mismatch, or authored-hash drift — sort to the top; the
rest follow in authored order. A small in-page filter (all / attention-only / by group) is
client-side JS that toggles `display` (no DOM rebuild — keep first-paint and filtering snappy
on a multi-MB page). Each card gets a stable `id` anchor (the constellation id) so a specific
card can be linked into an issue comment.

## The two heatmaps (transform + `:diverges`)

Generated server-side per case via libvips (Vix, already in the dep tree), encoded to PNG,
base64-inlined. Both heatmaps are generated for **every** transform and `:diverges` case —
including the `:diverges` `scp0_colorspace_124` case, whose diffuse P3 divergence is the most
heatmap-worthy of all (the raw-amplified map is the ideal way to show "diffuse 2.6%, not
localized"); the `:diverges` branch must not skip heatmap generation.

**Band alignment first (MUST).** `Vix.Vips.Operation.subtract/2` raises on a band-count
mismatch, and two cases can legitimately differ in band layout — `alpha_resize` (RGBA) and
`background_alpha` (`bg:` → RGB) — which is itself a divergence worth seeing. Before diffing,
align both images to a common 3-band RGB frame with `Operation.extract_band(img, 0, n: 3)`
(not `Image.flatten!`, which keeps alpha on a bare RGBA buffer). Consequence: the banded
heatmap visualizes **RGB-channel** deltas, while the printed verdict metric (`PixelCompare`)
counts **all** bands including alpha — so the card must say the heatmap shows RGB deltas and
must not claim the picture *is* the verdict math byte-for-byte.

- **Banded:** `abs(subtract(imgproxy, pipe))` (subtract auto-promotes uchar→signed short, so
  no wrap) → per-pixel max across the 3 bands via `extract_band` + a `maxpair`-fold (**not**
  `bandbool`/`bandrank`/`max` — those are boolean / band-wise-across-images / global-scalar,
  the wrong primitives) → `relational_const(:VIPS_OPERATION_RELATIONAL_MORE, [threshold])`
  mask → `ifthenelse(mask, hot, dim)` (hot via a 256×3 `maplut` ramp on the delta for a
  graded heat, dim elsewhere). Honors the case's own Δ threshold, so it shows where the
  budget is spent.
- **Raw amplified:** `linear(abs, [mult], [0.0])` then `cast(:VIPS_FORMAT_UCHAR)` (cast
  clamps, no wrap) — no thresholding, shows full structure including sub-threshold AA skew.
  This is the "edge shifted vs same-x libvips AA" question the constellation notes
  (`min_dims_dpr_marker`, `fill_down_marker`, …) keep making.

A **global toggle** in the report header flips every card's heatmap panel between Banded and
Raw at once (both PNGs are inlined; the toggle is pure client-side CSS/JS — no regeneration).
Global is the right default and sole control for v1: every stated workflow is a *scanning*
workflow, and a global flip keeps the whole page speaking one mental model. No per-card toggle.

Heatmaps are skipped only for lossy cards (no imgproxy fixture to diff against) and when the
ImagePipe/imgproxy dims differ (a dimension mismatch is itself the finding; the card shows the
mismatch instead of a heatmap — see the dims-mismatch guard above).

## Card anatomy

**Transform / `:diverges` card:**

- **Header label:** `Constellations.imgproxy_path/1` URL **plus** a human-readable opts
  summary. The summary is produced by a small, self-contained code→prose table living in the
  task, covering the codes actually used in `constellations.ex`
  (`rs`/`c`/`t`/`g`/`mw`/`mh`/`z`/`pd`/`ex`/`exar`/`dpr`/`bg`/`bl`/`sh`/`sm`/`scp`/`q`/`f`/`el`
  + gravity codes), with unknown segments echoed verbatim as a fallback. Deliberately a tiny
  dedicated formatter, not a reach into parser internals — keeps the boundary clean and the
  report decoupled from plan/parser shape.
- **Badges:** verdict (`:equal`/`:diverges`), group, and `tol` / `:triage` when present. The
  `:triage` badge shows the reason **and a clickable issue link** — the bare `#200` string is
  rendered as `<a href="https://github.com/hlindset/image_pipe/issues/200">#200</a>` (strip
  the leading `#` for the URL). The issue is the literal next click in the triage loop, so it
  must be a link, not text.
- **Metric line:** measured Δ-over-threshold band-byte count vs budget (or fraction vs floor),
  with within/over status styled by `--accent`/`--danger`. Always present on transform and
  `:diverges` cards, **including quarantined ones** — the triage badge annotates this line, it
  doesn't replace it.
- **Visuals:** imgproxy vs ImagePipe **side by side** (the source of truth, independent of any
  CDN); an **img-comparison-slider** overlay of the two renders; the **heatmap panel**
  (Banded/Raw, driven by the global toggle).
- **Images displayed from original bytes** (no re-encode): the imgproxy fixture is inlined
  straight from its on-disk PNG bytes (`File.read!`), and the pipe transform render is inlined
  from the response body (already PNG, `f:png` forced). The decoded `Vix` images are used only
  to compute the metric + heatmaps; re-encoding the decoded image for display would add CPU
  and risk re-compression drift, and would make the slider compare not-quite-the-committed
  bytes.

**Lossy card (reduced):** ImagePipe's live render alone, inlined from the response body with
its real content-type (no slider/heatmap, no imgproxy fixture exists), plus expected-vs-actual
dims & content-type from the manifest. Its pass affordance is a **distinct contract pill**
(e.g. "contract: dims+type ✓"), visibly different from the pixel cards' "within budget" pill,
so a contract match is never visually conflated with a pixel pass.

## Header / provenance

Top of the report shows manifest provenance (imgproxy digest, imgproxy libvips, ImagePipe
libvips at generation, runtime libvips) and the **skew banner** when runtime libvips differs
from the fixture-baked version — the same warn-and-attempt context the test prints, so a hot
heatmap under skew is read correctly rather than mistaken for a regression. The global
heatmap toggle and the case filter live here.

## Styling

A single inlined `<style>` block, borrowing the fiddle's design language so the report feels
native:

- **Palette via CSS custom properties**, dark-first with a light variant under
  `prefers-color-scheme`, reusing the fiddle's tokens: `--surface-app`/`--surface-bar`/
  `--surface-control`, `--border-subtle`, `--text-primary`/`--text-muted`, `--accent` (amber
  `#ffb84d` dark / `#d48100` light), `--danger` (red) for over-budget/quarantine/mismatch.
- **Checkerboard image backgrounds** via the same
  `repeating-conic-gradient(var(--checker-square) …)` so alpha sources read correctly behind
  the renders.
- **Fonts:** Geist Sans + Geist Mono from **Google Fonts** (`<link>` in the head), matching
  the fiddle exactly; the fiddle's declared system stacks remain the `font-family` fallback
  if the font CDN is unreachable. `--font-mono` for opts/URL labels and metric numbers,
  `--font-sans` for chrome.
- Card chrome (`--surface-bar` panels, `--border-subtle`, subtle `--image-shadow`) mirrors
  the fiddle's tool-section look.

The only view-time network dependencies are the img-comparison-slider CDN `<script>` and the
Google Fonts `<link>`; everything else (all images, all CSS) is inlined.

**Offline / CDN-unreachable degradation.** The report stays usable with both CDNs down: the
side-by-side imgproxy/pipe panels are rendered independently of the slider and remain the
source of truth, and the font `<link>` falls back to the fiddle's system stacks. The slider is
an *enhancement*, not the only comparison — the plan should verify that an undefined
`<img-comparison-slider>` custom element degrades cleanly (doesn't render as a broken overlap)
rather than relying on slot fallback luck.

## Docs

Add a short "Visual-diff report" section to the harness `README.md` documenting the on-demand
task (command, `--out`, that it needs no Docker, and that `report.html` is gitignored).

No conformance-matrix (`docs/imgproxy_support_matrix.md`) change: the report is DX-only and
observably touches no compatibility behavior. Per the project review-cycle rule, the
implementation plan's parallel review will use non-compatibility lenses
(correctness/boundaries, Elixir/Vix idiom, DX/output quality); the compatibility reviewer is
optional here.

## Module/file touch list

- **New:** `test/support/mix/tasks/imgproxy.gen_report.ex` (the task: render, compute, build
  HTML, opts-summary formatter, heatmap generation).
- **Edit:** `.gitignore` (add the default `report.html` path).
- **Edit:** `test/support/image_pipe/test/imgproxy_differential/README.md` (document the task).
- **Unchanged:** `constellations.ex`, `pixel_compare.ex`, `manifest.ex`, fixtures, the
  manifest, `REPORT.md`, the conformance test, the `mix test` lane.

## Open risks

- **Heatmap construction in libvips** is the least-trivial piece, but the operation chain is
  now known (see the heatmaps section): `subtract`/`abs` (auto-promotes, no wrap) →
  `extract_band` + `maxpair`-fold for per-pixel band-max (**not** `bandbool`/`bandrank`/`max`)
  → `relational_const(:MORE)` → `ifthenelse`/`maplut`; raw = `linear` → `cast` (clamps). Keep
  it behind a small private function and prototype it against one real constellation
  (`rs_fill_zone`) plus one band-mismatch case (`alpha_resize`) early so it's verified
  independently.
- **Self-contained size:** ~28 transform cases × (imgproxy + pipe + 2 heatmaps) base64-inlined
  yields a multi-MB HTML file. Acceptable for a regenerate-on-demand DX artifact; noted so it
  isn't mistaken for a problem. Keep the in-page filter on `display` toggling (not DOM
  rebuild) so the large page stays responsive.
