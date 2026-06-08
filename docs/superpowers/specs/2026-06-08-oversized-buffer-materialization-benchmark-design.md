# Design: oversized-buffer materialization benchmark — gate for #164

**Issue:** #164 — *deferred look-ahead pre-clamp (avoid materializing the oversized buffer)*. This
spec covers **only the gating benchmark**, not the optimization. Per #164's own framing, the
look-ahead pre-clamp **must not be implemented** until a memory high-water benchmark proves the
oversized buffer is a real, avoidable, materially-large cost.

**Builds on (merged):** #150 / PR #166 (post-hoc `ImagePipe.Output.Clamp`), #165 / PR #168 (host
`max_result_*` error→downscale; effective caps = `min(host max_result_*, encoder_limit(format))`).

**Staging (decided in brainstorming):** *benchmark first.* Build + run this throwaway benchmark,
record results here, then apply the gate (below). Only on a **go** verdict do we start a separate
brainstorm → spec → parallel review → plan → subagent-driven implementation cycle for the look-ahead
pre-clamp. This spec is scoped to the measurement.

**Benchmark disposition (decided):** committed as a **marked one-off** under `bench/` — a header
states it is a one-off #164 measurement, not part of the maintained decode-mode suite. It persists
on `main` for reproducibility but is explicitly disposable.

---

## Correction to #164's premise (found in design review — verified against the code)

#164 (and the original framing of this spec) assumed: *"A plain source + oversized resize stays
fully lazy and is shrunk lazily by #150's post-hoc clamp — no buffer. Every other materialization
point (region crop, smart crop, **delivery-backstop flush**) runs at ≤ source dimensions."* **That
is false for the enlarge corner**, and the enlarge corner is exactly where #164 lives.

Verified trace (every oversized-*enlarge* request, oriented **or** plain):

1. `Resize.execute` only `set_image`s the resized (lazy) node; it never sets `materialized?`
   ([`resize.ex:75`](../../../lib/image_pipe/transform/operation/resize.ex)), and its
   `requires_materialization?` is the default `false`
   ([`transform.ex:56`](../../../lib/image_pipe/transform.ex)). So `Chain` does not materialize at
   the resize.
2. `materialized?: true` is set in **exactly one place** — `OrientationFlush`
   ([`orientation_flush.ex:19,67`](../../../lib/image_pipe/transform/orientation_flush.ex)) — i.e.
   only when a flush actually materializes. A plain (orientation-1 / no-EXIF) chain's
   identity/`nil` pending is cleared **without** materializing
   ([`plan_executor.ex:122,127-129`](../../../lib/image_pipe/transform/plan_executor.ex)), so the
   state reaches delivery with `materialized?: false`.
3. `Request.Processor.process_decoded_source` then calls `materialize_before_delivery`
   ([`processor.ex:142,221-227`](../../../lib/image_pipe/request/processor.ex)), which — because
   `materialized?` is false — calls `OrientationFlush.flush` on `pending_orientation: nil` →
   `VipsImage.copy_memory(state.image)` on the **resized, pre-clamp, OVERSIZED** image.
4. Only **after** `process_decoded_source` returns does the producer run the post-hoc clamp
   ([`producer.ex:117` then `:127`](../../../lib/image_pipe/request/source_session/producer.ex)).
   So #150/#165's clamp downscales an image that is **already a RAM-resident oversized buffer** — it
   never had the lazy resize-up→clamp-down fusion the issue assumed.

**Consequences:**

- The oversized buffer is materialized on **every oversized-enlarge request**, not just the
  oriented corner. Orientation only changes **where** it happens (oriented: the flush right after
  the resize, `plan_executor.ex` resize handler; plain: the delivery backstop, `processor.ex:221`),
  **not whether**. An oriented-vs-plain control would therefore show a ~zero gap (both
  materialize) → a **false STOP**.
