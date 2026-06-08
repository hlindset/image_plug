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

### Where materialization lands

Two viable shapes (settle in review):

1. **Producer-owned materialize after clamp.** `process_decoded_source` returns the lazy state; the
   producer materializes the clamped image (an explicit `copy_memory`, or relying on the encoder's
   `finalize` — which already `copy_memory`s when stripping metadata, the default). Preferred.
2. **Pass limits into `process_decoded_source`** so it clamps before its own backstop. Rejected:
   drags `Output` limits into the `Processor`'s transform-execution path; option 1 keeps the clamp in
   the producer's `Output` calls.

## Correctness / blast radius (verified against the code)

`process_decoded_source` currently ends with `materialize_before_delivery`. Moving that out changes its
contract, which has a bounded but real blast radius:

- **Callers:** the producer (prod encode path, sole streaming path), `Processor.process_source/3`
  (processor.ex:30, used by `processor_test.exs`), and shrink-on-load tests that call
  `process_decoded_source` directly (`shrink_through_rotate_test`, `shrink_on_load_property_test`,
  `shrink_through_crop_test`) and assert on `final.image` dims. Those dim assertions read lazily and
  should still hold; assertions on `materialized?` (if any) must be revisited.
- **`processor_test.exs:468-487`** pins "chain that didn't materialize mid-pipeline → backstop
  materializes." If materialization moves to the producer, this pin moves with it (or `process_source`
  keeps an internal materialize for its non-streaming contract — decide in review).
- **Error classification (must preserve).** A materialize failure (corrupt source caught late) maps to
  `{:decode, _}` → **415** today (`materialize_before_delivery` → `do_handle_materialization_result`,
  processor.ex:246-247). After the move, materialization is either the relocated step (preserve the
  mapping) or the encoder's `finalize`, which **already** returns `{:decode, reason}`
  ([encoder.ex:54](../../../lib/image_pipe/output/encoder.ex)) → 415. The `FailingMaterializer` tests
  (`plug_test.exs:1898,1924`) pin this → 415 must still hold.
- **`source_response` is vestigial here.** `materialize_before_delivery(state, opts, source_response)`
  passes `source_response` but `do_handle_materialization_result/1` ignores it — so the backstop does
  **not** currently release the source, and moving it changes no source-release behavior. (The
  moduledoc's "needs source_response" is stale.) De-risks the move.
- **`resolve_output` on a lazy image:** only reads `Image.has_alpha?/1` (producer.ex:211) in the
  `{:needs_final_image_alpha, :source}` branch — an O(1) header read, lazy-safe. Explicit-format
  requests read nothing. ✓

## Output / cache / compat — no observable change

- **Byte-identical** (P2: clamp-then-copy == copy-then-clamp; `copy_memory` is pixel-identity). Served
  pixels, dimensions, content-type, headers unchanged.
- **Cache / ETag:** unchanged — same inputs, same output bytes.
- **imgproxy compat:** no behavioral/pixel change. The conformance doc needs only a **stage/order**
  note in the processing-pipeline section (the clamp now runs before the delivery-backstop
  materialization), per the compat-doc-sync rule — *not* a behavioral/pixel "Diverges" entry. The
  oriented-flush deferral and the deferred B (fold) get a short note.

## Tests

Behavioral, not memory (the memory win is covered by the throwaway benchmark; a high-water assertion
in the suite is impractical):

- **No-regression wire tests:** the existing over-cap conformance tests
  (`imgproxy_wire_conformance_test.exs`) must still pass unchanged — same status, content-type, decoded
  dims, `[:output, :clamp]` telemetry. This is the byte-identity guard at the wire.
- **Error classification:** the `FailingMaterializer` → 415 tests must still pass (update the injection
  point if materialization moved).
- **`processor_test` materialize pins:** update to the new contract (materialization owned by the
  producer, or `process_source` retains its own) — keep a test that a never-materialized chain still
  ends RAM-resident before encode.
- **Shrink-on-load tests:** confirm the direct `process_decoded_source` callers still pass (dim
  assertions are lazy-safe); adjust any `materialized?` assertions.
- No new memory test; reference the benchmark in the PR.

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
