# imgproxy differential pixel conformance — design

**Status:** approved (brainstorm), pending implementation plan
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
convolutions / `find_trim` mean near-exact pixel agreement is realistic — not merely
"looks similar."

This **complements** the existing self-derived
`test/image_pipe/imgproxy_wire_conformance_test.exs` (which asserts ImagePipe's own
contracts via oracle patterns, no real imgproxy). The differential lane adds the
missing third-party ground truth.

## Non-goals

- Not on the precommit/CI hot path for generation — CI only ever *reads* committed
  fixtures. No Docker in the hot path.
- Not testing imgproxy Pro features (smart/object gravity, advanced filters).
- Not testing ImagePipe's S3 source adapter — that is a separate feature/lane (a
  future MinIO service can join the testcontainers setup without coupling).
- Not changing any parser / encode / stage behavior. This is a test harness only;
  no ✅/⚠️ verdict *content* changes.

## Architecture — two decoupled artifacts

### Generator (manually run, off precommit)

`mix imgproxy.gen_fixtures`:

- Brings up a pinned `darthsim/imgproxy@sha256:<digest>` (non-pro config) via the
  **testcontainers-elixir** library, with a `LOCAL_FILESYSTEM_ROOT` bind of the
  committed sources dir so imgproxy fetches sources via `local://`.
- Walks the declarative constellation list, issues each request, **decodes
  imgproxy's output and re-saves it as lossless PNG** (compare in decoded-pixel
  space, never encoded bytes — JPEG/WebP/AVIF encoder settings differ even when
  pixels match).
- Writes: per-constellation fixture PNGs, the generated manifest, and `REPORT.md`.
- The testcontainers dependency is env-gated like the existing `:image_vision`
  precedent (conditional dep in `mix.exs` + opt-in invocation), so the default
  build never pulls it.

`mix imgproxy.gen_sources` (separate one-shot): builds the committed source images
deliberately. Sources are synthesized **once and committed as fixed lossless
inputs**; normal fixture regeneration reuses them. This prevents a dev's libvips
bump from silently changing inputs at generation time.

### Comparison test (default precommit/CI lane)

Runs in the normal `mix test` gate — fast, reads committed PNGs, re-runs ImagePipe
transforms through `ImagePipe.Plug.call/2`, decodes both sides, compares pixels. No
Docker, no opt-in tag for the reader. Self-skips loudly on libvips skew (below).

## Source-of-truth split (joined by `id`)

A constellation has authored-intent fields (human-written) and generated-provenance
fields (machine-written). They live separately:

### Canonical authored list — code module

`test/support/imgproxy_differential/constellations.ex`, imported by **both** the
generator and the test (so the list cannot drift):

```elixir
%{
  id: "rs_fill_zone_q4",
  source: :high_freq,          # :high_freq | :marker | :border | :alpha
                               # | :exif_jpeg | :icc_p3 | :small
  opts: "rs:fill:240:180/...", # imgproxy processing option string
  verdict: :equal,             # :equal | :diverges
  group: :transform,           # :transform | :lossy
  tol: nil,                    # optional per-constellation tolerance override
  note: nil                    # e.g. "#124 colorspace" for :diverges rows
}
```

### Generated manifest — machine-only, committed

Provenance, written by the generator:

- `imgproxy_digest` — the pinned image digest used.
- `imgproxy_libvips` — libvips version inside that container (the version that
  baked the fixture pixels; the skew-gate reference).
- `pipe_libvips_at_gen` — ImagePipe's `Vix.Vips.version()` at generation time
  (provenance/debugging; the generator warns if it differs from `imgproxy_libvips`,
  since then even generation-time validation was not truly same-kernel).
- per-`id`: `{fixture_filename, sha256}`.

Rules:
- A constellation listed in the code module with **no committed fixture** → the test
  **fails** (forces regeneration). This is the "same list" guarantee in action.
- The test verifies each committed PNG against its manifest `sha256` (detects
  accidental edits / corruption).
- A **verdict flip** (`:diverges` → `:equal` after a fix) is a pure code edit; the
  fixture is unchanged, so no regeneration is required.

### `REPORT.md` — committed, human-readable

Written on each generation: old→new `imgproxy_digest` + libvips, and per-constellation
max-delta-vs-previous-fixture, verdict, and pass/fail against the running ImagePipe.
The PR diff of **this file** is the reviewable record of a digest bump — not the
binary PNG diffs.

## Sources — synthesized once, committed, static

The large high-frequency source is the only big file, amortized across all
constellations (outputs are small). Every constellation goes through the downscale
path by default, exercising shrink-on-load (`scaleOnLoad`, stage 3) as the normal
mode; output sizes are swept across the integer shrink-factor boundaries
(1/8, 1/4, 1/2 + residual scale). One explicit **enlarge** constellation uses the
small source.

