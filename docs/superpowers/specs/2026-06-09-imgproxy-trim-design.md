# Design: imgproxy `trim` (uniform-border auto-crop)

**Issue:** #149
**Date:** 2026-06-09
**Target:** imgproxy compatibility (`docs/imgproxy_support_matrix.md`)

## Summary

Add a `trim` transform that detects and removes a uniform-color border from the
source image, matching imgproxy's `trim`/`t` option at **full parity** (all four
args: threshold, color, equal_hor, equal_ver). Trim is pure libvips border
detection (`find_trim` + extract) — **not** ML, not `image_vision`, not the
`smart` saliency feature. The libvips `smart` flag means "auto-detect the
background color," not object detection.

This is an imgproxy parity feature with no ImagePipe equivalent today; it is the
only non-SVG-gated `⭕ missing` stage in the early imgproxy pipeline (stage 2).

## Upstream reference (verified against `local/imgproxy-master`)

- `processing/trim.go` — `trim` is **stage 2** of `mainPipeline`, before
  `scaleOnLoad` (stage 3), `crop`, and `scale`. It imports the color profile,
  calls `vips.Trim`, `CopyMemory`s, then **nils `ImgData`** (disabling
  scale-on-load) and re-runs `CalcParams()` because the source dimensions
  changed.
- `vips/vips.c:875` `vips_trim(in, out, threshold, smart, bg, equal_hor, equal_ver)`
  — the authoritative semantics we replicate:
  1. If the image interpretation isn't sRGB, **colourspace-convert to sRGB** for
     detection.
  2. If the image **has alpha**, **flatten onto magenta `{255,0,255}`** before
     detecting (it does *not* trim-to-alpha-mask).
  3. **smart bg = the top-left pixel** `vips_getpoint(tmp, 0, 0)` of the prepared
     (sRGB-converted, magenta-flattened) image. Non-smart bg = the explicit color.
  4. `vips_find_trim(tmp, &left, &top, &width, &height, background, threshold)`.
  5. **equal_hor / equal_ver** expand the box on the more-trimmed side so both
     opposite margins equal the *smaller* inset (see "Box symmetrization").
  6. **Degenerate box (`width==0 || height==0`) → `vips_copy(in)`**: the image is
     returned **unchanged**, never an error.
  7. `vips_extract_area(**in**, ...)` — extraction is from the **original** image,
     not the sRGB/flattened detection copy.
- `options/parser/apply.go:187` `applyTrimOption` — grammar and gating:
  - `trim:%threshold:%color:%equal_hor:%equal_ver` (alias `t`), **max 4 args**.
  - arg0 threshold (float). **Empty/omitted ⇒ delete ⇒ trim disabled.**
  - arg1 color (hex RGB). Empty ⇒ delete ⇒ smart auto-detect.
  - arg2 equal_hor (bool), arg3 equal_ver (bool).
- `processing/options.go:201` accessors — `TrimEnabled() == Has(TrimThreshold)`;
  `TrimThreshold` default `10.0`; `TrimSmart() == !Has(TrimColor)`; `TrimColor`
  default black; `TrimEqualHor`/`TrimEqualVer` default `false`.

### Box symmetrization (equal_hor / equal_ver)

From `vips/vips.c`, applied against the **original** `Xsize`/`Ysize` after
`find_trim` yields `(left, top, width, height)`:

```
if equal_hor:
  right = Xsize - left - width            # right margin
  diff  = right - left
  if diff > 0:  width += diff             # left margin smaller → grow box rightward
  elif diff < 0: left = right; width -= diff   # right margin smaller → shift+grow box leftward
# equal_ver is the vertical analogue with top/bot/height/Ysize
```

Net effect: each pair of opposite margins becomes equal to the **smaller** of the
two (trim *less* aggressively, symmetrically). This is hand-rolled on top of
`find_trim`; the Elixir `Image` library does not expose it.

## Approach

**Faithfully replicate `vips_trim`** rather than calling the stock `Image.trim`.
`Image.trim`/`find_trim` give us threshold + bg-detect/explicit color, but skip
the magenta-alpha flatten, use a different smart-bg heuristic (averaged top-left
region vs the single `getpoint(0,0)` pixel), error on nothing-to-trim, and have
no equal flags. Full parity requires our own prep → detect → symmetrize → extract.

