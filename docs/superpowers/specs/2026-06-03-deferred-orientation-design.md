# Deferred orientation (#146) + shrink-through-crop (#151) — design

**Status:** design, pending review
**Issues:** [#146](https://github.com/hlindset/image_pipe/issues/146) (deferred rotation/flip model), [#151](https://github.com/hlindset/image_pipe/issues/151) (shrink-on-load with preceding crop)
**Depends on:** #143 / PR #147 (per-op materialization + always-sequential decode) — **merged** at `8452416`.

## 1. Summary

Adopt imgproxy's deferred-orientation model: instead of applying EXIF auto-orient + user
rotate/flip eagerly at the head of the pipeline, carry the orientation as **pending transform
state**, compensate the intervening geometry ops (crop, resize), and **flush** (apply the
rotation pixels) late — fused with a materialization that has to happen anyway.

This is a **performance parity** optimization. Output is unchanged: the orientation transforms
ImagePipe supports (EXIF 1–8, user rotate 90/180/270, flips) are lossless axis permutations that
commute with crop+resize under axis/gravity compensation, so deferred-flush output is
**byte-identical** to the eager-at-head output that the post-#143 baseline already produces and
that is already imgproxy-compatible. The wins are: fewer `copy_memory` passes (orientation fuses
with the smart-crop / filter / final materialization), and a longer sequential decode in the
auto-orient-without-ML path (better libvips graph fusion).

Delivered as one spec, **two staged slices** in one branch:

- **Slice A (#146):** the deferred-orientation model. Correctness-critical (must preserve output).
- **Slice B (#151):** let shrink-on-load proceed through a preceding crop (and a preceding
  90/270 rotate) by rescaling pending crop coordinates. Pure perf. Gated behind Slice A green.

## 2. Background: the code this builds on

- **Per-op materialization (#147, merged).** The `ImagePipe.Transform` behaviour has
  `requires_materialization?/1` ([transform.ex:68](../../../lib/image_pipe/transform.ex)). Before
  executing an op, `Chain.maybe_materialize/2`
  ([chain.ex:79](../../../lib/image_pipe/transform/chain.ex)) calls `Materializer.materialize/1`
  (`Vix.Vips.Image.copy_memory/1`, sets `State.materialized? = true`) iff the op declares it.
  Today: `Rotate` (any angle) materializes; `Flip` (vertical/both) materializes; `Crop`
  (smart/detect gravity) materializes; `AutoOrient` self-materializes for EXIF 3–8.
- **Eager orientation baseline (post-#143).** `AutoOrient → Rotate → Flip` sit at the head of the
  plan order and apply immediately. This produces correct, imgproxy-compatible output. **#146
  replaces the timing, not the result.**
- **`Transform.State`** ([state.ex](../../../lib/image_pipe/transform/state.ex)) carries
  `image`, `materialized?`, `source_dimensions` (exact pre-shrink dims for residual resize),
  `detector`, etc. No pending-orientation field yet.
- **`PlanExecutor`** ([plan_executor.ex](../../../lib/image_pipe/transform/plan_executor.ex))
  translates the semantic `Plan` into executable `Transform.Operation.*` ops, **interleaving
  build + execute per semantic op** with `state.image` in hand, threading an `execution_context`.
  This is the home for pending state, compensation, and flush bookkeeping.
- **Plan / pipelines.** A `Plan` has `pipelines: [Pipeline.t()]`. `processor`'s
  `execute_plan_pipelines/3` threads one `State` through each pipeline in turn
  ([processor.ex:136](../../../lib/image_pipe/request/processor.ex)), then runs a single
  `materialize_before_delivery/3` after the **last** pipeline
  ([processor.ex:207](../../../lib/image_pipe/request/processor.ex)) — "if not `materialized?`,
  materialize."
- **EXIF auto-orient is parser-pinned to the first pipeline today.** imgproxy treats auto-rotate
  as a global toggle: `effective_auto_rotate/2` collapses all pipeline segments to one boolean,
  and `apply_auto_rotate_to_first_pipeline/2` re-stamps it onto pipeline 1
  ([options.ex:328,357](../../../lib/image_pipe/parser/imgproxy/options.ex)). User rotate/flip are
  genuinely per-pipeline ([options.ex:208](../../../lib/image_pipe/parser/imgproxy/options.ex)).
- **Decode planner** ([decode_planner.ex](../../../lib/image_pipe/transform/decode_planner.ex))
  decides shrink-on-load. `shrink_blocked_before_resize?/1` halts shrink when a
  `CropGuided`/`CropRegion`/`Rotate(90|270)` precedes the resize; `auto_orient_before_resize?/1`
  scans for `%AutoOrient{}` to decide the shrink-axis swap for an EXIF quarter-turn.

## 3. The model (Slice A)

### 3.1 Pending orientation on `Transform.State`

Add `pending_orientation` (nil when nothing pending). It holds the deferred orientation as the
**unified block** — EXIF ∘ user-rotate ∘ user-flip — carrying enough to (a) compensate pre-flush
ops and (b) replay the rotation at flush time:

- the **numeric** combined quarter-turn + flip (for compensation math), and
- the **replay intent**: apply EXIF autorotate (if enabled) → user rotate → user flip, in that
  order (imgproxy's `rotateAndFlip` order: EXIF then user).

`nil` once flushed.

### 3.2 EXIF is source-level state, not a pipeline op

EXIF orientation is a property of the decoded **source**, read once, gated by a single global
toggle. The eager model smuggled it in as a pipeline-1 op because that's where pixels first got
touched; the pending model doesn't need that.

- **Drop `Plan.Operation.AutoOrient` as a pipeline op.** Carry a single **`auto_rotate`
  boolean** on the canonical plan. *(Field placement — `Plan`-level vs `Plan.Source` — is settled
  in the plan; it must land in `Cache.Key` canonical data, see §6.)*
- Pipelines carry **only** user `Rotate`/`Flip` ops.
- Parser simplifies: `effective_auto_rotate/2` still collapses segments to the boolean;
  `apply_auto_rotate_to_first_pipeline/2` and per-pipeline `AutoOrient` emission go away.

### 3.3 Two coordinate frames (the core invariant)

Mechanical swap rule, ported from imgproxy's `ExtractGeometry`:

1. When a quarter-turn is pending, **swap target W/H once** up front (display frame). All
   plan-level dimension math (resize targets, result-crop dims) then runs in the **display
   frame** — as if the rotation already happened.
2. The two pixel-touching ops *before* the flush swap **back to the storage frame** when they
   issue the vips call, because pixels are still in storage orientation:
   - **crop**: dim swap + gravity remap (§3.6),
   - **resize**: axis swap of the scale factors — the *only* orientation compensation in resize.
3. After the flush, storage frame == display frame; the tail uses values literally.

So compensation isn't ad-hoc patches — it's one principle: **plan-level dimension math happens in
the display frame; the pre-flush pixel ops transform axes + gravity back to storage.**

### 3.4 PlanExecutor responsibilities

`PlanExecutor` owns pending state, compensation, and flush bookkeeping. Operation modules stay
product-neutral and never know about a pending transform.

1. **Seed (pipeline 1 only).** At the start of pipeline 1, if `auto_rotate` is enabled, read the
   decoded source image's EXIF orientation (pure metadata, zero pixels) and seed
   `pending_orientation`. "Seed" = populate the pending block, **not** apply early. Swap the
   display-frame W/H once if the combined turn is a quarter-turn.
2. **Fold user rotate/flip.** As `Rotate`/`Flip` ops are encountered (in order), fold them into
   `pending_orientation` and update the display-frame turn.
3. **Compensate / flush, per op, decided from live state:**
   - pending live **and op does *not* materialize** (plain anchor/region crop; resize) →
     **compensate** (storage-frame axis swap; crop also gravity-remaps), pending stays live.
   - pending live **and op *does* materialize** (smart/detect crop) → emit **literal** params;
     the runtime flush fires first (§3.5) so this op sees oriented pixels — no compensation.
     (This is the "ML present ⇒ early flush ≈ today's rotate-at-head" degradation.)
   - pending already cleared → literal.

   Because `PlanExecutor` interleaves build+execute, "is pending still live?" is read straight
   off `State` after each op; the materializing op flushes pending as a side effect of executing.

### 3.5 The flush (inside materialize)

Per the chosen mechanism, the flush lives in the materialize path, not as an injected op:

- `Chain.maybe_materialize`, when about to materialize an op while `pending_orientation` is set,
  first **replays the pending orientation** (autorotate for EXIF → user rotate → user flip,
  executed directly — bypassing the per-op materialization re-check to avoid recursion), then
  `copy_memory`, then clears `pending_orientation`. The replay reuses the existing product-neutral
  transform mechanisms (autorotate/rotate/flip); this lives inside the `transform` boundary.
- **Per-pipeline flush.** If a pipeline ends with `pending_orientation` still set, flush at the
  pipeline boundary. Rationale: each pipeline is executed as a self-contained pass; EXIF is seeded
  once in pipeline 1 and consumed by pipeline 1's flush, so pipeline 2+ start upright with only
  their own user ops. Within a pipeline the full deferral applies (all crop→resize geometry lives
  in one pipeline). The cost is a possible extra `copy_memory` at a boundary in the rare
  multi-pipeline + late-materialize case — accepted for verifiable per-pipeline correctness.
  *(Carrying pending across pipelines is possible with compensation but rejected for v1.)*
- **Backstop.** `materialize_before_delivery/3` after the last pipeline routes through the same
  flush-aware materialize primitive, so a single-pipeline path that never materialized still has
  its pending orientation applied before output. Invariant: `materialized? == true ⟹ pending nil`.

### 3.6 Compensation surface — port `RotateAndFlip` verbatim

Net-new logic is bounded to **two ops** when a quarter-turn is pending.

**Resize:** single axis swap — when `(combined_angle) % 180 == 90`, swap `wscale`/`hscale`.

**Crop:** dim swap + gravity remap. Port imgproxy's `RotateAndFlip` (`gravity.go:88-156`) as the
**verbatim sequence** flipX → flipY → rotate, each step = *(remap gravity type via lookup) then
(transform X/Y offset on the **post-remap** type)*. Applied **user-then-EXIF** (reverse of
application order). Do **not** implement from a summarized table — the offset switch keys on the
already-remapped type.

Directional rotation map (clean bijection):

| Original | 90° | 180° | 270° |
|----------|-----|------|------|
| N | W | S | E |
| E | N | W | S |
| S | E | N | W |
| W | S | E | N |
| NW | SW | SE | NE |
| NE | NW | SW | SE |
| SW | SE | NE | NW |
| SE | NE | NW | SW |

180° corners are antipodal (NW↔SE, NE↔SW). Center / Smart / FocusPoint types are never remapped
by the lookup — only their offsets change. Flip type maps: flipX swaps E↔W, NE↔NW, SE↔SW; flipY
swaps N↔S, NW↔SW, NE↔SE.

Offset transforms (on post-remap type; FocusPoint fractions use `1-x`, not `-x`):
- **flipX**: Center/N/S → `X=-X`; FocusPoint → `X=1-X`
- **flipY**: Center/E/W → `Y=-Y`; FocusPoint → `Y=1-Y`
- **90°**: Center/E/W → `X,Y = Y,-X`; FocusPoint → `Y,1-X`; else → `Y,X`
- **180°**: Center → `-X,-Y`; N/S → `X=-X`; E/W → `Y=-Y`; FocusPoint → `1-X,1-Y`
- **270°**: Center/N/S → `-Y,X`; FocusPoint → `1-Y,X`; else → `Y,X`

The **tail** (effects → canvas → padding → background) is entirely post-flush and needs **zero**
compensation.

### 3.7 Why output is unchanged

For lossless axis permutations, resampling commutes with the permutation under axis-swapped scale
factors: resampling storage-X at scale *s* then transposing == transposing then resampling
oriented-Y at *s* (same kernel, same logical axis, relabeled). So eager-at-head,
flush-at-smart-crop, and imgproxy's late `rotateAndFlip` all yield byte-identical pixels. The one
placement-sensitive op is salient/attention crop (smart gravity): ImagePipe runs it on **oriented**
pixels in both the baseline and #146 (flush precedes it) — a deliberate divergence from
open-source imgproxy's attention-on-storage-orientation, matching the imgproxy Pro "rotate + ML
together" model. This is pre-existing behavior #146 preserves.

## 4. Slice B: shrink-on-load through a preceding crop (#151)

Pure perf; current behavior is correct. Gated behind Slice A green.

- In `decode_planner.ex`, stop halting `shrink_blocked_before_resize?` on
  `CropGuided`/`CropRegion`. When shrink proceeds through a crop, **rescale** the crop's dims and
  **absolute** gravity offsets (`|offset| >= 1`) by the realized preshrink factor; focus-point /
  relative offsets are untouched. (imgproxy `scale_on_load.go:136-153`.)
- **Synergy:** #146's resize axis-swap compensation also makes the existing `Rotate(90|270)`
  shrink-block liftable by the same mechanism (compensation makes preceding geometry safe to
  shrink through). Treat lifting that block as part of Slice B.
- **Sequencing:** coordinate **rescale** (decode-frame scalar shrink) is independent of and
  precedes the pending-rotation **compensation** (display↔storage axis/gravity). Asserted by a
  pixel-equivalence test, not reasoned about loosely.

## 5. `auto_orient_before_resize?` rework (Slice A, touches the decode path)

With `AutoOrient` gone from the chain, the planner can't scan for `%AutoOrient{}`. Replace it with
consulting `auto_rotate` (passed in by `request`, alongside the existing `exif_quarter_turn?`) +
the real source EXIF quarter-turn to decide the shrink-axis swap.

## 6. Cache key / ETag

- `auto_rotate` boolean enters `Cache.Key` canonical data (it changes output bytes). Which fields
  compose the key is owned by `Cache.Key` and its tests — update there.
- **ETag fast path preserved.** ETag = source byte-identity seed + canonical plan + Accept. The
  `auto_rotate` boolean + source seed carry the same information the old `AutoOrient` op did (two
  images with different EXIF have different bytes → different seed), so the 304-before-fetch path
  still distinguishes correctly. No content-hashing regression.
- **No data-version bump** (greenfield) — reshape canonical key data + tests in place.

## 7. Boundaries

- `auto_rotate` lives in the `plan` boundary; parser emits it; `PlanExecutor` and `decode_planner`
  (both `transform`) read it. The planner gets it passed in by `request` alongside
  `exif_quarter_turn?`. No new cross-boundary edges.
- All new pending/compensation/flush logic stays inside `ImagePipe.Transform.*`. Operation
  modules never reference pending state. Plan order is unchanged.

## 8. Testing (gates)

- **Per-EXIF-orientation pixel equivalence (Slice A, correctness gate):** deferred-flush output ==
  eager-orient-at-head output, orientations 1–8 × {plain crop+resize, anchor/fp/smart crop, user
  rotate/flip combos}, from a genuinely streamed source with `fail_on: :error` (extends #143's
  fixture gate). Runs in the default lane.
- **Detector-ordering gate (Slice A):** a deterministic stand-in `ImagePipe.Detector` that records
  the dimensions/orientation of the pixels handed to it, asserting it receives display-frame
  (oriented) pixels for portrait-EXIF sources after flush. Runs in the default lane, no Nx.
  Plus a thin real-detector smoke test tagged `:image_vision` for where inference is wired.
- **Slice B:** pixel-equivalence between the shrink-through-crop path and the full-decode+crop
  path, covering absolute **and** focus-point gravities, and the lifted `Rotate(90|270)` case.
- **Cache:** `auto_rotate` participates in the key; ETag unaffected by cachebuster/vary, and a
  conditional GET still 304s before fetch/decode.

## 9. Out of scope

- **No demo UI change** — no new/changed transform params or parser options; pure internal
  pipeline reordering plus the `auto_rotate` representation change (already exercised by existing
  `ar`/auto-rotate URL handling).
- No new operation type. Plan order unchanged.
- Carrying pending across pipeline boundaries (rejected for v1, see §3.5).

## 10. Risks / open questions

- **`auto_rotate` field placement** (`Plan` vs `Plan.Source`) — decide in the plan; both satisfy
  the cache-key requirement.
- **EXIF re-derivation under shrink-on-load.** With `autorotate`-at-flush, EXIF is re-read from the
  image's live metadata at flush time, and the numeric angle for compensation is read from the
  image `PlanExecutor` actually receives (already post-reload), so #144's reload and Slice B
  compose without a stale cached angle. Validate with a shrink-on-load + EXIF fixture.
- **Effects materialization timing.** Confirm which tail effects declare
  `requires_materialization?` so the "flush fuses with the first tail materialization" claim holds
  for the no-smart-crop path; otherwise the flush falls to the delivery backstop (still correct).
- **Smart-crop divergence from open-source imgproxy** is intentional (§3.7) and pre-existing; the
  gate test compares deferred-vs-eager (both oriented), so it won't — and shouldn't — pin parity
  against open-source imgproxy's storage-orientation attention.