- The optimization #164 describes is consequently **broader and more clearly worthwhile** than the
  issue thought: the look-ahead pre-clamp shrinks the *resize target* so the resize produces
  cap-sized pixels — then **neither** the flush **nor** the delivery backstop ever holds an
  oversized buffer, and the post-hoc clamp no-ops. It helps all oversized-enlarge traffic.
- The downscale case is unaffected (output ≤ source ≤ `max_input_pixels`); the issue's "≤ source
  dims" claim holds there. The benchmark targets **enlargement past the cap**.

(For completeness, the other `copy_memory` the original enumeration missed: `Encoder.finalize`
strips metadata via `copy_memory` when `strip_metadata`/`strip_color_profile` is set — but that runs
on the **post-clamp** image at ≤ cap, so it is not an oversized materialization. Noted, not a
concern.)

This correction is reported back to #164 as part of the deliverable (see *Deliverables*).

---

## The control: oversize vs. cap-sized (same final output, two ways)

Because orientation is not the discriminator, the control compares **the same final output produced
two ways at a fixed host cap (default 8192)**:

| arm | request target (long axis) | host cap | what happens | high-water tracks |
|---|---|---|---|---|
| **A — current** | oversize (9000 / 16000 / 20000) | 8192 | resize enlarges to oversize → delivery-backstop `copy_memory` of the **oversized** buffer → post-hoc clamp downscales to ~8192 | **pre-clamp (oversized)** dims |
| **B — optimized proxy** | ~8192 (= cap) | 8192 | resize enlarges to ~8192 → delivery-backstop `copy_memory` of the **cap-sized** buffer → clamp no-ops | **cap (post-clamp)** dims |

Both arms produce **identical final pixels** (~8192 long axis). **Arm B is a faithful proxy for the
post-optimization path**: the look-ahead pre-clamp would make Arm A's resize produce cap-sized
pixels, exactly Arm B's behavior. So:

> **Gap (A − B) = the avoidable oversized buffer = what the look-ahead would save.**

This needs no orientation machinery and no implementation of the optimization. Orientation is
demoted to **one optional confirmation cell** (§ Matrix): an oriented oversized request should show
~the same high-water as the plain oversized Arm A, confirming the cost is path-independent.

---

## Why a benchmark at all (the deferred perf check)

CLAUDE.md's transform guidelines: "no materialization" is **correctness-verified but not
perf-verified** — libvips can silently insert a line/tile cache that yields correct pixels but no
memory win. #164 is exactly that deferred perf check. The optimization is also not free: it
deliberately folds the encoder/host result limit into the pre-resize scale (a documented divergence
from imgproxy, whose `fix_size.go`/`prepare.go` constants live only in late, separate steps) and
requires a `:cover`-trap-safe *final-dims* look-ahead. So the cost it removes must be worth removing.

`copy_memory` (`orientation_flush.ex:18,66`) **fully realizes** the image at its current dimensions
into a RAM buffer by definition — it cannot be silently tiled away — so Arm A's spike is a genuine
allocation, not a measurement artifact. The residual silent-cache risk is on **Arm B**: its
high-water must track *cap* dims, i.e. the clamp/encoder must not itself force an oversized
intermediate. The matrix tests this directly (Arm B's measured high-water vs. its expected cap-size
buffer), so a null gap is never ambiguous between "no avoidable cost" and "Arm B also spiked."

### Reachability (re-derived post-#165)

Under #150 alone the effective cap was the encoder limit (WebP 16383 / AVIF 16384), so the corner
only fired when an admin raised `max_result_*` above the encoder limit. **#165 changed this:** the
effective cap is `min(host max_result_*, encoder_limit)`, default host cap **8192**. So an enlarge
past 8192 hits the corner at the **default** configuration → the benchmark's **primary** cap is
8192. A raised cap is a secondary data point.

---

## The gate (decision rule)

Proceed to implement the look-ahead pre-clamp **iff all three hold** (all read off the **libvips
tracked high-water**, `Vix.Vips.tracked_get_mem_highwater/0` — *not* RSS, which allocator retention
can inflate without representing an avoidable buffer; RSS is a directional cross-check only):

