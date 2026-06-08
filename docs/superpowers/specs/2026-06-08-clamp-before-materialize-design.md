# Design: clamp before materialize — avoid the oversized buffer on the plain path (#164, approach A)

**Issue:** #164. **Approach:** A (reorder), chosen by unanimous 3-agent quorum over B (narrow fold) and
C (full fold). See the gate/decision record:
`docs/superpowers/specs/2026-06-08-oversized-buffer-materialization-benchmark-design.md`.
**Builds on (merged):** #150 / #166 (`ImagePipe.Output.Clamp`), #165 / #168 (host `max_result_*`
→ effective caps `min(host, encoder_limit)`).

## Goal

On an over-cap **enlarge** request, the pipeline currently resizes up to the oversized target,
**materializes that oversized buffer**, and only then downscales it with the post-hoc clamp. Move the
clamp to run on the **lazy** composite **before** the materialization, so libvips fuses the resize →
clamp and the oversized intermediate never fully forms. **Byte-identical** output (probe P2); memory
high-water drops from ~556/848 MiB to ~200/222 MiB at pre-clamp 16000/20000 (benchmark Arm A → Arm C).

## Scope

- **In scope:** the **plain** (non-oriented) path, where the oversized buffer is materialized at the
  **delivery backstop** (`Request.Processor.materialize_before_delivery`,
  [processor.ex:142,221-236](../../../lib/image_pipe/request/processor.ex)) — the common case the
  benchmark measured.
- **Byte-identity is universal across plain compositions** (fit / stretch / cover / canvas / padding):
  `copy_memory` is pixel-identity, so moving it around the clamp never changes output (probe P2).
