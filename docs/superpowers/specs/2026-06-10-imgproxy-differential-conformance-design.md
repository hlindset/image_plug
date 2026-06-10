# imgproxy differential pixel conformance — design

**Status:** approved (brainstorm + parallel review applied), pending implementation plan
**Date:** 2026-06-10
**Compatibility target:** imgproxy (`docs/imgproxy_support_matrix.md`)

## Goal

Add pixel-level differential conformance testing against a real imgproxy. A
manually-run generator produces reference fixtures from a pinned `darthsim/imgproxy`
container; we commit them; a fast default-lane test compares ImagePipe's decoded
pixel output against the committed fixtures. This turns the support matrix's ✅/⚠️
verdicts into live, enforced tests.

Why it is viable here: imgproxy and ImagePipe both sit on libvips (imgproxy directly,
ImagePipe via Vix). For the stages the matrix marks ✅, the same resize kernels /
convolutions / `find_trim` mean near-exact pixel agreement is realistic — *provided
both sides invoke the same operation with the same parameters on the same libvips
version*. The skew gate and the dimension-equality precondition (below) exist to make
that proviso explicit rather than assumed.

This **complements** the existing self-derived
`test/image_pipe/imgproxy_wire_conformance_test.exs` (which asserts ImagePipe's own
contracts via oracle patterns, no real imgproxy). The differential lane adds the
missing third-party ground truth.

## Non-goals

- Not on the precommit/CI hot path for generation — CI only ever *reads* committed
  fixtures. No Docker in the hot path.
- Not testing imgproxy Pro features (smart/object gravity, advanced filters).
- Not testing ImagePipe's S3 source adapter — separate feature/lane (a future MinIO
  service can join the testcontainers setup without coupling).
- Not changing any parser / encode / stage behavior. Test harness only; no ✅/⚠️
  verdict *content* changes.

## Architecture — two decoupled artifacts

### Generator (manually run, off precommit)

`mix imgproxy.gen_fixtures`:

- Brings up a pinned `darthsim/imgproxy@sha256:<digest>` (non-pro config) via the
  **testcontainers-elixir** library, with a `LOCAL_FILESYSTEM_ROOT` bind of the
  committed sources dir so imgproxy fetches sources via `local://`. Container config
  must **not** set `IMGPROXY_USE_LINEAR_COLORSPACE` (default off; resize runs in
  working/sRGB space on both sides — confirmed `processing/scale.go:18-37`,
  `config.go`).
- Before generating, asserts the bound source files match the source hashes recorded
  in the manifest, so a stale/locally-regenerated source cannot bake a fixture that
  disagrees with what the comparison test will load.
- Walks the declarative constellation list, issues each request, **decodes
  imgproxy's output and re-saves it as lossless PNG** (compare in decoded-pixel
  space, never encoded bytes). Encoder effort/threads pinned for reproducibility.
- Writes: per-constellation fixture PNGs, the generated manifest, and `REPORT.md`.

**Dependency gating (blocker — must be exact).** The testcontainers dep is gated by an
env var at `deps/0` time, following the `:image_vision` pattern in `mix.exs:140-150`:
e.g. `System.get_env("IMGPROXY_DIFF") in ["1","true"]` adds
`{:testcontainers, "~> …", only: :test, runtime: false}`. **But that precedent is a
*dependency* gate, not a *task* gate** — a Mix task lives under `lib/mix/tasks/` and
therefore compiles in *every* env, including the plain `dev` compile precommit runs
(`mise.toml` → `mix compile --warnings-as-errors`). A top-level reference to
`Testcontainers.*` from that always-compiled module breaks precommit when the dep is
absent.

→ The task module **must compile-gate its body** so no compile-time reference to the
conditional dep exists when it's absent — mirroring the OTel optional-dep pattern
(`mix.exs:110-114`): wrap the testcontainers-touching code in
`if Code.ensure_loaded?(Testcontainers) do … end` / dispatch via `apply/3`. The task
runs under `MIX_ENV=test` with `IMGPROXY_DIFF=1` so the dep is present at run time.