## Components

### 1. Plan op — `ImagePipe.Plan.Operation.Trim` (semantic, product-neutral)

```elixir
%Trim{
  threshold: float(),               # concrete; parser defaults to 10.0
  background: :auto | %Color{},     # :auto = smart (top-left pixel); %Color{} = explicit bg
  equal_hor: boolean(),
  equal_ver: boolean()
}
```

Factory `ImagePipe.Plan.Operation.trim/1` in `lib/image_pipe/plan/operation.ex`,
validating fields (threshold numeric, background `:auto` or `%Color{}`, flags
boolean) and returning a tagged result like the other factories.

### 2. Executable op — `ImagePipe.Transform.Operation.Trim`

`@behaviour ImagePipe.Transform`.

- `name/1` → `:trim`.
- `requires_materialization?/1` → **`true`** (find_trim scans pixels). It is one
  of the materializing ops alongside right-angle rotate, vertical/both flip, and
  smart/detect crop; it is **not** a candidate for the sequential-safe
  equivalence harness.
- `execute/2` replicates `vips_trim` against `state.image`:
  1. Build a detection copy `prepared`: colourspace→sRGB if the interpretation
     isn't already sRGB; if `Image.has_alpha?(prepared)`, flatten onto
     `[255, 0, 255]`.
  2. Resolve bg: `:auto` → `Image.get_pixel(prepared, 0, 0)`; `%Color{}` → its RGB.
  3. `Vix.Vips.Operation.find_trim(prepared, background: bg, threshold: threshold)`
     → `{left, top, width, height}`.
  4. Apply equal_hor / equal_ver box math against the **original** dims.
  5. If `width == 0 or height == 0` → return `state` with the image **unchanged**.
     A `{:error, :nothing_to_trim}`/`:uncropped` from find_trim is the same no-op,
     never a request failure.
  6. Else `Image.crop(state.image, left, top, width, height)` (extract from the
     **original**, preserving its colorspace/alpha) and update `State`.
- A genuine libvips failure (not the nothing-to-trim sentinel) surfaces as a
  `{:decode, _}`-class error consistent with other materialization failures.

### 3. Pipeline position

In `lib/image_pipe/parser/imgproxy/plan_builder.ex` `plan_geometry/1`, prepend
`trim_operations(request)` **before** `orientation_operations` — trim is the
first geometry op. New order:

```
trim → orientation → crop → resize → color_profile → effects → canvas → padding → background
```

Rationale: trim redefines the source dimensions everything downstream is computed
from. imgproxy runs it at stage 2, before crop/scale, in the **un-oriented
storage frame** (rotateAndFlip is stage 7); ImagePipe defers orientation to a
late flush, so "first, before crop" is the correct storage-frame anchor.

