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

Three sibling registrations are **required** (each is load-bearing — omitting any
one breaks every trim request), mirroring how the other ops are wired:
- **`Operation.semantic?(%Trim{})` clause** in `plan/operation.ex` (validating the
  same fields). The fallback `semantic?(_) -> false` means a `%Trim{}` with no
  clause is treated as an *invalid* operation and the whole plan is **rejected at
  validation, pre-fetch**. Mirror the `Monochrome`/`Duotone` clauses.
- **`Plan.KeyData.data(%Trim{})` clause** in `lib/image_pipe/plan/key_data.ex`.
  `Cache.Key` maps `KeyData.data/1` over every operation and `key_data.ex` has
  **no catch-all** — an unmatched `%Trim{}` raises `FunctionClauseError` and
  crashes cache-key construction for every trim request. Emit
  `[op: :trim, threshold:, background:, equal_hor:, equal_ver:]`, routing a
  `%Color{}` background through `Color.key_data/1` (like `Background`) and `:auto`
  as a bare atom. Trim is a cache-key-affecting input, so this is correctness, not
  just hygiene.
- **Boundary export** of `Plan.Operation.Trim` in `lib/image_pipe/plan.ex` **and**
  in the exact-match list in `test/image_pipe/architecture_boundary_test.exs`
  (the `assert_boundary_exports(plan, [...])` assertion is `==`, so omission fails
  the suite).

### 2. Executable op — `ImagePipe.Transform.Operation.Trim`

`@behaviour ImagePipe.Transform`. Export `Transform.Operation.Trim` in
`lib/image_pipe/transform.ex` (and its architecture-test list).

- `name/1` → `:trim`.
- `requires_materialization?/1` → **`true`** (find_trim scans pixels). It is one
  of the materializing ops alongside right-angle rotate, vertical/both flip, and
  smart/detect crop; it is **not** a candidate for the sequential-safe
  equivalence harness.
- `execute/2` replicates `vips_trim` against `state.image`:
  1. Build a detection copy `prepared`: colourspace→sRGB if the interpretation
     isn't already sRGB; if `Image.has_alpha?(prepared)`, flatten onto magenta
     with the correct option key — `Image.flatten(prepared, background_color: [255, 0, 255])`
     (the key is `:background_color`, **not** `:background`; the wrong key
     silently flattens onto black and breaks alpha-source detection).
  2. Resolve bg as a **3-element list**: `:auto` → `Image.get_pixel(prepared, 0, 0)`
     (yields `[r,g,b]` for the 3-band prepared image); `%Color{}` →
     `Tuple.to_list(color.channels)` (`Plan.Color.channels` is an `{r,g,b}`
     **tuple**). `find_trim` does **not** validate that the background band count
     matches the image — a mismatch silently returns the whole image (no trim)
     rather than erroring, so the list arity must be correct by construction.
  3. `Vix.Vips.Operation.find_trim(prepared, background: bg, threshold: threshold)`
     → `{:ok, {left, top, width, height}}`. The **raw Vix op** signals
     nothing-to-trim as a successful `{:ok, {l, t, 0, 0}}` tuple — it does *not*
     return the `:nothing_to_trim`/`:uncropped` error that the higher-level
     `Image.find_trim` wrapper invents. Any `{:error, _}` from the raw op is a
     **genuine libvips failure** (e.g. a sub-window-size image → "window too
     large") and must be propagated, never swallowed (imgproxy propagates it too,
     `processing/trim.go`).
  4. Apply equal_hor / equal_ver box math against the **original** dims —
     **before** the degenerate check (ordering matters: a uniform image with both
     flags yields a full-image box `{0,0,X,Y}`, not the degenerate branch).
  5. If `width == 0 or height == 0` (after the equal-math) → return `state` with
     the image **unchanged**. This is the *only* no-op path.
  6. Else `Image.crop(state.image, left, top, width, height)` (extract from the
     **original**, preserving its colorspace/alpha) and update `State`.
- Error class: a libvips failure inside `execute/2` returns
  `{:error, {__MODULE__, reason}}`, which the chain surfaces as a transform error
  → **422**, consistent with Crop/Flip/Rotate (`crop.ex:190`, `flip.ex:60`). It is
  **not** a `{:decode, _}`/415 error — that class is reserved for the separate
  pre-op `copy_memory` materialization failure handled by the Materializer, which
  is not Trim-specific. (Removed the earlier incorrect `{:decode, _}` claim.)

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
  **Invalid bool values coerce to `false`, they do not error** — imgproxy's
  `parseBool` (`options/parser/parse.go`) warns and treats an unparseable bool as
  `false` and proceeds; matching parity means reusing the existing imgproxy
  boolean-argument handling (same as `enlarge`/`extend`), **not** adding stricter
  validation. (We omit imgproxy's warning log; that's an invisible divergence.)