- **The memory win is *verified* only for fit/stretch** (benchmark Arm C is a single resize node).
  cover (resize→crop) and canvas/padding (embed) insert extra lazy nodes between the resize and the
  clamp; whether libvips fuses `crop→resize` / `embed→resize` without a tile/line cache (so the
  oversized intermediate never forms) is **plausible but unmeasured** — the exact "silent line/tile
  cache" failure mode CLAUDE.md warns about. **This change MUST add Arm-C-style bench probes for
  cover+over-cap and canvas+over-cap and report the result** (see Tests). If a composition does *not*
  fuse, the reorder is still correct/byte-identical — that composition simply keeps its buffer
  (graceful degradation to today's behavior). Do not claim universal memory savings until probed.
- **Out of scope — deferred:**
  - The **oriented** mid-chain flush (`OrientationFlush` at the resize, inside `PlanExecutor`):
    materializes *before* final dims / negotiated format are known, so a pre-materialize clamp can't
    reach it without a look-ahead. Stays on the post-hoc clamp (correct, still pays its buffer). Rarer
    sub-corner (oriented source **and** over-cap enlarge).
  - The **double resample** (upscale-then-downscale) quality/CPU artifact — **approach B (narrow
    fold)**, deferred/future work per the quorum decision; revisit only if profiling shows over-cap
    enlargement is common and the CPU/quality cost is material. A is a strict prerequisite for B, so
    this forecloses nothing.

## The reorder

Today, in the producer ([producer.ex:108-144](../../../lib/image_pipe/request/source_session/producer.ex)):

```
process_decoded_source        # runs transform AND materializes (delivery backstop) — at OVERSIZED dims
  → resolve_output            # format negotiation
  → effective_limits + Clamp.clamp   # downscales the already-materialized oversized buffer
  → Encoder.stream_output
```

Reordered:

```
process_decoded_source (lazy) # runs transform, returns the LAZY composite (no delivery-backstop copy)
  → resolve_output            # on the lazy image (only read needed: Image.has_alpha?, an O(1) header read)
  → effective_limits + Clamp.clamp   # inserts the downscale as a LAZY node on the lazy resized image
  → materialize               # copy_memory the CLAMPED image (libvips fuses → buffer is ≤cap)
  → Encoder.stream_output
```

The single change: **the `copy_memory` that turns the pipeline into a RAM buffer moves after the
clamp.** `resolve_output` + `Clamp.clamp` move ahead of it. Both already run in the producer (the
`Request` boundary calling `Output`), so this is **not** a boundary change — it stays where #165 put it.
The `transform` boundary is untouched (no result-cap policy enters it — unlike B/C).

### Where materialization lands (settled in review)

**Use an explicit producer-owned materialize step after `Clamp.clamp`, reusing
`materialize_before_delivery`.** Do **NOT** rely on the encoder's `finalize` to materialize:
`finalize` only `copy_memory`s when stripping metadata, and returns the image **lazy** when
`strip_metadata: false` *and* `strip_color_profile: false` ([encoder.ex:48-49](../../../lib/image_pipe/output/encoder.ex)).
On that no-strip path, "rely on finalize" would (a) leave the memory win unmeasured/unrealized and
(b) reroute a late corrupt-source `copy_memory` failure from `{:decode,_}` → 415 to `{:encode,_}` →
**500** (or a crash) via the producer's `encode_fallback`. So materialization must be **unconditional**
and own a single deterministic failure point.

Concretely:

- `process_decoded_source` runs the transform and returns the **lazy** state (no delivery backstop).
- `materialize_before_delivery` becomes a shared step that both the **producer** (after `Clamp.clamp`)
  and `process_source` call — preserving its existing failure mapping: `{:source,_}`/`{:config,_}`
  pass through, **everything else → `{:decode, reason}` → 415** (the
  `do_handle_materialization_result` logic, [processor.ex:242-249](../../../lib/image_pipe/request/processor.ex)).
- It must use the **return-tuple** `copy_memory` (never raise — a raised exception in the producer is
  caught as `{:encode, exception, _}` → 500), and keep the `image_materializer` opt injectable so the
  `FailingMaterializer` → 415 tests still drive it.
- Keep `classify_materialize_error/1` (the mid-chain `{:materialize_error,_}` → `{:decode,_}` mapper,
  processor.ex:162-165) **distinct** — it has no `{:source,_}`/`{:config,_}` pass-through and covers a
  different error shape; do not consolidate it with the backstop mapper.

Rejected alternative: pass limits into `process_decoded_source` so it clamps before its own backstop —
that drags `Output` limits into the `Processor`'s transform-execution path; the chosen shape keeps the
clamp in the producer's `Output` calls.

On the **strip path** (the default), this yields two copies (clamp → producer `copy_memory` → finalize
strip-`copy_memory`) — same count as today (backstop copy → strip-copy), just reordered; no pixel
change (P2). On the **no-strip path**, the producer `copy_memory` is the sole materialization.

## Correctness / blast radius (verified against the code)

`process_decoded_source` currently ends with `materialize_before_delivery`. Moving that out changes its
contract, which has a bounded but real blast radius:

- **Callers:** the producer (prod encode path, sole streaming path), `Processor.process_source/3`
  (processor.ex:30, used by `processor_test.exs`), and shrink-on-load tests that call
  `process_decoded_source` directly (`shrink_through_rotate_test`, `shrink_on_load_property_test`,
  `shrink_through_crop_test`) and assert on `final.image` dims. Those dim assertions read lazily and
  should still hold; assertions on `materialized?` (if any) must be revisited.
- **`process_source/3` is a test-only public entry** (only `processor_test.exs` calls it). Resolve
  the contract by composing: `process_source = process_decoded_source (lazy) + materialize_for_delivery`,
  so its "returns RAM-resident" contract is preserved. The existing `processor_test.exs:466-501` pin
  (`materialized? == true`) **already targets `process_source`, so it stays green unchanged** — no
  relocation needed. Add a *new* pin that `process_decoded_source` now returns `materialized?: false`
  (the lazy contract).
- **Error classification (must preserve) — see "Where materialization lands".** A materialize failure
  maps to `{:decode, _}` → **415** today (processor.ex:242-249). The relocated shared step preserves
  this exact mapping; the `FailingMaterializer` → 415 tests (`plug_test.exs:1898,1924`) must still pass
  (move the injection point to wherever the producer's materialize runs). Note: relying on `finalize`
  alone would regress this on the no-strip path — see the blocker resolution above.
- **`source_response` is vestigial — drop it.** `materialize_before_delivery(state, opts,
  source_response)` passes `source_response` but `do_handle_materialization_result/1` ignores it — the
  backstop does **not** release the source. Drop the dead param (arity → /2) and **scrub the stale
  "needs source_response" moduledocs** at processor.ex:150-156 and materializer.ex:13-15 in the same
  change.
- **No-strip source lifetime (note, not a blocker).** With `strip_metadata: false` *and*
  `strip_color_profile: false`, `finalize` stays lazy, so even with the producer's explicit
  `copy_memory` the encode realizes a fused decode→…→clamp pipeline; the sequential **source stays
  open for the duration of the encode** (vs. today's backstop-then-encode, which decoupled them). This
  changes the source-lifetime profile (and means a client disconnect tears down the whole chain —
  arguably good, frees CPU). No client-observable change; note it in the PR.
- **`resolve_output` on a lazy image:** only reads `Image.has_alpha?/1` (producer.ex:211) in the
  `{:needs_final_image_alpha, :source}` branch — an O(1) header read, lazy-safe. Explicit-format
  requests read nothing. ✓

## Output / cache / compat — no observable change

- **Byte-identical** (P2: clamp-then-copy == copy-then-clamp; `copy_memory` is pixel-identity). Served
  pixels, dimensions, content-type, headers unchanged.
- **Cache / ETag:** unchanged — same inputs, same output bytes.
- **imgproxy compat:** no behavioral/pixel change → **stage/order** axis only (per the compat-doc-sync
  rule), *not* a behavioral/pixel "Diverges" entry, no surface-table change, no emoji flip. Append a
  realization-order sentence to the existing host-result-cap row in `docs/imgproxy_support_matrix.md`,
  e.g.: *"On the plain (non-oriented) path the clamp runs on the lazy composite before the
  delivery-backstop materialization, so libvips fuses resize→clamp and the oversized intermediate
  never fully forms (#164, approach A); served pixels, dims, and the `[:output, :clamp]` event are
  byte-/metadata-identical. The oriented mid-chain flush still materializes pre-clamp (deferred)."*
  **`docs/telemetry.md` is UNCHANGED** (the `[:output, :clamp]` `source_dimensions`/`dimensions`/`scale`
  contract is preserved — `Clamp` still reads the same pre-clamp oversized dims off the lazy node;
  state this explicitly so a reviewer doesn't hunt for a phantom edit).

## Tests

Behavioral byte-identity + error contract (the memory win is a benchmark concern, below):

- **No-regression wire tests:** the existing over-cap conformance tests
  (`imgproxy_wire_conformance_test.exs`) must still pass unchanged — same status, content-type, decoded
  dims, `[:output, :clamp]` telemetry. This is the byte-identity guard at the wire.
- **Error classification:** the `FailingMaterializer` → 415 tests must still pass (move the injection
  point to the producer's materialize step). Confirm a `copy_memory` failure at the new point yields
  `{:decode,_}` → 415, **not** `{:encode,_}` → 500 (the blocker the design resolves).
- **`process_source` materialize pin:** move the `materialized? == true` assertion
  (`processor_test.exs:466-501`) onto `process_source` (= `process_decoded_source` + the shared
  materialize), since `process_decoded_source` now returns lazy.
- **Shrink-on-load tests:** confirm the direct `process_decoded_source` callers still pass (dim
  assertions are lazy-safe); adjust any `materialized?` assertions.

**Bench probes (required for the memory claim — extend the one-off `bench/oversized_buffer_highwater.exs`):**
add Arm-C-style cells for **cover + over-cap** and **canvas/padding + over-cap** and report the
high-water. If they fuse (≈ Arm C), the spec may claim the memory win for those compositions; if not,
narrow the claim to fit/stretch and document the graceful degradation (those compositions keep their
buffer, still byte-identical). No high-water assertion in the ExUnit suite (impractical); reference the
probe results in the PR.

## Out of scope

- Approach B (narrow fold) and C (full fold) — deferred (B is the documented potential follow-up).
- The oriented mid-chain-flush buffer — deferred (stays on post-hoc clamp).
- Any change to #165's served pixels, the demo UI, or the maintained bench suite.

## Process from here

Per CLAUDE.md / the #165 Go path: parallel disjoint-reviewer cycle on this design (lenses: the
`process_decoded_source` contract change + error-classification preservation; the materialization-point
choice; an imgproxy-compat lens confirming **no observable change** + the stage/order doc note) →
commit reviewed design → `writing-plans` → parallel plan review → `subagent-driven-development`
(fresh subagent + spec→quality review pair per task) → final review → `mise run precommit` → PR.