**Acceptance criterion:** bare `mix compile --warnings-as-errors` (no special env)
compiles both Mix task modules cleanly, with the testcontainers dep absent.

### Source builder (separate one-shot)

`mix imgproxy.gen_sources`: builds the committed source images deliberately. Sources
are synthesized **once and committed as fixed inputs**; normal fixture regeneration
reuses them. Prevents a dev's libvips bump from silently changing inputs at generation
time. (Some sources are JPEG/WebP — see below; "fixed input" is the guarantee, not
"lossless".)

### Comparison test (default precommit/CI lane)

Runs in the normal `mix test` gate — fast, reads committed PNGs, re-runs ImagePipe
transforms through `ImagePipe.Plug.call/2`, decodes both sides, compares. No Docker,
no opt-in tag. Skew handling below.

## Source-of-truth split (joined by `id`)

### Canonical authored list — code module

`ImagePipe.Test.ImgproxyDifferential.Constellations` at
`test/support/image_pipe/test/imgproxy_differential/constellations.ex`
(`use Boundary, top_level?: true, deps: []` — pure data, no `lib/` deps), imported by
**both** the generator and the test:

```elixir
%{
  id: "rs_fill_zone_q4",
  source: :high_freq,          # see source table
  opts: "rs:fill:240:180/...", # imgproxy processing option string
  verdict: :equal,             # :equal | :diverges
  group: :transform | :lossy,
  tol: nil,                    # optional per-constellation tolerance override
  divergence: nil              # for :diverges rows: {metric, region, floor, "#124"}
}
```

### Generated manifest — machine-only, committed

Provenance, written by the generator; **shape validated on load** (fail loudly on a
malformed entry, not a raw match error):

- `imgproxy_digest`, `imgproxy_libvips` (the version that baked the pixels; skew-gate
  reference), `pipe_libvips_at_gen` (provenance; generator warns if it differs from
  `imgproxy_libvips`).
- per source: `sha256` of the committed source file.
- per `id`: `{fixture_filename, fixture_sha256, authored_sha256}` where
  `authored_sha256` is a hash of the canonicalized authored fields
  (`{source, opts, verdict, group, tol, divergence}`).

Drift rules — three guards, closing the middle case sha256-on-bytes alone leaves open:
- Listed constellation with **no committed fixture** → test **fails** (forces regen).
- Committed PNG must match its manifest `fixture_sha256` (corruption/edit guard).
- The current `constellations.ex` entry's authored hash must match the manifest's
  `authored_sha256` (catches an edited `opts`/`source`/`verdict` without
  regeneration — otherwise ImagePipe would run new opts against a fixture baked from
  old opts, a silent false pass under tolerance).
- A **verdict flip** (`:diverges` → `:equal`) changes the authored hash, so it *does*
  require touching the manifest — but the fixture bytes are unchanged, so no container
  run is needed; the generator has a `--reauthor` path that refreshes authored hashes
  without re-running imgproxy.

### `REPORT.md` — committed, human-readable

Written on each generation: old→new `imgproxy_digest` + libvips, and per-constellation
max-delta-vs-previous-fixture, verdict, pass/fail against the running ImagePipe. The PR
diff of **this file** is the reviewable record of a digest bump — not the binary PNGs.

## Sources — synthesized once, committed, fixed

The large source is the only big file, amortized across all constellations (outputs
are small). Shrink-on-load (`scaleOnLoad`, stage 3) **only fires for JPEG/WebP** in
imgproxy (`processing/scale_on_load.go:25-27`; PNG load has no shrink param) — so the
shrink-boundary sweep is driven by JPEG/WebP sources, **not PNG**.

