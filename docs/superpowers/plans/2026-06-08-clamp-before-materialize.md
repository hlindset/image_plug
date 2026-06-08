# Clamp-before-materialize (#164 approach A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the plain (non-oriented) over-cap path, run `Output.Clamp` on the lazy composite *before* the delivery materialization, so libvips fuses resize→clamp and the oversized buffer never forms — **byte-identical** output, just less peak memory.

**Architecture:** Move the single delivery `copy_memory` from the *end of* `Request.Processor.process_decoded_source` to the producer, *after* `Clamp.clamp`. `process_decoded_source` returns the lazy transformed `State`; the materialize becomes a shared `Processor.materialize_for_delivery/2` that both the producer (post-clamp) and `process_source/3` call, preserving the `{:decode,_}`→415 error mapping and the injectable `image_materializer`. The `transform` boundary is untouched.

**Tech Stack:** Elixir, `Vix.Vips.Image`, the `image` library, ExUnit, `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-08-clamp-before-materialize-design.md`. **Run all tooling via `mise exec -- …`.**

---

## File structure

- `lib/image_pipe/request/processor.ex` — extract `materialize_for_delivery/2` (public; drop the vestigial `source_response`); `process_decoded_source` returns lazy; `process_source` composes transform + materialize; keep `classify_materialize_error/1` distinct; scrub stale moduledoc.
- `lib/image_pipe/request/source_session/producer.ex` — insert `Processor.materialize_for_delivery/2` after `Clamp.clamp` in `prepare_first_chunk/1`.
- `lib/image_pipe/transform/materializer.ex` — scrub stale "needs source_response" moduledoc line.
- `test/image_pipe/processor_test.exs` — add a pin that `process_decoded_source` returns `materialized?: false` (the contract change); the existing `process_source` materialize test stays green unchanged.
- `bench/oversized_buffer_highwater.exs` — add cover + canvas/padding over-cap Arm-C probes.
- `docs/imgproxy_support_matrix.md` — stage/order realization-order note.

Existing guards that must stay green unchanged (byte-identity + error contract): `test/image_pipe/imgproxy_wire_conformance_test.exs` (over-cap clamp tests), `test/image_pipe/plug_test.exs` (`FailingMaterializer` → 415 tests ~1891-1934), the shrink-on-load tests calling `process_decoded_source`.

---

### Task 1: Extract `materialize_for_delivery/2` (pure refactor, no behavior change)

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (`process_decoded_source` ~107-148, `materialize_before_delivery`/`materialize_state`/`handle_materialization_result`/`do_handle_materialization_result` ~221-249, moduledoc ~150-156)
- Modify: `lib/image_pipe/transform/materializer.ex` (moduledoc ~13-15)

- [ ] **Step 1: Run the full suite to capture a green baseline**

Run: `mise exec -- mix test`
Expected: PASS (note the count, e.g. "N tests, 0 failures").

- [ ] **Step 2: Replace the materialize helpers with a public `materialize_for_delivery/2`**

In `processor.ex`, replace `materialize_before_delivery/3`, `handle_materialization_result/2`, and `do_handle_materialization_result/1` with:

```elixir
@doc """
Materializes the (post-transform) image to a RAM buffer before delivery, unless
an op already materialized mid-pipeline. Maps a materialize failure to a decode
error (→ 415), passing through already-tagged source/config errors. Shared by
`process_source/3` and the producer (which calls it after `Output.Clamp`).
"""
@spec materialize_for_delivery(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
def materialize_for_delivery(%State{} = state, opts) do
  result =
    if state.materialized? do
      {:ok, state}
    else
      materialize_state(state, opts)
    end

  classify_delivery_materialize_result(result)
end

defp materialize_state(%State{} = state, opts) do
  materializer = Keyword.get(opts, :image_materializer, Materializer)
  materializer.materialize(state, opts)
end

defp classify_delivery_materialize_result({:error, {:source, _reason} = error}), do: {:error, error}
defp classify_delivery_materialize_result({:error, {:config, _reason} = error}), do: {:error, error}
defp classify_delivery_materialize_result({:error, reason}), do: {:error, {:decode, reason}}
defp classify_delivery_materialize_result({:ok, %State{} = state}), do: {:ok, state}
```

- [ ] **Step 3: Point `process_decoded_source` at the renamed helper (still materializes here for now)**

In `process_decoded_source/3`, the `source_response` is no longer needed by the materialize. Drop it from the materialize call and the local binding. The `with` inside the `[:transform, :execute]` span becomes:

```elixir
result =
  with {:ok, final_state} <- execute_transform_plan(initial_state, plan, opts) do
    materialize_for_delivery(final_state, opts)
  end

{result, transform_stop_metadata(result)}
```

Also remove the now-unused `source_response = Map.get(decoded, :source_response)` binding if it is used nowhere else in the function (verify with a quick read; `decoded` may still carry it for other purposes — only remove the local if unused).

- [ ] **Step 4: Scrub stale moduledocs about `source_response`**

In `processor.ex` moduledoc/comment (~150-156) and `materializer.ex` moduledoc (~13-15), remove the assertion that the delivery materialize "needs source_response" (it does not — it was dropped). Keep the description that it materializes any chain that did not materialize mid-pipeline.