**Color-management position (#124-class divergence, documented not closed):**
imgproxy converts to sRGB *for detection* inside `vips_trim` regardless of `scp`;
ImagePipe runs detection in the source-profile space (its `NormalizeColorProfile`
op stays positioned after geometry, gated on `scp`). Recorded as a Diverges note,
same family as issue #124.

### 4. Parser surface — `ImagePipe.Parser.Imgproxy`

- Add `trim` / `t` to the option dispatch.
- Grammar `trim:%threshold:%color:%equal_hor:%equal_ver`, **max 4 args** (reject
  >4, matching `ensureMaxArgs`).
- arg0 threshold: float; **empty/omitted ⇒ trim disabled** (gate on threshold
  presence, mirroring `TrimEnabled == Has(TrimThreshold)`). Presence *is* the
  enable signal; we store the parsed float. imgproxy's `10.0` getter-default is
  vestigial in the option path (arg0-empty deletes the key and disables trim, so
  the default is never reached); ImagePipe does not need a default threshold.
- arg1 color: hex RGB (3/6 digit). Empty ⇒ `background: :auto`.
- arg2 equal_hor: bool, default `false`. arg3 equal_ver: bool, default `false`.
- Carry the result on `PipelineRequest` (new `trim` field, `nil` when disabled).
  `plan_builder` emits `Plan.Operation.Trim` only when the field is present.
- All validation failures (bad float, bad hex, bad bool, >4 args) return a parser
  error **before** any source fetch or cache access (request-safety guideline).
- Order-insensitivity preserved: option position in the URL does not affect the
  fixed plan order.

### 5. Decode / shrink-on-load — `lib/image_pipe/transform/decode_planner.ex`

`compute_load_shrink/3` short-circuits to `1.0` when its `chain` contains a
`Plan.Operation.Trim`. The planner is fed **only** `first_pipeline_operations`
(`request/processor.ex` `decode_validate_source_response/1`), so this disables
shrink-on-load **iff trim is in the first pipeline** — forfeiting scale-on-load
exactly as imgproxy does (trim stage 2 nils `ImgData` before stage 3).

- **Trim in pipeline 1** → in the planner's chain → shrink disabled → full-res
  decode + materialize.
- **Trim in a later pipeline** → not in `first_pipeline_operations` → pipeline 1's
  resize still drives scale-on-load; trim runs on the already-shrunk in-memory
  image. Matches imgproxy's documented "place trim in a second pipeline to avoid
  early full-resolution materialization" guidance.

Decode still opens `:sequential`; the per-op materialization model handles the
trim's RAM materialization lazily via `requires_materialization?: true`.

### 6. Plan→transform translation — `lib/image_pipe/transform/plan_executor.ex`

Register `Plan.Operation.Trim → Transform.Operation.Trim` in the translation
table, same shape as Crop/Resize.

### 7. Demo UI (`demo/`)

Add trim controls wired into the imgproxy URL state (transform guideline — keep
the demo in sync):
- enable toggle (presence of threshold),
- threshold number,
- background mode: auto vs color picker,
- equal-hor / equal-ver checkboxes.

## Behavioral divergences (recorded, not bugs)

1. **Detection colorspace (#124-class):** imgproxy detects in sRGB; ImagePipe
   detects in the source-profile space. Edge effect on wide-gamut sources.
2. **Smart bg heuristic:** matches imgproxy's `getpoint(0,0)` top-left pixel when
   we replicate it directly; if we ever fall back to stock `Image.find_trim`
   auto-detect, that averages a top-left region instead. We replicate `getpoint`.
3. **Not byte-identical:** like the rest of the imgproxy parity surface, we assert
   dimensions/regions, not bytes (different median-filter/resample internals).

## Conformance doc updates (`docs/imgproxy_support_matrix.md`)

Per the compat-doc sync rule, all three axes change:
- **Stage axis:** pipeline stage 2 `trim` ⭕→✅; mermaid class none→chain; update
  the "Realized in" + Notes, including the shrink-on-load-in-first-pipeline note.
- **Surface axis:** `trim`/`t` row in "Resize, geometry, and orientation"
  Missing→Supported; document the 4-arg grammar and "empty threshold disables."
- **Behavioral axis:** add the Diverges notes above (sRGB-detection #124-class;
  smart bg = top-left pixel).

## Test plan

- **Parser:** grammar — defaults, empty-threshold-disables, hex color, bool flags,
  >4-arg rejection, order-insensitivity; validation failures return before side
  effects.
- **Plan / planner:** `Trim` emitted first in geometry order; decode_planner
  shrink-block — two tests pinning both halves (trim in pipeline 1 disables
  shrink-on-load; trim in pipeline 2 leaves it intact).
- **Transform unit:** `requires_materialization? == true`; equal_hor/ver box math
  against known insets (both `diff>0` and `diff<0` branches); degenerate box →
  image unchanged; alpha source → magenta-flatten detection path.
- **Wire conformance** (`test/image_pipe/imgproxy_wire_conformance_test.exs`): a
  representative request decoding the body and asserting trimmed output dimensions
  vs a synthetic bordered fixture; a no-op case (uniform / no-border image
  returns unchanged); smart vs explicit-color.
- **Sequential-access gate:** trim is materializing, so it is excluded from the
  sequential-safe equivalence harness; confirm the harness's known-materializing
  set stays consistent (no false "sequential-safe" claim).

## Out of scope

- Background *removal* (ML segmentation/matting, alpha cutout) — a different,
  non-imgproxy feature; its own future brainstorm if pursued.
- `IMGPROXY_TRIM_*`-style global config defaults (ImagePipe has no env loader;
  trim is URL-only here).
