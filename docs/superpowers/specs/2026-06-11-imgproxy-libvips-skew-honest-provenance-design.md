# imgproxy differential: honest libvips provenance, no skew boolean (#207)

## Problem

`ImagePipe.Test.ImgproxyDifferential.Skew.aligned?/1` compares two values that use
**different version schemes**, so it can never be true:

- `runtime_libvips/0` returns `Vix.Vips.version()` — a libvips **release** string
  (e.g. `"8.18.2"`).
- `manifest.imgproxy_libvips` is the **`.so` ABI soname** (e.g. `"42.20.2"`),
  recorded by `gen_fixtures`' `container_libvips/1` from the bundled
  `libvips.so.42` realname (the darthsim container exposes no release string and
  no `vips` CLI).

`"8.18.2" == "42.20.2"` is structurally always `false`, so `aligned?/1` is always
false and the conformance suite's "libvips skew: comparing anyway" warning fires
unconditionally — regardless of any real drift. The same apples-to-oranges
comparison exists at generation time in `gen_fixtures` (`if imgproxy_libvips !=
pipe_libvips` — soname vs release — is always true).

## Why we can't just "compare correctly"

Empirically confirmed during this work:

- **imgproxy side (gen time):** the darthsim container exposes no libvips release
  string, no `vips` CLI, and imgproxy neither logs nor serves its libvips version
  (verified against the local imgproxy checkout — it has `VIPS_*_VERSION` only as
  compile-time C macros, never surfaced at runtime). The only available
  identifier is the `.so` realname — the libtool/ABI **soname**.
- **ImagePipe side:** `Vix.Vips.version()` returns only the **release**; Vix
  exposes no public ABI/soname accessor.

There is no clean, public soname↔release conversion. Either direction would
require fragile env-specific derivation or a hardcoded lookup table maintained
per libvips release. The honest conclusion: the imgproxy-vs-ImagePipe libvips
comparison the code *pretends* to do is not robustly computable.

## Decision

**Drop the boolean.** Remove the structurally-false equality entirely. Always
emit a clearly-labeled provenance note — both versions, each tagged with its
scheme — instead of a skew claim. Decided in brainstorming over two alternatives
(release-vs-release self-drift on ImagePipe's own version; soname→release lookup
table); both were rejected in favor of not pretending to a comparison we can't
honestly make.

This is **test-support only**. No conformance pixel behavior changes. The
manifest shape is unchanged: `imgproxy_libvips` (soname) and `pipe_libvips_at_gen`
(release) stay as provenance — they're useful, just no longer gated by a boolean.

## Changes

### 1. Delete the `Skew` module and its test

- Delete `test/support/image_pipe/test/imgproxy_differential/skew.ex`.
- Delete `test/image_pipe/imgproxy_differential/skew_test.exs`.
- `aligned?/1` is the false comparison being removed. `runtime_libvips/0` is a
  one-line passthrough over `Vix.Vips.version()`. `ci?/1` is dead — only its own
  test references it (confirmed). Inline `Vix.Vips.version()` at the two real call
  sites (with a `"release"` scheme label in the surrounding text), rather than
  keeping a module that does no skew detection plus a tautological wrapper test.

### 2. Conformance test `setup_all`

In `test/image_pipe/imgproxy_differential_conformance_test.exs`, replace the
`if not Skew.aligned?(manifest)` warn-and-attempt block with one **unconditional**
stderr line carrying both versions and their schemes, e.g.:

> `[imgproxy-differential] fixtures baked by imgproxy libvips 42.20.2 (.so ABI soname); ImagePipe running 8.18.2 (release). Different version schemes — not directly comparable; pixel diffs may reflect libvips drift.`

Drop the `Skew` alias. Same once-per-run output volume as today, honest wording.

### 3. `gen_report` provenance

In `test/support/mix/tasks/imgproxy.gen_report.ex`:

- Drop the `skew?: not Skew.aligned?(manifest)` field from `provenance/1`.
- `runtime = Vix.Vips.version()` (drop `Skew.runtime_libvips()`).
- Remove `Skew` from the alias list.

### 4. `report_html` header

In `test/support/image_pipe/test/imgproxy_differential/report_html.ex`:

- Remove the conditional red `skew` banner (it depended on `prov.skew?`).
- Keep the existing provenance `<p>` line, which already labels every value with
  its scheme (`.so ABI soname` / `release, at gen` / `release`). Append a short
  "schemes differ — not directly comparable" clause so the line stands on its own
  as the labeled note.

### 5. `gen_fixtures`

In `test/support/mix/tasks/imgproxy.gen_fixtures.ex`:

- Replace the `if imgproxy_libvips != pipe_libvips` warning (soname vs release,
  always true) with an unconditional, scheme-labeled info log — drop the `!=`
  comparison and the "not truly same-kernel" framing.
- Add scheme labels to the `REPORT.md` provenance lines in `write_report!/1` for
  consistency (`imgproxy libvips (.so ABI soname)` / `ImagePipe libvips at
  generation (release)`).

### 6. Tests

- Delete `skew_test.exs` (module gone).
- In `test/image_pipe/imgproxy_gen_report_test.exs`: drop `skew?` from
  `sample_doc`'s provenance map. Add one assertion that the rendered header
  carries both scheme labels (covers the "clearly-labeled provenance" contract).
  No banner assertion exists today, so nothing else breaks.

### 7. Documentation sync

The deleted warn-and-attempt "skew model" is described in prose that must be
updated in the same change (conformance-doc-sync rule, **stage/order** axis):

- `test/support/image_pipe/test/imgproxy_differential/README.md` — rewrite the
  "## libvips skew — warn-and-attempt" section to describe the always-on,
  scheme-labeled provenance note (record both versions, no version-match claim).
- `docs/imgproxy_support_matrix.md` — drop "skew-gated to the fixtures' libvips"
  from the `:equal` row (the comparison always runs; tolerances absorb
  libvips-version resampling differences), and change the closing pointer's
  "libvips skew model" to "libvips provenance model".
- `gen_fixtures` `container_libvips/1` comment — "the skew identifier" → "the
  provenance identifier" (folded into change 5).

The descriptive "libvips-version resampling skew" in the harness README's
`min_dims_clamp` findings row (and a `constellations.ex` comment) stays — there
"skew" means resampling *error*, not the removed detection model.

## Out of scope / unchanged

- Manifest shape (`manifest.exs`) and `manifest_test.exs` — unchanged.
- No conformance pixel-behavior change; no parser/output/encode/stage change.
- Compatibility reviewer is optional for this harness-only change, per the
  project's review-cycle rule.

## Verification

- `mise run precommit` (format, `compile --warnings-as-errors`, credo --strict,
  full test) — compiles test-support and runs the conformance + gen_report tests.
- Focused: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs test/image_pipe/imgproxy_gen_report_test.exs`.
- Confirm no remaining references to `Skew` (`grep -rn "Skew" test/ lib/`).