- [ ] **Step 5: Verify no behavior change**

Run: `mise exec -- mix test`
Expected: PASS, same count as Step 1 (pure refactor — `process_source` and the producer both still get a materialized result).

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: no warnings (catches an unused `source_response`/arity mismatch).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/request/processor.ex lib/image_pipe/transform/materializer.ex
git commit -m "refactor: extract Processor.materialize_for_delivery/2 (drop vestigial source_response)"
```

---

### Task 2: Reorder — `process_decoded_source` returns lazy; producer materializes after clamp

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (`process_decoded_source/3`, `process_source/3` ~30-35)
- Modify: `lib/image_pipe/request/source_session/producer.ex` (`prepare_first_chunk/1` with-chain ~108-144)
- Test: `test/image_pipe/processor_test.exs` (add a contract pin)

- [ ] **Step 1: Write the failing contract pin for the lazy return**

Mirror how the shrink-on-load tests build `decoded` (see `test/image_pipe/shrink_through_crop_test.exs` ~50-60 for the `fetch_decode_validate_source_with_source_format` + `process_decoded_source` pattern and the `opts()`/`resolved_source()` helpers). Add to `processor_test.exs`:

```elixir
test "process_decoded_source returns a lazy (un-materialized) state for a sequential plan" do
  target_w = 200
  {:ok, operation} = resize_fit(target_w, :auto)
  plan = %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}

  {:ok, decoded} =
    Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source(), opts())

  assert {:ok, %State{materialized?: false} = state} =
           Processor.process_decoded_source(decoded, plan, opts())

  # Dims are still readable on the lazy node (O(1) header read).
  assert Image.width(state.image) <= target_w
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs -k "lazy (un-materialized)"`
Expected: FAIL — `process_decoded_source` currently materializes, so `materialized?` is `true`.

- [ ] **Step 3: Make `process_decoded_source` return the lazy transformed state**

In `process_decoded_source/3`, drop the `materialize_for_delivery` call (added in Task 1) so the span wraps only the transform:

```elixir
result = execute_transform_plan(initial_state, plan, opts)
{result, transform_stop_metadata(result)}
```

- [ ] **Step 4: Compose materialize back into `process_source/3`**

`process_source/3` must preserve its "returns RAM-resident" contract:

```elixir
def process_source(%Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
  with {:ok, decoded} <-
         fetch_decode_validate_source_with_source_format(plan, resolved_source, opts),
       {:ok, %State{} = state} <- process_decoded_source(decoded, plan, opts) do
    materialize_for_delivery(state, opts)
  end
end
```

- [ ] **Step 5: Insert the materialize after `Clamp.clamp` in the producer**

In `producer.ex` `prepare_first_chunk/1`, the `with`-chain (alias `ImagePipe.Transform.State` is already imported). Change the clamp + add a materialize step before `Encoder.stream_output`:

```elixir
     limits = effective_limits(resolved_output.format, request.opts),
     {:ok, clamped, clamp_info} <-
       Clamp.clamp(final_state.image, limits, request.opts),
     :ok <- emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
     {:ok, %State{image: image}} <-
       Processor.materialize_for_delivery(%State{final_state | image: clamped}, request.opts),
     {:ok, stream, content_type} <-
       Encoder.stream_output(image, resolved_output, request.opts),
```

Notes for the implementer:
- `final_state` is now lazy. `%State{final_state | image: clamped}` preserves `final_state.materialized?`: plain path → `false` → materialize copies the **clamped** (≤cap) image (the win); oriented path → `true` → no-op (its mid-chain flush already materialized the oversized buffer — out of scope, unchanged).
- `materialize_for_delivery` returns `{:error, {:decode, _}}` on failure, which the `with`'s `else {:error, reason} -> {:error, reason}` propagates → `sender` → **415**. It uses `copy_memory` via the (injectable) `Materializer`, which returns a tuple and does not raise.

- [ ] **Step 6: Run the contract pin + the full guard set**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS (new pin passes; the `process_source materializes…` test still passes — `process_source` still materializes via composition).

Run: `mise exec -- mix test test/image_pipe/plug_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS — the `FailingMaterializer` → 415 tests (producer now owns the delivery materialize via the injected `image_materializer`) and the over-cap clamp wire tests (byte-identical output) stay green.

- [ ] **Step 7: Full suite + warnings**

Run: `mise exec -- mix test`
Expected: PASS. If a shrink-on-load test asserted `materialized? == true` on a `process_decoded_source` result, update it to `false` (the transform no longer materializes; dims/`source_dimensions` assertions are unchanged).

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/request/processor.ex lib/image_pipe/request/source_session/producer.ex test/image_pipe/processor_test.exs
git commit -m "feat(#164): clamp before delivery materialize (plain-path oversized-buffer fix)"
```

---

### Task 3: Bench probes — verify cover + canvas/padding fusion (memory-win coverage)

**Files:**
- Modify: `bench/oversized_buffer_highwater.exs` (add Arm-C-style cells for cover + canvas over-cap)

- [ ] **Step 1: Add cover + canvas Arm-C probes**

Add two `run_case` clauses (mirror the existing `"C"` clause ~206-247, which does `Image.resize → Clamp.clamp(lazy) → copy_memory`). For each, build the *real* lazy composite the producer would (decode → `Image.resize` to the over-cap target → then the composition op) and feed it to `Clamp.clamp(lazy) → copy_memory`, measuring high-water:
- `"Ccover"`: after the resize, apply a cover crop via `Image.crop`/`Operation.extract_area` to a smaller box (a crop node between resize and clamp).
- `"Ccanvas"`: after the resize, apply `Image.embed` (a canvas/padding embed node between resize and clamp).

Add matrix rows `{"Ccover", 16000, 8192}` and `{"Ccanvas", 16000, 8192}`. Keep the one-off header note.

- [ ] **Step 2: Run the probes (one process per case)**

Run: `mise exec -- mix run bench/oversized_buffer_highwater.exs case Ccover 16000 8192`
Run: `mise exec -- mix run bench/oversized_buffer_highwater.exs case Ccanvas 16000 8192`
Expected: a CSV row each with `libvips_peak_bytes`. Compare to Arm A (≈556 MiB) and Arm C (≈200 MiB).

- [ ] **Step 3: Record the result in the spec + decision doc**

If `Ccover`/`Ccanvas` ≈ Arm C (fused, ~200 MiB) → the memory win extends to those compositions; update the spec Scope section to claim it. If ≈ Arm A (~556 MiB, did not fuse) → narrow the claim to fit/stretch and document the graceful degradation (those compositions keep their buffer; still byte-identical). Edit `docs/superpowers/specs/2026-06-08-clamp-before-materialize-design.md` (Scope) and the benchmark doc's Results/Addendum accordingly with the measured numbers.

- [ ] **Step 4: Commit**

```bash
git add bench/oversized_buffer_highwater.exs docs/superpowers/specs/2026-06-08-clamp-before-materialize-design.md docs/superpowers/specs/2026-06-08-oversized-buffer-materialization-benchmark-design.md
git commit -m "bench(#164): probe cover + canvas over-cap fusion; record memory-win coverage"
```

---

### Task 4: Conformance doc — processing-pipeline stage/order note

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (the host result-dimension cap row, ~113; the `fixSize` row, ~91 — find by searching for "result" / "fixSize")

- [ ] **Step 1: Append the realization-order note (no emoji flip, no surface-table change)**

Find the host-result-cap row and append, after its existing composition-divergence sentence:

> On the plain (non-oriented) path the clamp runs on the lazy composite before the delivery-backstop materialization, so libvips fuses resize→clamp and the oversized intermediate never fully forms (#164, approach A); served pixels, dims, and the `[:output, :clamp]` event are byte-/metadata-identical. The oriented mid-chain flush still materializes pre-clamp (deferred).

Do **not** change any emoji, add a "Diverges" entry, or touch the surface/option tables. **Do not edit `docs/telemetry.md`** — the `[:output, :clamp]` `source_dimensions`/`dimensions`/`scale` contract is unchanged.

- [ ] **Step 2: Verify formatting + nothing else regressed**

Run: `mise exec -- mix test`
Expected: PASS (docs-only change; confirms no compat-doc test asserts on the changed text in a brittle way).

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(#164): imgproxy support matrix stage/order note for clamp-before-materialize"
```

---

### Task 5: Gate + finish

- [ ] **Step 1: Run the full Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green. Fix any formatting/credo findings and re-run.

- [ ] **Step 2: Final parallel review on the assembled diff** (per CLAUDE.md — disjoint reviewers incl. an imgproxy-compat lens confirming no observable change). Apply accepted feedback.

- [ ] **Step 3: Post the deferred-B note on #164** (outward — confirm with the user first): a comment recording the quorum decision (A implemented; B = narrow fold deferred, revisit on profiling; C rejected), linking the benchmark + decision doc.

- [ ] **Step 4: Name the branch, push, open the PR** (the branch is currently `bench/orientation-flush-memory-164` — rename to something like `feat/164-clamp-before-materialize` if desired), and handle PR review.

---

## Self-review notes

- **Spec coverage:** reorder (T2) ✓; shared `materialize_for_delivery` + error mapping + injectable materializer (T1/T2) ✓; `process_source` contract preserved (T2 step 4) ✓; drop `source_response` + scrub moduledocs (T1) ✓; cover/canvas memory-win probes (T3) ✓; conformance stage/order note + telemetry-unchanged (T4) ✓; byte-identity + 415 guards (T2 steps 6-7) ✓; oriented + double-resample deferred (spec, untouched here) ✓.
- **Error contract:** the one real hazard — a materialize failure must stay `{:decode,_}`→415, never `{:encode,_}`→500. `materialize_for_delivery` returns the tuple (no raise); the producer propagates it; the `FailingMaterializer` tests pin it (T2 step 6). Do not route the producer materialize through the `rescue` in `with_stream_translation` (that would tag `{:encode,_}`).
- **No new boundary crossing:** clamp + materialize call stay in the producer (`Request` boundary calling `Output`/`Processor`); `transform` is untouched.