| key | format | shape | purpose |
|-----|--------|-------|---------|
| `high_freq` | **JPEG** | zone-plate / radial chirp / fine checkerboard | drives downscale-by-default + the 1/8·1/4·1/2 + residual shrink-factor sweep (stage 3); high frequency makes resampling divergence visible. JPEG so shrink-on-load actually fires; ImagePipe `jpeg_shrink_n` is a port of `calcJpegShink`, so {1,2,4,8} boundaries agree exactly. |
| `high_freq_webp` | **WebP** | same pattern | the continuous-scale residual path (`vips_webpload` `scale:1.0/shrink`), where imgproxy's `imath.Scale` denominator rounding vs ImagePipe's float target is the most likely ±1px divergence — exercised explicitly. |
| `marker` | PNG | off-center solid block at known coords | unambiguous crop / gravity anchoring (centering already matched via `center_bias` ↔ `ShrinkToEven`). |
| `border` | PNG, sRGB | uniform frame | trim — `:equal` (exact `find_trim` + `equal_hor`/`equal_ver` box math). |
| `alpha` | PNG, RGBA | transparency | alpha flatten/resize (verify ImagePipe premultiplies around resize/blur like imgproxy, `vips/vips.c:421-425,745-755`). |
| `exif_jpeg` | JPEG | real EXIF orientation tag | orientation (PNG carries no EXIF orientation). |
| `icc_p3` | PNG + Display-P3 ICC (committed `.icc`); **sharp saturated P3-only edges + a uniform border region** | carries the #124 colorspace divergence (with `scp:0` + a tone effect) *and* the trim-detection-space divergence (imgproxy converts to sRGB pre-trim regardless of `scp`; ImagePipe detects in source space). Sharp edges so the divergence is robustly measurable, not a smooth gradient that falls below the floor. |
| `small` | PNG | small source | enlarge / extend-aspect-ratio (no shrink-on-load on the enlarge path). |

No real-photo datasets (licensing); synthetic covers everything that matters.

## Comparison semantics

### Dimension-equality precondition (all groups)

Before any pixel/contract comparison, assert ImagePipe's output dimensions equal the
committed fixture's, as a **distinct, loud failure** ("dims differ: …"). A ±1px
scale-factor route difference (imgproxy's `WScale` exactness-snap vs ImagePipe's
integer-target-then-divide) must surface as this, not as corrupted pixel deltas.

### Skew gate — default lane + CI guard

The `:equal` and lossy-contract assertions are meaningful only when ImagePipe runs the
libvips that baked the fixtures:

- Assert only when runtime `Vix.Vips.version()` **exactly** equals manifest
  `imgproxy_libvips` (kernels can change on a patch bump, so exact-match; regeneration
  is required on any bump, on CI's libvips). Otherwise `ExUnit`-**skip** with a clear
  reason.
- **CI skew-guard:** a meta-test detects CI (env) and **fails** if skew would skip the
  suite — so CI can never be green-by-skip and must run on the fixtures' libvips.
  Locally, mismatched libvips skips loudly; matched libvips runs the real assertions.

### `:equal` — transform group (PNG output only)

Decode ImagePipe's PNG response and the committed PNG; compare with a **count-based
outlier budget**, modeled on the existing wire test's trusted primitive
(`pixel_diverges?` far-count tied to edge length) rather than a hard per-pixel max:

- Count pixels whose max per-channel absolute delta exceeds a small threshold `T`;
  require that count ≤ budget `B`.
- `T` and `B` tuned empirically against real fixtures, per-constellation overridable.
- Rationale: with same libvips + identical scale factor (the dimension precondition
  guarantees the factor matched) + default kernel (Lanczos3, no `centre` —
  `vips/vips.c:413`), resize is deterministic and near-exact even on high-frequency
  content; `B` absorbs the handful of sub-pixel seam pixels. If a tight `B` proves
  *infeasible* on the high-frequency source despite matching dimensions, that is a
  real scale-factor/kernel mismatch to investigate — not something to paper over by
  loosening tolerance. (Honesty note, per repo guidelines: this is correctness-
  verified, not a perf claim.)

### `:diverges` — structured metric, NOT skew-gated

Assert a **structured** divergence appropriate to the mechanism, over the affected
region/channel — never "delta exceeds floor *somewhere*" (one ringing pixel makes that
tautological). E.g. for #124, a *mean* per-channel delta over a flat P3 patch exceeds
the floor; a colorspace difference is a systematic regional bias, not a stray pixel.
Each `:diverges` row carries `divergence: {metric, region, floor, issue}`.

These assertions run **regardless of skew**: the divergences they pin (#124 colorspace
order, trim-detection space) are *algorithmic* and version-independent. If ImagePipe
accidentally converges (e.g. a partial #124 fix), the metric drops below the floor and
the test fails — forcing a verdict flip to `:equal` + a matrix update in the same
change. True bidirectional matrix enforcement.

### Lossy group — contract-only, no pixel claim

`f:webp/avif/jpeg` and `q:` exercise encoders configured independently on each side, so
decoded-pixel agreement (even loose) mostly measures unrelated quantization noise.
These constellations assert **dimensions + content-type + clean-decode (+ ballpark
byte-size sanity)** — no decoded-pixel comparison. Transform-pixel fidelity stays
entirely on the PNG group; encoder *selection* is a format/header contract here.

## Coverage (non-pro)

resize fit/fill/fill-down/auto, non-smart gravity (+ offsets), enlarge, extend,
extend-aspect-ratio, padding, dpr, **min-width/min-height** (notably *disables*
shrink-on-load — a distinct stage-3 branch, `decode_planner.ex:169-171`), **zoom**,
quality, format, background, blur, sharpen, rotate, trim, strip. Excludes smart/object
gravity and Pro filters. Each constellation maps to a ✅ stage (→ `:equal`/lossy
contract) or a ⚠️ stage (→ `:diverges`).

## Process & documentation discipline (per CLAUDE.md)

- **Matrix doc sync:** add a "Differential conformance" subsection to
  `docs/imgproxy_support_matrix.md` documenting the harness + the verdict↔stage-row
  mapping. Axis: records *how* conformance is verified; no ✅/⚠️ content change.
- **Review cycle:** the implementation plan gets a disjoint-focus parallel review
  before execution, including a **compatibility-lens reviewer** validating the
  constellation verdicts, divergence pairings, and tolerance choices against real
  upstream imgproxy (`/Users/hlindset/src/imgproxy`). Commit the reviewed plan first.
- **Demo UI:** no new transform parameters → `fiddle/` untouched.
- **Contributor loop (documented in the test failure message + a README):** add row →
  `MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures` (needs Docker) → commit PNG
  + manifest → push. The "missing fixture → fail" rule reddens CI until fixtures are
  committed; this is intended (forces generation) and the failure names the task.

## Layout

```
docs/imgproxy_support_matrix.md                       # + "Differential conformance" subsection
test/support/image_pipe/test/imgproxy_differential/
  constellations.ex                                   # ImagePipe.Test.ImgproxyDifferential.Constellations (Boundary, deps: [])
  sources/                                            # committed fixed sources (jpeg/webp/png + .icc)
  fixtures/                                           # committed reference PNGs
  manifest.<term|json>                                # generated provenance (shape-validated on load)
  REPORT.md                                           # generated, human-readable bump record
lib/mix/tasks/imgproxy.gen_sources.ex                 # one-shot source builder (compile-clean w/o dep)
lib/mix/tasks/imgproxy.gen_fixtures.ex                # generator (compile-gated testcontainers body)
test/image_pipe/imgproxy_differential_conformance_test.exs  # default-lane comparison test + CI skew-guard
```

## Open implementation details (decided during planning, not forks)

- Tolerance constants `T`/`B` per group/constellation (tuned against real fixtures).
- Manifest serialization (Elixir term vs JSON) + its load-time shape validator.
- imgproxy non-pro container config (URL signing `unsafe`, FS root, format
  availability, encoder effort/threads pinned, no linear colorspace).
- testcontainers health-wait strategy.
- Exact `:diverges` metric/region/floor per divergent constellation.
- Whether `high_freq_webp` residual-scale cases need a wider `B` than JPEG boundaries.