1. **Real & avoidable.** Arm A's tracked high-water *materially exceeds* Arm B's at the same cap,
   for matched final output. The gap is the avoidable oversized buffer.
2. **Scales with pre-clamp area.** Across Arm A's oversize sweep at the fixed 8192 cap
   ({9000, 16000, 20000}), high-water rises with the **pre-clamp (oversized)** area while Arm B
   stays flat at the cap-size buffer. A rising A-curve over ≥2 distinct same-cap oversize points,
   against a flat B, is the discriminating evidence that the buffer is pre-clamp-sized (not
   post-clamp).
3. **Materially large.** The gap is order **~100 MiB+** at a realistic oversize and trends toward
   hundreds of MiB / ~1 GiB at ≈2×-cap and raised-cap (see the buffer-size table below; the gap is
   small just-over-cap and only becomes material at ≳2× cap — the benchmark maps where).

**Else: document & stop.** Record the verdict in *Results & Decision* and as a comment on #164; keep
the committed one-off benchmark; do **not** implement. No imgproxy-compat or pixel-equivalence
review is needed for a stop — nothing observable changed.

*Rationale for this bar:* "any reproducible delta" is too weak — a few-MiB win would not pay for the
divergence + `:cover`-trap complexity. "Must be large for common default-cap traffic" is too strict
— enlarging past 8192 is itself uncommon. Option 1 requires the cost to be real, avoidable, and
large **when it bites**, matching the issue's "corner of a corner" framing.

### Expected buffer sizes (the threshold, computed against the ACTUAL matrix)

Source is a **portrait ~2000×3000, 3-channel (no alpha)** image (a JPEG/PNG-no-alpha decode → the
delivery-backstop buffer carries 3 bands). Fit-enlarge to long axis `L` (portrait → height = `L`,
width = `2L/3`). Buffer ≈ `width × L × 3 bytes`:

| arm/point | long axis `L` | pre-clamp dims | buffer (3ch) | post-clamp output | gap vs Arm B |
|---|---|---|---|---|---|
| B (proxy) | 8192 | 5461 × 8192 | **128 MiB** | 5461 × 8192 | — |
| A @ 9000 | 9000 | 6000 × 9000 | **154 MiB** | ~5461 × 8192 | **~26 MiB** |
| A @ 16000 | 16000 | 10667 × 16000 | **488 MiB** | ~5461 × 8192 | **~360 MiB** |
| A @ 20000 | 20000 | 13333 × 20000 | **763 MiB** | ~5461 × 8192 | **~635 MiB** |

(The tracked high-water measures the *actual* allocation regardless of these estimates; the table
calibrates the gate's "~100 MiB" bar and shows the gap is sub-100 MiB just-over-cap but clears it
decisively at ≳2× cap. 4-channel sources scale these ~33% higher.) These dims also confirm gate
condition 2 has **3 distinct, reachable same-cap pre-clamp points** (9000/16000/20000): output is
**PNG** (encoder limit `:infinity`), so the **host cap is the sole binding limit** at all three — no
WebP/AVIF 16383/16384 confound, and 20000 is a valid pre-clamp resize target.

---

## What & how we measure

- **Primary signal:** `Vix.Vips.tracked_get_mem_highwater/0` — the libvips working-set peak, the
  same programmatic counter `bench/decode_modes.exs` trusts. (The project pins a custom Vix fork in
  `mix.lock` with the fixed high-water NIF; stock/old Vix returns ~0 — the self-check arm guards
  against a regression here.)
- **Secondary (directional only):** an OS RSS peak sampler (`ps -o rss`, lifted from
  `decode_modes.exs`) and an optional `--leak` / `vips_shutdown` "memory: high-water mark"
  cross-check. **The gate decision is read off the tracked high-water, not RSS.**
