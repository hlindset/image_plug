# Imgproxy Aspect-Ratio Geometry Design

## Scope

This slice brings ImagePipe's imgproxy compatibility parser in line with
imgproxy's two aspect-ratio geometry options:

- **Fix `extend_aspect_ratio` (`extend_ar`, `exar`)** — the current parser
  implements a non-imgproxy shape. Correct it to imgproxy's
  `extend_aspect_ratio:%extend:%gravity` semantics.
- **Add `crop_aspect_ratio` (`crop_ar`, `car`)** — an imgproxy Pro option that
  corrects the aspect ratio of the `crop` area. Not currently implemented.

Both options translate cleanly into the existing product-neutral
`ImagePipe.Plan` and reuse transforms that already exist. No new transform
behavior is invented; the work is concentrated in the imgproxy parser, the plan
builder, two semantic plan operations, the executable crop operation, the demo
UI, and documentation.

Out of scope: `resizing_algorithm` (`ra`), `trim` (`t`), and all other geometry
gaps. The support-matrix corrections for `ra`/`car` Pro markers are included
because they are factual fixes adjacent to this work.

## Current State

### `extend_aspect_ratio` is implemented with the wrong shape

imgproxy's option is `extend_aspect_ratio:%extend:%gravity`:

- `extend` is a boolean (`1`/`t`/`true` enable).
- `gravity` (optional) accepts the same values as the `gravity` option except
  `sm`, `obj`, and `objw`; default `ce` with no offsets.
- When enabled, imgproxy extends the image **to the requested aspect ratio** —
  the ratio implied by the requested `width:height` resize dimensions — padding
  the deficient axis only. Default `false:ce:0:0`.

ImagePipe today instead parses two positive numbers as a literal
`{width, height}` ratio written into the URL:

- `lib/image_pipe/parser/imgproxy/option_grammar.ex` `parse_extend_aspect_ratio/2`
  reads `[width, height]` as two positive numbers.
- `lib/image_pipe/parser/imgproxy/pipeline_request.ex` stores
  `extend_aspect_ratio: ImagePipe.imgp_ratio() | nil`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex`
  `extend_aspect_ratio_operation/1` emits a `Canvas` operation whose width/height
  are `{:ratio, w, h}` taken from the URL literal, always with default center
  gravity.

Consequences:

- A real imgproxy URL such as `.../exar:1:ce/...` errors today, because `ce`
  is not a positive number.
- The invented `exar:16:9` form is accepted but has no imgproxy meaning.
- The gravity argument is ignored; offsets are unsupported.

The **transform layer is already correct**. `ImagePipe.Transform.Operation.ExtendCanvas`
supports a `{:aspect_ratio, {ratio_width, ratio_height}}` rule that "expands the
canvas on the needed axis so the final canvas has the requested ratio while
preserving the full current image" (`lib/image_pipe/transform/operation/extend_canvas.ex`).
`ImagePipe.Transform.PlanExecutor` already lowers a `Canvas` operation with
`{:ratio, _, _}` dimensions into that rule via `canvas_rule/2`. The fix is
therefore entirely in the parser and plan builder: change where the ratio comes
from (the resize target, not the URL) and carry the parsed extend flag, gravity,
and offsets.

### `crop_aspect_ratio` is missing

imgproxy's option is `crop_aspect_ratio:%aspect_ratio:%enlarge`:

- `aspect_ratio` is a single non-negative number (width / height). `0` means no
  correction.
- `enlarge` is a boolean. When enabled, imgproxy enlarges the crop area to reach
  the ratio instead of reducing it; if an enlarged dimension exceeds the image
  size, imgproxy reduces the crop area to fit while maintaining the ratio.
- It corrects the **size** of the crop area only, not the crop gravity. Per
  imgproxy's own note, `crop:100:200:nowe:300:400/crop_ar:1:1` crops a
  `200x200` area anchored by the unchanged `nowe` gravity (offsets `300:400`).
  Note that `car:1:1` here is `aspect_ratio=1` **plus `enlarge=1`** — so the
  `100x200` area is *enlarged* to `200x200` (the deficient short axis grows to
  match). The default (reduce) form `car:1` would instead shrink it to
  `100x100`.

**Source caveat.** `crop_aspect_ratio` is imgproxy Pro and has no implementation
in the non-Pro Go source, so the exact reduce/enlarge axis selection, the
enlarge clamp-to-bounds fallback, and tie rounding cannot be verified against
source — only against the docs. Implement per the documented behavior. Tie
rounding follows ImagePipe's existing crop convention (`round_ties_to_even/1` in
`crop.ex`) for internal consistency; this is a minor, pixel-tie-only divergence
from imgproxy's `math.Round` (half away from zero) and is not asserted at the
pixel level.

The crop area is produced by `crop:%width:%height:%gravity`, parsed into
`ImagePipe.Parser.Imgproxy.CropRequest` and lowered to
`ImagePipe.Plan.Operation.CropGuided` then `ImagePipe.Transform.Operation.Crop`.
Crop dimensions can be absolute pixels, relative fractions (`<1`), or full-axis
(`0`). Relative and full-axis dimensions resolve to pixels only inside the crop
transform, against the live source size. Therefore the aspect-ratio correction
must run inside the crop transform after dimensions resolve to pixels, not at
plan-build time.

## Design

### Feature 1: Fix `extend_aspect_ratio`

**Parser (`option_grammar.ex`).** Replace `parse_extend_aspect_ratio/2` with the
same parsing shape as the sibling `parse_extend/2`: parse the first argument as
an extend boolean and the optional remainder as gravity. Emit parser fields:

```elixir
[extend_aspect_ratio: extend?, extend_aspect_ratio_requested: true,
 extend_aspect_ratio_gravity: gravity_or_nil,
 extend_aspect_ratio_x_offset: x_or_nil,
 extend_aspect_ratio_y_offset: y_or_nil]
