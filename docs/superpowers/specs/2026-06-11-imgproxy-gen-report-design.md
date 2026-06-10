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
  test compares: an in-task `SourceOrigin` plug serving `sources/`, `ImagePipe.Parser.Imgproxy`,
  `ImagePipe.Plug.call/2`, with `Image.open!(body, access: :random, fail_on: :error)`. (The
  conformance test defines `SourceOrigin` inline; the task carries its own equivalent — these
  are two test-support consumers of the same public render contract, not shared internals.)

## Per-constellation computation (live, mirrors the test)

For each constellation the task loads its manifest entry, renders ImagePipe, and recomputes
the **same** metric the conformance test uses, so the report doubles as an eyeball-able
re-run of the suite:

- **transform group:** `PixelCompare.outliers/3` at the case's `tol.threshold` (default Δ2)
  vs `tol.budget` → band-byte count + within-budget / over-budget status.
- **`:diverges`:** `PixelCompare.fraction_over/3` vs the divergence floor → fraction +
  above-floor status.
- **lossy group:** ImagePipe's output dims + content-type vs the manifest's recorded
  contract → match / mismatch.

Manifest authored-hash drift (`Manifest.authored_sha256/1` vs the stored
`authored_sha256`) is surfaced as a per-card warning banner — the same staleness the test
asserts on — rather than aborting the whole report.

### Ordering & filtering

Cases that need attention (over-budget, `:triage`-quarantined, contract mismatch, or
authored-hash drift) sort to the top; the rest follow in authored order. A small in-page
filter (all / attention-only / by group) is included as client-side JS.

## The two heatmaps (transform + `:diverges` only)

Generated server-side per case via libvips (Vix, already in the dep tree), encoded to PNG,
base64-inlined:

- **Banded:** per-band `abs(imgproxy − pipe)` → per-pixel max delta → pixels at/under the
  case's own threshold dimmed/transparent, pixels over mapped to a hot ramp. Ties the
  picture to the verdict math (where the budget is being spent).
- **Raw amplified:** `abs(diff)` multiplied for visibility, no thresholding — shows full
  structure including sub-threshold AA skew. This is the "edge shifted vs same-x libvips AA"
  question the constellation notes (`min_dims_dpr_marker`, `fill_down_marker`, …) keep making.

A **global toggle** in the report header flips every card's heatmap panel between Banded and
Raw at once (both PNGs are inlined; the toggle is pure client-side CSS/JS — no regeneration).

Heatmaps are skipped for lossy cards (no imgproxy fixture to diff against) and when the
ImagePipe/imgproxy dims differ (a dimension mismatch is itself the finding; the card shows
the mismatch instead of a heatmap).

## Card anatomy

**Transform / `:diverges` card:**

- **Header label:** `Constellations.imgproxy_path/1` URL **plus** a human-readable opts
  summary. The summary is produced by a small, self-contained code→prose table living in the
  task, covering the codes actually used in `constellations.ex`
  (`rs`/`c`/`t`/`g`/`mw`/`mh`/`z`/`pd`/`ex`/`exar`/`dpr`/`bg`/`bl`/`sh`/`sm`/`scp`/`q`/`f`/`el`
  + gravity codes), with unknown segments echoed verbatim as a fallback. Deliberately a tiny
  dedicated formatter, not a reach into parser internals — keeps the boundary clean and the
  report decoupled from plan/parser shape.
- **Badges:** verdict (`:equal`/`:diverges`), group, and `tol` / `:triage` (reason + tracking
  issue) when present.
- **Metric line:** measured Δ-over-threshold band-byte count vs budget (or fraction vs floor),
  with within/over status styled by `--accent`/`--danger`.
- **Visuals:** imgproxy vs ImagePipe **side by side**; an **img-comparison-slider** overlay
  of the two renders; the **heatmap panel** (Banded/Raw, driven by the global toggle).

**Lossy card (reduced):** ImagePipe's live render alone (no slider/heatmap, no imgproxy
fixture exists), plus expected-vs-actual dims & content-type from the manifest.

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

- **Heatmap construction in libvips** is the least-trivial piece (per-band abs-diff → per-pixel
  max → threshold/ramp colorization). The plan should prototype this against one real
  constellation early and keep it isolated behind a small private function so it can be
  verified independently.
- **Self-contained size:** ~28 transform cases × (imgproxy + pipe + 2 heatmaps) base64-inlined
  yields a multi-MB HTML file. Acceptable for a regenerate-on-demand DX artifact; noted so it
  isn't mistaken for a problem.