- **One case per OS process.** The counter is process-wide, monotonic, non-resettable, so a clean
  per-case peak requires isolation. Mirror `decode_matrix.exs`: one `mix run` per case → one CSV
  row → collate.
- **Disable the libvips operation cache** (`Vix.Vips.cache_set_max(0)`, `cache_set_max_mem(0)`),
  exactly as `decode_modes.exs:79-80` does, so a retained cached buffer cannot perturb the
  high-water reading. (Required setup, not optional.)
- **Counter self-check arm (anti-silent-failure guard).** One isolated arm `copy_memory`s a
  known-large image and asserts the tracked high-water is **≥ that image's byte size** (a floor, not
  `≈` — libvips also holds transient decode/source buffers, so the peak exceeds the single copy).
  This is the analogue of CLAUDE.md's equivalence-harness self-check: if the NIF were dead/zero,
  *every* arm would read ~0 and the gap would falsely vanish; this arm fails first. A benchmark that
  cannot detect a buffer it knows is there cannot be trusted to report its absence. (Its own process
  isolation means its allocation never pollutes other arms.)
- **Cold-start note.** Per-process isolation means each case pays cold BEAM+libvips startup; this is
  present in both A and B so it cancels in the gap, and is small relative to a 100 MiB+ buffer for
  the absolute (condition 3) reading.

---

## The matrix (explicit executed cells)

Output format **PNG** for all cells (host cap is the sole binding limit). Source portrait
~2000×3000, 3-channel. Resize mode **fit + enlarge** (`enlargement: :allow`).

| cell | arm | target long axis | cap | purpose |
|---|---|---|---|---|
| 1 | B (cap-sized proxy) | 8192 | 8192 | the optimized-path floor |
| 2 | A (oversized) | 9000 | 8192 | just-over-cap (condition 1 + slope point) |
| 3 | A (oversized) | 16000 | 8192 | ≈2× cap (slope point, condition 3) |
| 4 | A (oversized) | 20000 | 8192 | extreme (slope point, condition 3) |
| 5 | A (oversized) | 20000 | 20000 (raised) | raised-cap regime sanity (optional) |
| 6 | self_check | — | — | counter sanity (≥ known buffer bytes) |
| 7 | oriented confirm (EXIF 6, `auto_rotate: true`) | 16000 | 8192 | optional: oriented oversized ≈ Arm A @ 16000 (cost is path-independent) |

- **Condition 1** decided by: cell 2/3/4 (A) − cell 1 (B).
- **Condition 2 (slope)** decided by: cells 2 → 3 → 4 (A rising) vs cell 1 (B flat).
- **Condition 3 (magnitude)** decided by: the cell 3/4 gaps (≳ hundreds of MiB).
- Cells 5–7 are optional confirmations, not load-bearing for the gate.

**Cover mode** is *not* needed for this control (the `:cover`-trap is an implementation-phase
correctness concern, not a buffer-existence question). Omitted to keep the matrix lean; noted here
so its absence is deliberate, not an oversight.

---

## Drive path & source construction

- **Sources.** Arm A/B: a plain 3-channel portrait ~2000×3000 (generate with `Image`/libvips, or
  reuse a `priv/static/images` fixture of suitable size). Optional oriented confirm cell:
  `Image.set_orientation!(6)` re-encoded as JPEG (as in
  [`OrientedFrameOrigin`](../../../test/support/image_pipe/test/oriented_frame_origin.ex)), and the
  request must run with **`auto_rotate: true`** — otherwise `from_exif(6, false)` is identity and the
  EXIF arm silently does not flush (`pending_orientation.ex`, `orientation_flush.ex:80-87`).
- **Pipeline under test.** Must faithfully exercise the **real** seam: decode (with
  `DecodePlanner` options) → `PlanExecutor.execute` → `Processor.materialize_before_delivery` (the
  delivery-backstop `copy_memory`) → producer `effective_limits` (= `min(host, encoder_limit)`) →
  `Output.Clamp` → encoder, with the encoded stream **fully consumed** (libvips is lazy; the peak
  only realizes when pixels are pulled). It must **not** hand-roll a libvips pipeline.