```

mirroring the existing `extend`/`extend_requested`/`extend_gravity`/offsets
fields. The exact field names follow the existing `extend_*` precedent.

**Reuse note:** the existing `parse_optional_extend_gravity/2` hardcodes the
`extend_gravity`/`extend_x_offset`/`extend_y_offset` key names
(`option_grammar.ex:299-332`). To emit `extend_aspect_ratio_*` keys it must be
parameterized with a key prefix (preferred) or duplicated. Do not silently
reuse it as-is.

**Gravity scope.** Mirror the existing `extend` gravity exactly: the 9
directional anchors in `@gravity_anchors` (`ce`, `no`, `so`, `ea`, `we`, and the
four corners) plus optional `x`/`y` offsets. imgproxy additionally allows `fp`
(focus point) gravity for `extend`/`exar`, but ImagePipe's `extend` does **not**
support `fp` today (the `ExtendCanvas` transform only places by `{:anchor, ...}`,
not focal point), so exar inherits the same directional-only support. Adding
`fp` extend-gravity is a pre-existing gap in `extend` and is deferred (see
Deferred Behaviors). `sm`, `re`, `obj`, and `objw` are rejected, as they already
are by `@gravity_anchors`.

**PipelineRequest (`pipeline_request.ex`).** Replace the
`extend_aspect_ratio: imgp_ratio() | nil` field with a boolean
`extend_aspect_ratio` plus `extend_aspect_ratio_requested`,
`extend_aspect_ratio_gravity`, `extend_aspect_ratio_x_offset`, and
`extend_aspect_ratio_y_offset`, typed consistently with the existing `extend_*`
fields.

**PlanBuilder (`plan_builder.ex`).** Rewrite `extend_aspect_ratio_operation/1`:

- No-op (return `nil`) when extend is not enabled, mirroring
  `extend_operation_requested?/1`'s `extend: false, extend_requested: true`
  case.
- No-op unless **both** resize dimensions are explicit positive pixels. The
  requested aspect ratio is undefined otherwise. `request.width`/`request.height`
  are tagged values (`:auto`, `{:pixels, 0}`, `{:pixels, N}`, `{:scale, N}`);
  treat `:auto`, `{:pixels, 0}`, and `{:scale, _}` (percentage/scale resize, no
  fixed target ratio) as no-op. Only `{:pixels, N}` with `N > 0` on both axes
  yields a ratio.
- Otherwise emit a `Canvas` operation whose per-axis dimensions encode the
  resize target ratio: width `{:ratio, resize_w, 1}` and height
  `{:ratio, resize_h, 1}`, where `resize_w`/`resize_h` are the integer pixel
  values extracted from the `{:pixels, N}` resize dimensions. `Operation.canvas`
  canonicalizes these (gcd), `PlanExecutor.canvas_dimension/1` maps each
  `{:ratio, n, d}` to `{:ratio, n/d}`, and `canvas_rule/2` pairs them into
  `{:aspect_ratio, {resize_w, resize_h}}` for `ExtendCanvas`, i.e. target ratio
  `resize_w / resize_h`. Use the parsed gravity (default center) and offsets,
  with `fill: :transparent, overflow: :reject`.
- Update `effective_padding_pixel_ratio/1`'s `:canvas_preserving` branch, which
  currently checks `not is_nil(request.extend_aspect_ratio)`
  (`plan_builder.ex:554`), to use the new boolean enabled-state predicate.

**Semantics.** The canvas size is computed by `ExtendCanvas` from the **current
(post-resize) image**, not from absolute target pixels: it expands only the
deficient axis so the result reaches the target ratio while preserving the full
current image (`extend_canvas.ex:122-136`). This matches imgproxy, which anchors
the extended canvas to the actual scaled output and scales the deficient axis to
the `TargetWidth:TargetHeight` ratio. Because the canvas runs after resize, this
only changes pixels under `fit` resizing where the image is smaller than `w×h`;
under `fill`/`force` the image already matches the ratio and `ExtendCanvas` is a
no-op.

### Feature 2: Add `crop_aspect_ratio`

**Parser (`option_grammar.ex`).** Add `parse_crop_aspect_ratio/2` dispatched
from `parse_special_option/3` for `crop_aspect_ratio`, `crop_ar`, and `car`.
Parse `[aspect_ratio]` or `[aspect_ratio, enlarge]`:

- `aspect_ratio` is a non-negative number. `0` is valid and means "no
  correction".
- `enlarge` (optional) is a boolean (`1`/`t`/`true`).
- Reject negatives and malformed input with `{:invalid_option_segment, segment}`
  before any side effects.

Emit `[crop_aspect_ratio: ratio_or_nil, crop_aspect_ratio_enlarge: bool]`.

**PipelineRequest (`pipeline_request.ex`).** Add `crop_aspect_ratio` (nil or a
ratio number) and `crop_aspect_ratio_enlarge` (boolean, default `false`).

**CropGuided plan operation (`plan/operation/crop_guided.ex`).** Add two optional
fields: `aspect_ratio` (nil or `{:ratio, numerator, denominator}`) and `enlarge`
(boolean, default `false`). `nil` aspect_ratio means no correction, preserving
current behavior. Wire the new fields through `ImagePipe.Plan.Operation`: add
them to the `@crop_guided_keys` allow-list (`plan/operation.ex:53`, otherwise
`validate_known_options` rejects them), and extend the `crop_guided` constructor
+ `valid_crop_guided?` validation consistent with the existing pattern.

**PlanBuilder (`plan_builder.ex`).** In `crop_operations/1` (which currently
passes only `x_offset`/`y_offset` to `Operation.crop_guided`), populate the new
`CropGuided` fields from the pipeline request. A `crop_aspect_ratio` of `0` or
absent resolves to `aspect_ratio: nil` (no correction). Only `CropGuided`
(gravity/anchor/focal crops) carries the correction; `CropRegion` (coordinate
crops) does not, matching imgproxy where `car` corrects the `crop` option's
area.

**PlanExecutor (`transform/plan_executor.ex`).** In the `CropGuided -> Crop`
lowering, pass `aspect_ratio` and `enlarge` through to the executable `Crop`
struct.

**Crop transform (`transform/operation/crop.ex`).** Add `aspect_ratio` (nil or
`{:ratio, n, d}`) and `enlarge` (boolean) fields. The insertion point is inside
`crop_coordinates/4` for the `crop_from: :gravity` clause
(`crop.ex:147-173`): after `crop_dimension/2` resolves `crop_width`/`crop_height`
to pixels (lines 154-155) and before `gravity_crop_coordinates/7`. `image_width`
and `image_height` are in scope there for the enlarge clamp. Apply the correction
when `aspect_ratio` is set:

- Let `target = numerator / denominator` and `current = crop_width / crop_height`.
- Reduce (default): shrink the axis that makes the area exceed the target ratio
  so the corrected area matches `target`.
- Enlarge: grow the deficient axis to reach `target`; if a corrected dimension
  exceeds the image bound on that axis, fall back to reducing so the area fits
  within the image while keeping `target`.
- Round consistently with the existing `round_ties_to_even/1` helper and clamp
  to `>= 1` and `<= image bound`, as the surrounding code already does.

Gravity, offsets, and anchoring are unchanged: the corrected width/height flow
into the existing `gravity_crop_coordinates/7`, so the crop stays pinned by its
original gravity.

### Demo UI

The demo currently encodes the wrong `exar` shape and has no `car` control.

**`demo/src/demo-url-state.ts`.**

- Rewrite `exar` parsing (`parseExtendAspectRatio`, dispatched at the `"exar"`
  case) to read an extend boolean and optional gravity instead of two numeric
  ratio arguments. Replace `extendAspectWidth`/`extendAspectHeight` state with an
  enabled/extend flag and a gravity selection. Keep state shape consistent with
  the existing `extend` (resize-extend) controls.
- Add `car` parsing producing crop aspect-ratio state (ratio number + enlarge
  boolean), updating crop-related state.

**`demo/src/App.svelte`.**

- Replace the `exar:${extendAspectWidth}:${extendAspectHeight}` summary and its
  ratio inputs with an extend toggle plus a gravity selector; summary becomes
  `exar:1:<gravity>` (or `exar:1` for default center). The aspect ratio is no
  longer user-entered.
- Add a crop aspect-ratio control under the crop section (ratio number input +
  enlarge toggle) emitting `car:<ratio>` or `car:<ratio>:1`.

The demo must round-trip these segments: emit the URL option and parse it back
from `/demo/...` paths.

## Cache Keys

Per the cache guidelines, the canonical key data is reshaped in place with **no
key-data version bump** (greenfield, no need to read old entries):

- `exar`'s canonical operation shape changes: the emitted `Canvas` operation now
  derives its ratio from the resize target and may carry gravity/offsets. This is
  the same `Canvas` operation type already covered by `ImagePipe.Plan.KeyData`;
  confirm the gravity/offset fields are included.
- `car` adds `aspect_ratio` and `enlarge` fields to `CropGuided`. Update
  `ImagePipe.Plan.KeyData` for `CropGuided` to include both, so semantically
  different crops produce different keys.

## Decode Planning

Unchanged. `DecodePlanner` already maps `Canvas` and `CropGuided`/`CropRegion`
to `:random` access. Neither feature introduces a one-pass-safe path.

## Error Handling

- All new parsing rejects malformed input with `{:invalid_option_segment,
  segment}` before any source fetch or cache access, consistent with the request
  safety guidelines.
- `aspect_ratio: 0` and disabled `exar` are valid no-ops, not errors, matching
  imgproxy.
- Disallowed `exar` gravities (`sm`/`obj`/`objw`) are rejected, matching
  imgproxy and the existing `extend` behavior.

## Testing

Following the test guidelines (boundary-focused, wire-level for compatibility,
property tests for invariants):

**Parser (`test/parser/imgproxy/` subdirectory + property test).**

- `exar` parses `extend` boolean + gravity (including default center, corner
  gravities, and offsets); rejects `sm`/`obj`/`objw`/`re`; `exar:0` / disabled is
  a no-op.
- `car` parses `aspect_ratio` and optional `enlarge`; `car:0` is a no-op;
  negatives and malformed input rejected.
- Order-insensitivity property coverage extends to both options.

**Existing tests to rewrite/remove (exact locations):**

- `test/parser/imgproxy/options_test.exs:11,29` — asserts `exar:16:9` →
  `pipeline.extend_aspect_ratio == {16, 9}`. Rewrite to the boolean+gravity
  shape.
- `test/parser/imgproxy/plan_builder_test.exs:233` — uses
  `plan_pipeline(extend_aspect_ratio: {16, 9})`. Rewrite.
- `test/parser/imgproxy/option_grammar_test.exs:232-234` — arity-rejection list
  contains `extend_aspect_ratio:16:9:1` / `exar:16:9:1`; the new valid arity
  changes, so update these.
- `test/parser/imgproxy/option_grammar_test.exs:203-211` — the "dropped options
  return unknown option errors" test currently asserts `crop_aspect_ratio`,
  `crop_ar`, `car`, and `crop_ar:1:1` return `{:error, {:unknown_option, _}}`.
  Implementing `car` **breaks this test**: remove those entries from the
  unknown-option list.

These are post-migration shape pins, not behavior coverage worth keeping; the
rewritten parser tests above cover the corrected shape.

**Plan builder / plan operations.**

- `exar` emits a `Canvas` with `{:ratio, w, h}` derived from the resize target,
  the parsed gravity/offsets, and no-ops when a resize dimension is auto.
- `car` populates `CropGuided.aspect_ratio`/`enlarge`; `0`/absent yields no
  correction.
- `KeyData` distinguishes corrected vs uncorrected crops and exar gravity/offset
  variation.

**Crop transform unit tests (`test/.../crop` transform).**

- Reduce and enlarge correction against absolute, relative, and full-axis crop
  dimensions, including the clamp-to-image-bounds enlarge fallback.
- Gravity/anchor unchanged by correction (the imgproxy `nowe` example).

**Wire-level Plug tests (`imgproxy_wire_conformance_test.exs`).** Real
`ImagePipe.call/2` requests that decode the response body and assert output
dimensions:

- `exar:1` under `fit` extends the canvas to the resize ratio; verify resulting
  dimensions and that `fill`/`force` are no-ops.
- `car:<ratio>` corrects a crop area's dimensions; verify decoded dimensions and
  that gravity placement is unchanged. Include a no-geometry-resize case where
  `car` applies to a standalone crop.
- Cache reuse for semantically equivalent requests; failures (bad gravity)
  return before source/cache access.

**Demo state tests** (`demo/src/processing-path.test.ts`, run via `demo:test`
vitest — this runner exists and must be exercised per the color-controls
precedent):

- Round-trip the new `exar` boolean+gravity shape and new `car` segments through
  demo state.
- **Update existing exar tests that pin the old shape:**
  `processing-path.test.ts:263-286` (emit `exar:16:9`) and the combined
  round-trip at `:744-770` (asserts `extendAspectWidth: 16,
  extendAspectHeight: 9`). These break under the new shape and must be rewritten,
  not just supplemented.

## Documentation

- `docs/imgproxy_support_matrix.md`: `extend_aspect_ratio` Partial -> Supported;
  `crop_aspect_ratio` Missing -> Supported (Pro); **add the missing `(pro)`
  markers to `crop_aspect_ratio` and `resizing_algorithm`**, which the matrix
  currently omits.
- `docs/imgproxy_path_api.md` and `docs/transform_operations.md`: document the
  corrected `exar` semantics and the new `car` option with value ranges and
  examples.

## Deferred Behaviors

- `resizing_algorithm` (`ra`) and `trim` (`t`) remain unimplemented; they are
  separate slices.
- `crop_aspect_ratio` correction is wired only through gravity crops
  (`CropGuided`), not coordinate crops (`CropRegion`), matching imgproxy.
- `fp` (focus point) gravity for `extend`/`extend_aspect_ratio` is not supported.
  This is a pre-existing gap in ImagePipe's `extend` (the `ExtendCanvas` transform
  places by anchor only, not focal point); exar matches `extend`. Adding focal
  extend-gravity is a separate enhancement touching both options and the
  transform.
