# Deferred orientation (#146) + shrink-through-crop (#151) — design

**Status:** design, reviewed (5 disjoint-focus subagent reviews applied, incl. imgproxy observable-compatibility), pending user review
**Issues:** [#146](https://github.com/hlindset/image_pipe/issues/146) (deferred rotation/flip model), [#151](https://github.com/hlindset/image_pipe/issues/151) (shrink-on-load with preceding crop)
**Depends on:** #143 / PR #147 (per-op materialization + always-sequential decode) — **merged** at `8452416`.

## 1. Summary

Adopt imgproxy's deferred-orientation model: instead of applying EXIF auto-orient + user
rotate/flip eagerly at the head of the pipeline, carry the orientation as **pending transform
state**, compensate the intervening geometry ops, and **flush** (apply the rotation pixels) late —
fused with realizing the downscaled image.

This is a **performance parity** optimization. Output is unchanged: the orientation transforms
ImagePipe supports (EXIF 1–8, user rotate 90/180/270, flips) are lossless axis permutations that
commute with crop+resize under axis/gravity compensation, so deferred-flush output is
**byte-identical** to the eager-at-head output the post-#143 baseline produces and that is already
imgproxy-compatible. Wins: fewer `copy_memory` passes (the rotation fuses with realizing the
resized image), and a longer sequential decode in the auto-orient-without-ML path. Byte-identity
is **asserted against an independent libvips reference and proven with rounding-sensitive
fixtures** (§8), not assumed.

Delivered as one spec, **two staged slices** in one branch:

- **Slice A (#146):** the deferred-orientation model. Correctness-critical (must preserve output).
- **Slice B (#151):** let shrink-on-load proceed through a preceding crop / 90·270 rotate by
  rescaling pending crop coordinates. Pure perf. Gated behind Slice A green.

## 2. Background: the code this builds on

- **Per-op materialization (#147, merged).** `ImagePipe.Transform` has `requires_materialization?/1`
  ([transform.ex:68](../../../lib/image_pipe/transform.ex)). Before executing an op,
  `Chain.maybe_materialize/2` ([chain.ex:79](../../../lib/image_pipe/transform/chain.ex)) calls
  `Materializer.materialize/1` (`copy_memory`, sets `State.materialized? = true`) iff the op
  declares it. Today `Rotate` (any angle), `Flip` (vertical/both), `Crop` (smart/detect gravity)
  materialize; `AutoOrient` self-materializes for EXIF 3–8.
- **Eager orientation baseline (post-#143).** `AutoOrient → Rotate → Flip` sit at the head and
  apply immediately, producing correct, imgproxy-compatible output. **#146 replaces the timing,
  not the result, and the eager path is deleted** (no parallel eager impl is retained — see §8).
- **`Transform.State`** ([state.ex](../../../lib/image_pipe/transform/state.ex)) carries `image`,
  `materialized?`, `source_dimensions` (exact pre-shrink dims, **storage frame**, for residual
  resize), `detector`, etc. No pending-orientation field yet.
- **`PlanExecutor`** ([plan_executor.ex](../../../lib/image_pipe/transform/plan_executor.ex))
  translates the semantic `Plan` into executable ops, **interleaving build+execute per semantic op**
  with `state.image` in hand ([plan_executor.ex:68-90](../../../lib/image_pipe/transform/plan_executor.ex)),
  threading an `execution_context`. **Caveat:** one semantic op may expand to several executable ops
  run in a single `Chain.execute` call — notably `cover`/`auto` resize expands to `[Resize, Crop]`
  ([plan_executor.ex:257-278](../../../lib/image_pipe/transform/plan_executor.ex)). PlanExecutor
  builds both **before** either runs, so it cannot re-read `State` *between* them; flush ordering
  inside that expansion is handled explicitly (§3.5).
- **Plan / pipelines.** `processor`'s `execute_plan_pipelines/3` threads one `State` through each
  pipeline as a **separate** `Transform.execute_plan(%Plan{plan | pipelines: [pipeline]}, …)` call
  ([processor.ex:136-158](../../../lib/image_pipe/request/processor.ex)) — `PlanExecutor.execute/3`
  receives a single-pipeline plan with **no index**. A single `materialize_before_delivery/3` runs
  after the last pipeline ([processor.ex:207](../../../lib/image_pipe/request/processor.ex)) and
  routes through an injectable `Materializer` ([processor.ex:218](../../../lib/image_pipe/request/processor.ex)).
  `State` (so `pending_orientation`) **survives across pipeline boundaries unless explicitly
  cleared** — per-pipeline flush is a requirement the implementation must enforce (§3.5).
- **EXIF auto-orient is parser-pinned to the first pipeline today** via `effective_auto_rotate/2` +
  `apply_auto_rotate_to_first_pipeline/2`
  ([options.ex:328,357](../../../lib/image_pipe/parser/imgproxy/options.ex)). User rotate/flip are
  per-pipeline ([options.ex:208](../../../lib/image_pipe/parser/imgproxy/options.ex)).
- **Decode planner** ([decode_planner.ex](../../../lib/image_pipe/transform/decode_planner.ex)):
  `shrink_blocked_before_resize?/1` halts shrink on `CropGuided`/`CropRegion`/`Rotate(90|270)`;
  `auto_orient_before_resize?/1` scans for `%AutoOrient{}` to decide the shrink-axis swap.

## 3. The model (Slice A)

### 3.1 Pending orientation on `Transform.State`

Add `pending_orientation` (nil when nothing pending). It carries the **unified block** with enough
to both compensate pre-flush ops and replay the rotation:

- `auto_rotate?` (bool) — whether EXIF replay is enabled (mirrors `Plan.auto_rotate`). Drives both
  whether EXIF is folded into compensation and whether the flush replays it.
- `exif_angle` (0/90/180/270) and `exif_flip_x` (bool) — EXIF mirror (orientations 2/4/5/7 set a
  horizontal flip; imgproxy `prepare.go:48-50`, applied as `Flip(c.Flip, false)`). Seeded from the
  source tag **only when `auto_rotate?` is true** — both are 0/false for `ar:0`.
- `user_angle` (0/90/180/270), `user_flip_x` (bool), `user_flip_y` (bool).
- a replay intent: (when `auto_rotate?`) EXIF → user rotate → user flip (imgproxy `rotateAndFlip`
  order: EXIF then user).

`nil` once flushed. The numeric fields drive compensation (§3.6). **Critical:** the replay calls
`Image.autorotate` (which reads orientation from the live image *tag*) **only when `auto_rotate?`
is true**. Calling it for an `ar:0` source that still carries an EXIF tag would wrongly apply the
suppressed EXIF rotation — `…/rot:90/ar:0/plain/<orientation-6 src>` would yield EXIF 90° + user
90° = 180° where imgproxy applies only the user 90° (a regression vs. the eager baseline, which
never emits AutoOrient for `ar:0`). When `auto_rotate?` is false the replay applies only user
rotate/flip and leaves the tag intact (stripped later iff `strip_metadata`).

### 3.2 EXIF is source-level state, not a pipeline op

- **Drop `Plan.Operation.AutoOrient` as a pipeline op.** Carry a single **top-level
  `Plan.auto_rotate` boolean** (placement is prescriptive, not open — see §6 cache requirement).
- Pipelines carry **only** user `Rotate`/`Flip` ops.
- Parser simplifies: `effective_auto_rotate/2` still collapses segments to the boolean;
  `apply_auto_rotate_to_first_pipeline/2` and per-pipeline `AutoOrient` emission go away.

**Call-site inventory (production) for removing the `AutoOrient` *plan* op** — every site:

| Site | Change |
|------|--------|
| `plan.ex:22` exports + `architecture_boundary_test.exs` plan-export/`@concrete_plan_names :AutoOrient` | remove plan-op export + assert entry |
| `plan/operation.ex` (alias, union member, `auto_orient/0`, `semantic?/1` clause) | remove |
| `plan/key_data.ex` `data(%AutoOrient{}) → [op: :auto_orient]` | remove; `auto_rotate` enters `plan_material` instead (§6) |
| `plan_executor.ex` `PlanAutoOrient` alias + `executable_operations(%PlanAutoOrient{})` clause | remove (dead with no plan-op) |
| `parser/imgproxy/plan_builder.ex` `auto_orient_operation/1` emission | remove; write `Plan.auto_rotate` |
| `decode_planner.ex` `auto_orient_before_resize?/1` (chain scan) + `open_options/4` | replace scan with passed-in `auto_rotate`; **`open_options/4 → /5`** (§5) |
| `transform/operation/auto_orient.ex` (the *transform* op) | **retained** as the flush-replay primitive (§3.5); revisit its `transform.ex:25` boundary export — narrow if no external constructor remains |

`Plan.detect_classes/1` and `Plan.face_assist?/1` inspect `op.guide`; `AutoOrient` has none, so
they are unaffected.

### 3.3 Two coordinate frames (the core invariant)

1. When a **quarter-turn** is pending (combined EXIF+user angle ≡ 90 mod 180), **swap target W/H
   once** up front; all plan-level dimension math then runs in the **display frame**.
2. The pixel-touching ops *before* the flush operate in the **storage frame**:
   - **pre-resize gravity crop** (anchor/fp): dim swap + gravity remap (§3.6),
   - **resize**: swap the op's requested width/height + min/zoom (§3.6).
3. After the flush, storage frame == display frame; everything downstream uses values literally.

**180° and flip-only:** no axis swap (not a quarter-turn), so no frame W/H swap — but a **pixel
flush is still required** (imgproxy `rotate_and_flip.go:11,16` flushes for 180°), and pre-flush crop
gravity still remaps via the 180°/flip rows of §3.6.

### 3.4 PlanExecutor responsibilities

`PlanExecutor` owns pending state, compensation, and **flush-point insertion**; operation modules
stay product-neutral and never know about pending state.

1. **Seed (first pipeline only).** Because `execute/3` gets a single-pipeline plan with no index,
   `processor` passes an explicit signal (e.g. `seed_orientation: first_pipeline? and
   plan.auto_rotate`, derived in the processor's pipeline loop). On the seeded pipeline,
   PlanExecutor sets `pending_orientation.auto_rotate?` from `plan.auto_rotate`; when true it reads
   the source image's EXIF orientation (pure metadata) into `pending_orientation` and swaps
   display-frame W/H once for a quarter-turn. When false, no EXIF is seeded (so no EXIF compensation
   and no EXIF replay — matching `ar:0`). EXIF reading stays in `transform`; `request` only signals.
2. **Fold user rotate/flip.** As `Rotate`/`Flip` ops are encountered (in order) within the
   pipeline, fold into `pending_orientation`. The accumulator is **per-pipeline**: it starts empty
   each pipeline (EXIF seeded only in the first), and is cleared by that pipeline's flush (§3.5).
3. **Per-op decision (from live `State`):**
   - pre-resize gravity crop (anchor/fp), non-materializing → **compensate** (§3.6), pending stays.
   - **explicit region crop (`CropRegion`)** → cannot be gravity-compensated; **force a flush
     before it** (degrades to eager: region crop sees oriented pixels, literal coords). This costs
     a full-res materialize, but `decode_planner` already blocks shrink-on-load for `CropRegion`,
     so there is no additional perf loss. *(Slice B may add a region coordinate transform if
     shrink-through-region is wanted; out of scope for A.)*
   - smart/detect crop (materializes, pre-resize) → emit literal; the auto-flush fires first so it
     sees oriented pixels.
   - resize (pre-flush, only when no earlier flush happened) → **compensate** (§3.6).
   - result crop (cover/`auto` expansion, post-resize) and all tail ops → **literal** (post-flush
     per §3.5).

### 3.5 The flush rule and mechanism

**Single mechanism (per the chosen design):** a flush-aware materialize primitive — replay pending
orientation (**`Image.autorotate` only when `auto_rotate?`** (§3.1) → user rotate → user flip,
executed directly, bypassing the per-op materialization re-check to avoid recursion), then
`copy_memory`, then clear `pending_orientation`.
Housed in a small `transform`-internal helper (e.g. `Transform.OrientationFlush`) so the generic
`Chain` runner stays op-agnostic. The replay reuses the product-neutral `AutoOrient`/`Rotate`/`Flip`
transform mechanisms.

**When it fires** — at the **earliest** of:
1. the first op that materializes (smart/detect crop — pre-resize, so the flush lands before
   resize → resize then needs no compensation);
2. a **forced** flush before an op that must consume oriented pixels but can't be compensated
   (explicit `CropRegion`, §3.4);
3. **immediately after the resize scaling stage** — a forced flush PlanExecutor inserts between the
   resize and any result crop / tail. This fuses the rotation with realizing the (lazy) resized
   image, matching imgproxy step 6 (`scale`) → step 7 (`rotateAndFlip`) → step 8 (`cropToResult`).
   It makes the cover result crop and the entire tail post-flush/literal;
4. the delivery backstop (`materialize_before_delivery`) — the **no-geometry** case (no crop, no
   resize), where the flush fuses with the final delivery materialize.

Forced flushes (cases 2,3) are PlanExecutor invoking the same flush-aware primitive at controlled
points — *not* a new `FlushOrientation` operation. The auto-fire (case 1) is the existing
`requires_materialization?` path, extended to flush pending first.

**Per-pipeline + backstop.** Each pipeline flushes any pending by its boundary (State threads
across pipelines and won't auto-clear; EXIF seeded only in pipeline 1 → pipeline 2+ start upright).
`materialize_before_delivery/3` must route through the **flush-aware** primitive so the
single-pipeline never-materialized path still applies pending before output. Invariant:
`materialized? == true ⟹ pending_orientation == nil`. *(Carrying pending across pipelines is
possible with compensation but rejected for v1.)*

### 3.6 Compensation surface — port `RotateAndFlip` verbatim

Net-new logic is bounded to the **pre-resize gravity crop** and the **resize**, only when a
quarter-turn (or flip) is pending.

**Resize compensation (ImagePipe-specific).** ImagePipe's resize resolves *target dimensions*
itself from `State.effective_source_dims` (live image = storage frame when pending) + requested
width/height + fit/fill/dpr/min/zoom ([resize.ex:62-113](../../../lib/image_pipe/transform/operation/resize.ex)) —
there is **no** `wscale`/`hscale` to swap (imgproxy's `scale.go:10-11` formulation does not map).
Compensation = **swap the resize op's requested `width`↔`height`, `min_width`↔`min_height`, and
`zoom_x`↔`zoom_y`** when a quarter-turn is pending; `dpr` is scalar (unchanged). Source dims are
the live storage dims as-is. Because display source == swap(storage source), "fit swap(S) to
(Wr,Hr)" and "fit S to swap(Wr,Hr)" are the same computation with axes relabeled → results are
swaps of each other and rounding hits the same logical axis → byte-identical after the flush
rotation. `source_dimensions` (residual-resize exact dims) stays in the **storage frame** (the
removed `AutoOrient` op no longer swaps it; the display-frame swap is plan-level only). This
byte-identity is **proven**, not assumed, with coprime/odd-pixel fixtures (§8).

**Crop gravity compensation.** Port imgproxy's `RotateAndFlip` (`gravity.go:88-156`) as the
**verbatim sequence** flipX → flipY → rotate, each step = *(remap gravity type via lookup) then
(transform X/Y offset on the **post-remap** type)*. Apply it as **two calls, user-then-EXIF**
(reverse of application order), matching `crop.go:49-50` exactly:

```
RotateAndFlip(user_angle, user_flip_x, user_flip_y)   # user rotate+flip
RotateAndFlip(exif_angle, exif_flip_x, false)         # EXIF rotate+mirror
```

Do **not** implement from a summarized table — the offset switch keys on the already-remapped type.

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

180° corners are antipodal (NW↔SE, NE↔SW). Center / Smart / FocusPoint types are never remapped by
the lookup — only their offsets change. Flip type maps: flipX swaps E↔W, NE↔NW, SE↔SW; flipY swaps
N↔S, NW↔SW, NE↔SE.

Offset transforms (on post-remap type; FocusPoint fractions use `1-x`, not `-x`):
- **flipX**: Center/N/S → `X=-X`; FocusPoint → `X=1-X`
- **flipY**: Center/E/W → `Y=-Y`; FocusPoint → `Y=1-Y`
- **90°**: Center/E/W → `X,Y = Y,-X`; FocusPoint → `Y,1-X`; else → `Y,X`
- **180°**: Center → `-X,-Y`; N/S → `X=-X`; E/W → `Y=-Y`; FocusPoint → `1-X,1-Y`
- **270°**: Center/N/S → `-Y,X`; FocusPoint → `1-Y,X`; else → `Y,X`

(Transcription verified against `gravity.go:8-57,96-152` during review.) **Pre-resize gravity crop
dims** also swap when a quarter-turn is pending (`crop.go:55-56`). The result crop, tail, and
everything post-flush use values **literally** — no compensation.

### 3.7 Why output is unchanged

For lossless axis permutations, resampling commutes with the permutation under the
requested-dimension swap above (same kernel, same logical axis, relabeled). So eager-at-head,
flush-after-resize, and imgproxy's late `rotateAndFlip` yield byte-identical pixels — **proven**
with rounding-sensitive fixtures, not asserted. The one placement-sensitive op is salient/attention
crop (smart gravity): ImagePipe runs it on **oriented** pixels (the flush precedes it) in both the
baseline and #146 — a deliberate divergence from open-source imgproxy's attention-on-storage,
matching the imgproxy Pro "rotate + ML together" model. Pre-existing; #146 preserves it.

## 4. Slice B: shrink-on-load through a preceding crop (#151)

Pure perf; gated behind Slice A green.

- In `decode_planner.ex`, stop halting `shrink_blocked_before_resize?` on `CropGuided`/`CropRegion`.
  When shrink proceeds through a crop, **rescale** the crop's dims and **absolute** gravity offsets
  (`|offset| >= 1`) by the realized preshrink factor; focus-point/relative offsets untouched
  (`scale_on_load.go:136-153`).
- **Synergy:** #146's resize requested-dim swap also makes the `Rotate(90|270)` shrink-block
  liftable by the same mechanism — part of Slice B.
- **Sequencing:** rescale (storage-axis scalar shrink) is independent of and precedes the
  display↔storage axis swap (`scaleOnLoad` rescales in storage axes; the swap happens later in
  crop/resize). Asserted by pixel-equivalence test, not reasoned about loosely.
- **Region-crop coordinate transform** (optional, here): if shrink-through-region is wanted, add the
  region left/top recompute under a pending quarter-turn instead of Slice A's force-flush.

## 5. `decode_planner` rework (Slice A, touches the decode path)

With `%AutoOrient{}` gone from the chain, `auto_orient_before_resize?/1` (chain scan) is replaced by
a passed-in `auto_rotate` boolean: **`open_options/4 → open_options/5`** (or a struct arg),
supplied by `request` ([processor.ex:72](../../../lib/image_pipe/request/processor.ex)) alongside
the existing `exif_quarter_turn?`. New swap gate: `auto_rotate AND exif_quarter_turn?` (EXIF is
always "before resize" once source-level, so the old position-sensitivity correctly disappears).
The planner test ([decode_planner_test.exs](../../../test/image_pipe/transform/decode_planner_test.exs))
is **rewritten** to the boolean form, not deleted.

## 6. Cache key / ETag (prescriptive)

- **`auto_rotate` is a top-level `Plan` field, explicitly emitted by `Cache.Key.plan_material/2`**
  ([key.ex:65-79](../../../lib/image_pipe/cache/key.ex)). `plan_material/2` reads only
  `pipelines`/`output`/`cachebuster` and **never reads `plan.source`** — so placing `auto_rotate`
  on `Plan.Source` would silently drop it from **both** key and ETag (cache poisoning + wrong 304).
  This is not an open question; it must be the top-level field.
- **Mechanism (correcting the earlier rationale):** `auto_rotate` takes the slot the `AutoOrient`
  op held in `plan_material` (which feeds **both** key and ETag, `http_cache.ex:60`). On-vs-off
  distinctness comes from **the boolean in `plan_material`**, *not* from the source seed — the seed
  is a storage-identity (ETag/mtime/size), identical for on vs off against the same bytes. The seed
  is unchanged and continues to track source-byte identity over time.
- `auto_rotate` changes output bytes → belongs in **both** key and ETag. Because `plan_material` is
  shared and the ETag only strips cachebuster (`http_cache.ex:73`), emitting it there lands it in
  both, and not in the cachebuster/vary partition — correct.
- **No data-version bump** (greenfield) — reshape `plan_material` + remove the dead
  `KeyData.data(%AutoOrient{})` clause + update the pinned key tests in place.
- Producer test: same source bytes, `auto_rotate` on vs off → **different key and different ETag**.

## 7. Boundaries (confirmed by review — no new edges)

- `Plan.auto_rotate` lives in `plan`; parser emits it (`parser → plan`, existing); `PlanExecutor`
  and `decode_planner` (`transform`) read the `Plan` field (`transform → plan`, existing);
  `request` passes `auto_rotate` to `open_options` (`request → transform`, the same call shape that
  already passes `exif_quarter_turn?`). No new cross-boundary edge.
- Flush replay + compensation stay inside `ImagePipe.Transform.*`. Naming concrete ops there is
  allowed (the architecture test only forbids it in request/source/response and parser files).
  `request`/`source`/`response` continue to dispatch only through generic `Transform`. Plan order
  unchanged; URL option order still does not define processing order.

## 8. Testing (gates)

- **Orientation correctness gate (Slice A) — against an independent libvips reference, runs in the
  default lane.** Compare deferred-flush request output to `Image.autorotate ∘ rotate ∘ flip`
  applied to the same crop+resize result (the reference pattern already in
  [auto_orient_materialize_test.exs:23-26](../../../test/image_pipe/transform/auto_orient_materialize_test.exs)),
  **not** to a retained eager pipeline (the eager path is deleted — no `*_characterization_test.exs`,
  no parallel eager impl kept for testing). Matrix: EXIF **1–8 including mirrors 2/4/5/7** ×
  {plain anchor crop, focus-point crop, smart crop, region crop, cover/`auto` result crop} × user
  rotate/flip combos. Include **rounding-sensitive fixtures** (non-square, odd/coprime source W·H)
  per fit/fill/force × {EXIF 6, EXIF 8} to prove byte-identity through the requested-dim swap.
  **Pin `ar:0` explicitly:** an orientation-6 source with `rot:90` and `ar:0` must apply only the
  user 90° (no EXIF), matching imgproxy and *not* the live tag — the regression guard for §3.1.
- **Request-boundary decode-and-sample-pixels test (Slice A).** Make a real `ImagePipe.call/2`
  request, decode `resp_body`, sample pixels (helpers exist:
  [imgproxy_wire_conformance_test.exs](../../../test/parser/imgproxy/imgproxy_wire_conformance_test.exs)).
  Include the **no-geometry** case (rotate/flip only, no crop/resize) — the riskiest path, where the
  flush falls to the delivery backstop and exercises `materialized? ⟹ pending nil` end-to-end.
- **Compensation unit table test (Slice A).** Direct table test of the gravity remap+offset function:
  every gravity type × every turn/flip, so a remap-branch bug localizes (a wire pixel mismatch
  won't). Legitimate hand-built inputs — the producer is the compensation function itself.
- **Detector-ordering gate (Slice A).** Extend `ImagePipe.Test.FakeDetector`
  ([test/support/fake_detector.ex](../../../test/support/fake_detector.ex)) with a `record_to: pid`
  opt that messages back `{Image.width(img), Image.height(img)}` from `detect/2` (the behaviour
  passes the live image). Assert it receives **display-frame (oriented) dimensions** for a
  portrait-EXIF source (orientation 6/8). Runs in the default lane, no Nx. Plus a thin
  real-detector smoke test tagged `:image_vision`.
- **Property test (one per slice).** Slice A: EXIF 1–8 × random rotate/flip × random crop+resize →
  decoded output within ±1px of and matching the libvips reference (commutation/order-insensitivity).
  Slice B: reuse the ±1px pattern in
  [shrink_on_load_property_test.exs](../../../test/image_pipe/shrink_on_load_property_test.exs).
- **Slice B.** Pixel-equivalence shrink-through-crop vs full-decode+crop (absolute **and**
  focus-point gravities; lifted `Rotate(90|270)`). **Decode-limit guardrail:** an over-limit source
  with a crop+resize that *would* shrink still fails with the pixel-limit error — shrink-through-crop
  must not let an over-budget source past `validate_original_pixels` (which keys off un-shrunk header
  dims, [processor.ex:69-70](../../../lib/image_pipe/request/processor.ex)).
- **Embedded-orientation-tag assertions (Slice A).** With `strip_metadata=false` (`st:0`), assert
  the output's residual EXIF orientation tag: (a) `ar:1`+tagged source → tag absent, pixels rotated;
  (b) `ar:0`+tagged source → tag present, pixels unrotated; (c) `ar:1`+orientation 1 → no change.
  (Default `strip_metadata=true` removes the tag in both systems; these pin the off case.)
- **Cache.** Producer test per §6 (key + ETag differ on auto_rotate on/off); conditional GET still
  304s before fetch/decode.

## 9. Out of scope

- **No demo UI change** — the URL surface (`ar`, `rot`, flip) is unchanged; only the internal
  representation moves. Verified the demo already emits `ar:1`/`rot:` and has the controls
  (`demo/src/App.svelte`, `demo/src/processing-path.ts`). CLAUDE.md's demo-sync rule triggers only
  on changed transform params / parser options — there are none.
- No new operation type; no `FlushOrientation` op. Plan order unchanged.
- Carrying pending across pipeline boundaries (rejected for v1, §3.5).
- Region-crop coordinate transform (Slice A force-flushes instead; optional in Slice B, §4).
- **Animated sources and watermark are unsupported in ImagePipe today** (no frame/`n-pages`
  handling, no watermark transform); the per-pipeline flush model assumes single-frame processing.
  If animation is added, the flush must fire per frame (cf. imgproxy `transformAnimated`), and the
  smart-crop-on-oriented-pixels divergence (§3.7) warrants a line of user-facing docs.

## 10. Risks / open questions (resolved items removed)

- **Effects materialization timing.** Which tail effects declare `requires_materialization?` only
  affects fusion, not correctness — with the flush pinned to "after resize" (§3.5 case 3) the tail
  is always post-flush regardless. Confirm during implementation; the backstop guarantees safety.
- **EXIF re-derivation under shrink-on-load (Slice B).** `autorotate`-at-flush re-reads EXIF from
  the image's live metadata, and the numeric angle for compensation is read from the image
  PlanExecutor receives (already post-reload), so #144's reload composes without a stale angle.
  Validate with a shrink-on-load + EXIF fixture in Slice B.
- **Origin-dimension reporting (informational).** imgproxy swaps reported origin W/H for
  orientations 5–8 *regardless* of auto_rotate (`processing.go:204-221`). ImagePipe exposes no
  origin-dimension header, so there's no observable divergence today; revisit only if such a header
  is added.
- **Resolved during review:** `auto_rotate` field placement (→ §6 top-level, prescriptive); the
  resize compensation form (→ §3.6 requested-dim swap); the cover result-crop flush point (→ §3.5
  case 3); CropRegion (→ §3.4 force-flush); EXIF mirror tracking (→ §3.1); seeding/pipeline-index
  plumbing (→ §3.4 processor signal); the correctness gate baseline (→ §8 libvips reference); the
  `ar:0` flush-replay gating so the live EXIF tag never overrides a disabled auto-rotate
  (→ §3.1, §3.5, §8).