| key | shape | purpose |
|-----|-------|---------|
| `high_freq` | large zone-plate / radial chirp / fine checkerboard | resampling divergence is visible (flat/gradient hides it); drives downscale-by-default + shrink-boundary sweep |
| `marker` | off-center solid block | unambiguous crop / gravity anchoring |
| `border` | uniform frame | trim has something to detect |
| `alpha` | RGBA with transparency | alpha handling / flatten |
| `exif_jpeg` | JPEG with a real EXIF orientation tag | orientation (must be JPEG — PNG carries no EXIF orientation) |
| `icc_p3` | non-sRGB ICC (Display P3); commits the `.icc` | carries the #124 colorspace divergence |
| `small` | small source | enlarge / extend-aspect-ratio constellations |

No real-photo datasets (licensing); synthetic covers everything that matters.

## Comparison semantics — all skew-gated

### Skew gate

The fixture pixels were baked by a specific libvips (`imgproxy_libvips`). The premise
"same kernels → near-exact" only holds when ImagePipe runs that same version. So:

- Assert only when runtime `Vix.Vips.version()` == manifest `imgproxy_libvips`.
- Otherwise `ExUnit` **skip** with a clear message — never a silent pass, never a
  spurious fail.
- Consequence: CI generates fixtures on its own libvips, so CI always hits the real
  assertions and is the enforcement point; a contributor on a different local libvips
  skips rather than flakes. Fixtures should be generated on the libvips CI runs (and
  ideally one matching the imgproxy container's, so "same kernels" is literally true).

### `:equal` — transform group

Decode ImagePipe's PNG response and the committed PNG; compare with **tight max
per-channel delta + small outlier budget**:

- Primary: max per-channel absolute delta ≤ N on every pixel.
- Plus: a small budget of outlier pixels allowed to exceed N (absorbs a few
  edge/seam pixels from affine resampling).
- Provisional starting values: N ≈ 2/255, outlier budget ≈ 0.05% of pixels capped at
  ≤ 8/255. **Tuned against real fixtures during implementation.** Both knobs are
  per-constellation overridable via `tol`.

### `:diverges`

Assert the delta **exceeds a floor** somewhere (per-constellation). If ImagePipe
accidentally **converges** with imgproxy (e.g. a partial #124 fix), the test fails —
forcing the author to flip the verdict to `:equal` and update the matrix in the same
change. True bidirectional matrix enforcement. Each `:diverges` row is paired with a
source that makes its divergence measurable (`icc_p3` for #124; `border` for
trim-detection space). Floor assertions are skew-gated too, for consistency.

### lossy group — `f:webp/avif/jpeg`, `q:`

Encoding (quantization) depends on each side's encoder library + settings, configured
independently — so decoded-pixel agreement is inherently loose here even with shared
libvips. These constellations request their real format, decode both sides, and use a
deliberately **loose** tolerance, quarantining independent-encoder noise from the
transform-fidelity assertions.

## Coverage (non-pro)

resize fit/fill/auto, non-smart gravity, enlarge, extend, extend-aspect-ratio,
padding, dpr, quality, format, background, blur, sharpen, rotate, trim, strip.
Excludes smart/object gravity and Pro filters. Each constellation maps to a ✅ stage
(→ `:equal`) or a ⚠️ stage (→ `:diverges`).

## Process & documentation discipline (per CLAUDE.md)

- **Matrix doc sync:** add a "Differential conformance" subsection to
  `docs/imgproxy_support_matrix.md` documenting the harness and the verdict↔stage-row
  mapping. Axis: this records *how conformance is now verified*; no ✅/⚠️ verdict
  content changes (the harness changes no behavior).
- **Review cycle:** after the implementation plan is written, run disjoint-focus
  parallel reviewers and apply accepted feedback before implementation. At least one
  reviewer takes the **compatibility lens**: validate the constellation verdicts,
  divergence pairings, and tolerance choices against the real upstream imgproxy (local
  checkout / source), not just internal correctness. Commit the reviewed plan before
  implementation starts.
- **Demo UI:** no new transform parameters → the `fiddle/` app is untouched.

## Layout

```
docs/imgproxy_support_matrix.md                       # + "Differential conformance" subsection
test/support/imgproxy_differential/
  constellations.ex                                   # canonical authored list (compiled, :test)
  sources/                                            # committed static sources (+ .icc)
  fixtures/                                            # committed reference PNGs
  manifest.<term|json>                                # generated provenance
  REPORT.md                                           # generated, human-readable bump record
lib/mix/tasks/imgproxy.gen_sources.ex                 # one-shot source builder
lib/mix/tasks/imgproxy.gen_fixtures.ex                # generator (testcontainers, env-gated dep)
test/image_pipe/imgproxy_differential_conformance_test.exs  # default-lane comparison test
```

## Open implementation details (decided during planning, not forks)

- Exact tolerance constants (tuned against real fixtures).
- Manifest serialization format (Elixir term vs JSON).
- imgproxy non-pro container config (URL signing off / `unsafe`, FS root, format
  availability).
- testcontainers health-wait strategy and the dep env-gate spelling.
- Fixture filename convention (by `id`).