- **Enlarge-only invariant.** Every Arm A/B target must exceed the source long axis (3000), so
  shrink-on-load never fires on either arm (`DecodePlanner.resize_load_shrink` returns ≤ 1.0 for an
  enlargement → no `shrink:`/`scale:` load option, so the JPEG-vs-other-format shrink-on-load
  asymmetry in `decode_planner.ex:191-200` stays dormant and both arms decode at full source dims).
  State and assert this precondition.
- **Exact entry point — implementation detail, settled when building.** Prefer the highest-fidelity
  option practical from `mix run`: (a) a real `ImagePipe.call/2` (native or imgproxy parser) under
  `MIX_ENV=test`, or (b) a direct Processor→Producer-seam invocation
  (`fetch_decode_validate_source_with_source_format` → `process_decoded_source` → `effective_limits`
  → `Clamp.clamp` → `Encoder.stream_output` consumed). **Whichever is chosen, the metadata-strip
  flags and `auto_rotate` must be set explicitly and recorded** (not left to defaults), since they
  determine whether the finalize `copy_memory` and the oriented flush fire. Option (b) must include
  `materialize_before_delivery` (it is inside `process_decoded_source` — but a hand-rolled variant
  must not skip it, or it would erase the very buffer under test).

---

## Deliverables

- `bench/oversized_buffer_highwater.exs` — per-case runner (one case → one CSV row), plus a matrix
  orchestrator (separate file mirroring `decode_matrix.exs`, or a `--orchestrate` mode in the same
  file). Header marks it a **one-off #164 measurement, not part of the maintained suite**.
- This design doc, with **Results & Decision** filled after the run.
- **A correction note on #164** recording that the delivery-backstop `copy_memory` materializes the
  oversized buffer on every oversized-enlarge request (premise fix), regardless of go/no-go.