- Carry the result on `PipelineRequest` (new `trim` field, `nil` when disabled).
  `plan_builder` emits `Plan.Operation.Trim` only when the field is present.
- The hard-error validations are **threshold** (`parseFloat`) and **color**
  (`parseHexRGBColor`) — both hard-error upstream — plus the **>4-args** guard.
  These return a parser error **before** any source fetch or cache access
  (request-safety guideline). Bad bools do not (see above).
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
  image. This matches imgproxy's explicitly documented guidance: chained pipelines
  (a Pro feature, the `-` separator, which ImagePipe's compat parser supports)
  recommend moving trim to a separate later pipeline so "the result of the first
  pipeline is already resized and loaded to the memory" — `features/chained_pipelines.mdx:29-35`,
  with `usage/processing.mdx:331` confirming trim "disables scale-on-load."

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
4. **sRGB-skip heuristic:** imgproxy gates the detection colourspace-convert on
   `vips_image_guess_interpretation(in) != sRGB`. The available Elixir accessor
   (`Vix.Vips.Image.interpretation/1`) returns the **stored header**
   interpretation, not the guessed one, so an 8-bit RGB image imgproxy would treat
   as already-sRGB may get an extra (harmless) sRGB round-trip here. Negligible
   pixel impact; recorded for completeness.

## Conformance doc updates (`docs/imgproxy_support_matrix.md`)

Per the compat-doc sync rule, all three axes change:
- **Stage axis:** pipeline stage 2 `trim` ⭕→✅; mermaid class none→chain; update
  the "Realized in" + Notes, including the shrink-on-load-in-first-pipeline note.
- **Surface axis:** `trim`/`t` row in "Resize, geometry, and orientation"
  Missing→Supported; document the 4-arg grammar and "empty threshold disables."
- **Behavioral axis:** add the Diverges notes above (sRGB-detection #124-class;
  smart bg = top-left pixel).

## Test plan

- **Parser:** grammar — defaults, empty-threshold-disables, hex color,
  order-insensitivity; **>4-arg rejection** and bad-float / bad-hex failures
  return before side effects; **invalid bool coerces to `false` and the request
  succeeds** (parity — assert it does *not* error).
- **Plan / planner:** `Trim` emitted first in geometry order; `semantic?(%Trim{})`
  accepts a valid op (and the plan is not rejected); decode_planner shrink-block —
  two tests pinning both halves (trim in pipeline 1 disables shrink-on-load; trim
  in a later pipeline leaves it intact).
- **Cache key** (in `Cache.Key` tests, which own the field set): two trims with
  different threshold / background produce different keys; semantically equal
  trims collide. (Guards against the missing-`KeyData`-clause crash too.)
- **Transform unit:** `requires_materialization?(%Trim{}) == true` (single
  assertion — *not* a "harness membership" test). The equal_hor/ver box math
  (`diff>0` and `diff<0`) is exercised through `execute/2` on **fixtures with
  asymmetric borders**, asserting decoded output dimensions — not by poking a
  private `symmetrize` helper. A **bounds property test** over random insets
  asserts the post-equal box always satisfies `0 ≤ left`, `left+width ≤ Xsize`,
  `0 ≤ top`, `top+height ≤ Ysize`.
- **Degenerate × equal-flags ordering:** uniform image + `equal_hor=true,
  equal_ver=false` → unchanged (vertical axis still 0); uniform + **both** flags →
  full-image result via the crop path (not the unchanged path). Pins the
  symmetrize-before-degenerate-check ordering.
- **Alpha + colorspace paths:** an alpha-source fixture whose border distinguishes
  a **magenta** flatten from a black one (catches the `:background_color` key bug);
  a **grayscale** source still trims (exercises the 1-band→3-band sRGB convert +
  3-element auto-bg).
- **Failure propagation:** a sub-find_trim-window-size image surfaces an error
  (the raw op's `{:error, _}` propagates as a 422 transform error), is **not**
  silently returned un-trimmed.
- **Wire conformance** (`test/image_pipe/imgproxy_wire_conformance_test.exs`):
  representative request decoding the body and asserting trimmed dimensions vs a
  synthetic bordered fixture; a no-op case (uniform / no-border image returns
  unchanged), covering the no-geometry form (trim without resize/crop); smart vs
  explicit-color.

## Out of scope

- Background *removal* (ML segmentation/matting, alpha cutout) — a different,
  non-imgproxy feature; its own future brainstorm if pursued.
- `IMGPROXY_TRIM_*`-style global config defaults (ImagePipe has no env loader;
  trim is URL-only here).