- On verdict:
  - **No-go:** decision recorded here + the #164 comment. Done.
  - **Go:** a fresh brainstorm → spec → parallel disjoint-reviewer cycle (≥1 imgproxy-compat lens on
    the deliberate divergence + a pre/post **pixel-equivalence** gate proving #164 changes no served
    pixels vs. the #165 baseline) → reviewed design committed → `writing-plans` → parallel plan
    review → reviewed plan committed → `subagent-driven-development` (fresh subagent + spec→quality
    review pair per task) → final parallel review → `mise run precommit` → PR. **The new spec must
    cite this doc's recorded high-water numbers as the justification** — implementation is gated on
    the recorded evidence, not merely a "go" word. That rigor attaches to the implementation, not
    this measurement.

## Process note (this phase)

The heavy subagent-driven-development + per-task review pairs are reserved for the implementation
phase. For this throwaway benchmark we ran a **light parallel design review** before building
(lenses: signal validity, corner correctness, gate soundness — the imgproxy-compat lens is N/A for a
memory measurement); its findings (notably the delivery-backstop premise correction) are folded in
above. Next: build, run, record the verdict.

---

## Out of scope

- The look-ahead pre-clamp itself (the gated optimization) — separate cycle on a **go** verdict.
- Any change to #165's served-pixel behavior, the delivery-backstop design, or the demo UI.
- The maintained decode-mode benchmarks (`bench/decode_modes.exs`, `bench/decode_matrix.exs`) —
  untouched; this is a separate one-off.

---

## Results & Decision

**Verdict: GO** — implement the look-ahead pre-clamp.

Run on the dev machine (macOS, the project's pinned Vix fork), `mise exec -- mix run
bench/oversized_buffer_highwater.exs`, libvips op cache disabled, one OS process per cell, plain
3-channel 2000×3000 source, PNG output, per-axis dimension cap the sole binding limit
(`max_result_pixels` raised). Figures are the **libvips tracked high-water** (the gate signal);
stable to ~1% across three full matrix runs.

| cell | arm | pre-clamp dims | final output | libvips high-water | gap vs B |
|---|---|---|---|---|---|
| 1 | B (cap-sized floor) | 5461×8192 | 5461×8192 | **147 MiB** | — |
| 2 | A @ 9000 (just over) | 6000×9000 | 5461×8192 | 207 MiB | **~60 MiB** |
| 3 | A @ 16000 (≈2× cap) | 10667×16000 | 5462×8192 | 556 MiB | **~409 MiB** |
| 4 | A @ 20000 (extreme) | 13333×20000 | 5461×8192 | 848 MiB | **~701 MiB** |
| 5 | A @ 20000, cap 20000 (no clamp) | 13333×20000 | 13333×20000 | 810 MiB | (raw buffer, no clamp) |
| 6 | self-check | — | — | 122 MiB (floor 51.5) | **OK** (counter alive) |

**Gate evaluation (all three met):**

1. **Real & avoidable.** Arm A's high-water materially exceeds Arm B's (147 MiB) — 556 MiB at 16000,
   848 MiB at 20000. ✓
2. **Scales with pre-clamp area.** The **final output is identical** (5461×8192) across cells 1–4,
   yet Arm A's high-water rises 207 → 556 → 848 MiB as the *pre-clamp* (oversized) area grows
   (54 → 171 → 267 Mpx), while Arm B stays flat at 147 MiB. So the buffer tracks **pre-clamp**, not
   post-clamp, dims. The gap is explained almost exactly by `(pre-clamp 3ch buffer − cap buffer) +
   ~modest fixed overhead` (e.g. 16000: (488 − 128) + ~50 ≈ 409 MiB; 9000: (154 − 128) + ~34 ≈
   60 MiB). ✓
3. **Materially large.** ~409 MiB at ≈2× cap, ~701 MiB at the extreme — decisively past the
   ~100 MiB bar. (As predicted, the gap is sub-100 MiB just-over-cap (~60 MiB at 9000) and only
   becomes material at ≳1.5–2× cap — the optimization is for the larger-oversize regime.) ✓

**Premise correction confirmed empirically.** Arm A is a **plain** source (`auto_rotate: false`, no
EXIF, no rotate) and still materializes the full oversized buffer — at the **delivery backstop**
(`Processor.materialize_before_delivery`), before the post-hoc clamp. So the cost is
path-independent and broader than #164's original "oriented corner" framing: the look-ahead
pre-clamp benefits **all** oversized-enlarge traffic. (The oriented flush is the *same*
`OrientationFlush.copy_memory` at the *same* oversized dims, just fired earlier in the chain — so a
separate oriented cell was not run; path-independence follows structurally and is consistent with
the plain-source measurement here.)

**Next:** proceed to the implementation cycle (fresh brainstorm → spec → parallel review → plan →
subagent-driven development → PR), citing these numbers as the justification — per the *Go* path
above. The throwaway benchmark (`bench/oversized_buffer_highwater.exs`) and this doc are committed as
the gate's record; a correction note is posted to #164.

### Addendum — approach finding (changes #164's prescribed form)

Two extra probes were added to the benchmark while scoping the implementation, and they **redirect the
approach away from #164's "look-ahead fold into resize":**

- **P1 — fold diverges.** `resize src→cap` directly (the issue's fold) vs. #165's `resize src→T` then
  clamp `T→cap` produce **DIFFERENT** pixels (and even different rounded dims, 533×800 vs 534×800):
  a single resample ≠ a double resample. So the issue's fold form **cannot** satisfy its own "must
  not change any served pixels vs. #165" gate.
- **P2 — reorder is byte-identical.** Applying the clamp *before* the `copy_memory` (clamp→copy) vs.
  the current *after* (copy→clamp) is **IDENTICAL** (`copy_memory` is pixel-identity; the clamp
  resamples the same resized pixels either way).
- **Arm C — reorder avoids the buffer.** `resize→clamp(lazy)→copy_memory` (the reorder) measures
  **199.8 MiB @ 16000** and **221.8 MiB @ 20000** — vs. Arm A's 556 / 848 MiB (a **~356 / ~626 MiB**
  win). It lands *between* Arm A and the 147 MiB Arm-B floor (not at it — ~50-75 MiB of streaming
  working-set remains above the pure cap buffer). So **libvips fuses the two lazy resizes**:
  materializing the clamped output does not fully hold the oversized intermediate. (Measured for a
  single resize node = the fit/stretch shape; cover/canvas/padding fusion is unverified — see the
  approach-A design's bench-probe requirement.)

**Implication.** The byte-identical, buffer-avoiding fix is **"clamp before materialize"** (reorder
`Output.Clamp` ahead of the delivery-backstop / flush `copy_memory`), *not* the issue's pixel-divergent
fold-into-resize. The reorder cleanly fixes the **plain** path (the common case; Arm A's buffer here is
the *delivery backstop*, with no orientation). The **oriented** mid-chain flush materializes before the
final dims and negotiated output format are known, so the simple reorder does not reach it — that
corner needs either a separate treatment or is left to the post-hoc clamp (still correct, still pays
its buffer).

### Decision (after a 3-agent quorum)

Three approaches were considered and put to three independent reviewers with an identical neutral brief:

- **A — Reorder only.** Move `Output.Clamp` before the delivery-backstop materialization (byte-identical,
  P2; universal across compositions on the plain path; ~zero correctness risk; small localized change).
  Keeps the upscale-then-downscale double resample (a quality/CPU artifact, not a correctness bug).
- **B — Reorder + narrow fold.** A, plus fold the downscale into the resize for the *simple* subset
  (fit/cover, dimension-cap, no padding/canvas/pixel-cap) to also get the single-resample quality/CPU
  win there; everything else declines to A's post-hoc path.
- **C — Full fold.** Fold across all compositions like imgproxy `limitScale`; largest correctness surface
  (content errors a size-only backstop can't catch), a look-ahead predictor that duplicates pipeline
  geometry, and an architectural reversal (result-cap policy into the product-neutral `transform`
  boundary).

**Verdict: unanimous A (3/3, medium-high confidence).** Reasoning: memory is the only *material* harm and
A removes 100% of it at ~zero risk; B/C only buy a quality/CPU nicety on an *uncommon* corner (over-cap
*enlargement*) at disproportionate cost; A respects the #165 `Output`-boundary architecture while C
reverses it; imgproxy parity does **not** favor the fold (imgproxy is itself split — `limitScale` folds
but `fixSize` is post-hoc, so a retained post-hoc clamp is faithful to `fixSize`); and **A is a strict
prerequisite for B**, so shipping A forecloses nothing.

**Chosen: implement A now. B is deferred/future (potential) work** — revisit only if profiling shows
over-cap enlargement is *not* rare and the double-resample CPU/quality cost is material on real traffic;
if revived, fold the fit/cover dimension-cap subset only (B), never C. Tracked as a follow-up note on #164.
Implementation design for A: see `docs/superpowers/specs/2026-06-08-clamp-before-materialize-design.md`.

### Composition fusion probes (added during A implementation)

To confirm the reorder's memory win is not limited to the single-resize (fit/stretch) shape Arm C
measured, two probes drive the *real* intermediate node types between the resize and the clamp
(@ target 16000 / cap 8192):

- **Ccover** (a crop node — cover result-crop): **~260 MiB**.
- **Ccanvas** (an embed node — canvas/padding): **~207 MiB**.

Both fuse (≈ Arm C's ~200 MiB; far below Arm A's ~556 MiB), so libvips streams `crop→clamp` and
`embed→clamp` without holding the oversized intermediate. The #164 memory win therefore extends to
cover and canvas/padding compositions, not just fit/stretch. (Cover sits a little higher because its
cropped intermediate is itself still over-cap on both axes.)
