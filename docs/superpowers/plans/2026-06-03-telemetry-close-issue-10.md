# Close Telemetry Issue #10 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the remaining stage/metadata/doc/test gaps on [issue #10](https://github.com/hlindset/image_pipe/issues/10) so telemetry meets its acceptance criteria without adding new spans.

**Architecture:** The span surface is already complete (request, parse, source resolve/fetch/fetch_decode, transform execute + per-operation, output negotiate, encode, send, cache, http_cache, detect). Per the chosen design, decode + input-pixel validation + body-size limiting stay **folded** into `[:source, :fetch_decode]` rather than getting distinct timing spans — a separate `[:decode]` span would measure libvips *lazy construction*, not pixel work (real decode cost lands in transform/encode), repeating the dishonesty the project already rejects for per-op spans. So the only code change is one missing runtime-metadata field the issue explicitly asks for (transform count/names) on `[:transform, :execute]`. The rest is documentation of the fold + the two already-emitted-but-undocumented request-stage events (`[:source, :fetch_decode]`, `[:transform, :operation]`), and failure-telemetry test assertions for the folded sub-stages. Cache-*lifecycle* spans (`[:cache, :admission]`, `[:cache, :warm_start]`, and the `[:cache, :eviction|:flush|:cleanup]` stop events) are also emitted-but-thinly-documented, but they're cache-maintenance background events outside issue #10's request-processing-stage scope — explicitly scoped out here and flagged as a follow-up (Task 4).

**Tech Stack:** Elixir, `:telemetry` (`:telemetry.span/3`), ExUnit, Plug.Test. Run everything through `mise exec -- ...`.

---

## Scope check

This is a single subsystem (telemetry). No split needed. Three workstreams, each independently committable:

1. **Task 1 — Metadata** (code): aggregate transform `operation_count` + `operations` on `[:transform, :execute]`.
2. **Task 2 — Tests**: failure-telemetry assertions for the folded sub-stages (body-size limit, input-pixel limit) on `[:source, :fetch_decode, :stop]`, plus the new execute metadata.
3. **Task 3 — Docs**: document `[:source, :fetch_decode]` (incl. the fold rationale), `[:transform, :operation]`, the new execute metadata, and a stage→result / error-category table in `docs/telemetry.md`.

## File structure

| File | Responsibility | Change |
|---|---|---|
| `lib/image_pipe/plan/operation.ex` | Canonical semantic-operation facade | Add `name/1` — stable atom per semantic op struct |
| `lib/image_pipe/plan.ex` | Plan query surface | Add `operation_names/1` — flatten pipelines → `[atom()]` |
| `lib/image_pipe/request/processor.ex` | Request orchestration; owns the `[:transform, :execute]` span | Enrich start metadata with `operations` + `operation_count` |
| `lib/image_pipe/telemetry/logger.ex` | Opt-in default Logger | Show operation count on the `[:transform, :execute]` line |
| `test/image_pipe/plan_test.exs` | Plan query unit tests | Test `operation_names/1` |
| `test/image_pipe/telemetry_test.exs` | Wire-level telemetry contract | Add execute-metadata + folded-failure assertions |
| `docs/telemetry.md` | Public telemetry contract | Document fold, fetch_decode, per-op span, execute metadata, result table |

**Stable names emitted** (from `Plan.Operation.name/1`, derived from each struct's module tail): `:resize`, `:crop_guided`, `:crop_region`, `:canvas`, `:padding`, `:background`, `:rotate`, `:flip`, `:blur`, `:sharpen`, `:pixelate`, `:monochrome`, `:duotone`, `:brightness`, `:contrast`, `:saturation`, `:normalize_color_profile`.

> **Two distinct vocabularies (do not conflate).** The aggregate `[:transform, :execute].operations` uses this **plan/semantic** vocabulary above. The per-operation `[:transform, :operation].operation` field uses the **executed-transform** vocabulary from `Transform.transform_name/1` — a *different* set (e.g. both `:crop_guided` and `:crop_region` execute as `:crop`; `:canvas` executes as `:extend_canvas`). They intentionally differ, and one plan op can expand into several executed transform ops, so `operation_count` (plan ops) need not equal the number of per-op spans. Task 3 documents this explicitly; the plan must not claim the two name sets "line up".

**Exact folded-failure metadata** (verified against `processor.ex` + `Error.tag/1`):
- Body-size limit → `[:source, :fetch_decode, :stop]` metadata `%{result: :source_error, error: :body_too_large}`.
- Input-pixel limit → `[:source, :fetch_decode, :stop]` metadata `%{result: :processing_error, error: :input_limit}`.

---

## Task 1: Aggregate transform metadata on `[:transform, :execute]`

The issue asks metadata to include "transform count/names". Per-op spans carry name+index, but the coarse `[:transform, :execute]` start metadata is currently `%{}` ([processor.ex:132](lib/image_pipe/request/processor.ex:132)). Add the aggregate up front (known from the plan, honest even if execution raises).

**Files:**
- Modify: `lib/image_pipe/plan/operation.ex`
- Modify: `lib/image_pipe/plan.ex`
- Modify: `lib/image_pipe/request/processor.ex:132`
- Test: `test/image_pipe/plan_test.exs`

- [ ] **Step 1: Write the failing test for `Plan.operation_names/1`**

In `test/image_pipe/plan_test.exs`, build the resize op with the **existing** `Operation.resize/4` constructor (the file already defines `resize_operation/0` at ~line 158 and a `plan/1` builder at ~line 144 — reuse that house style; do not hand-write a raw `%Operation.Resize{}` literal, which duplicates enforced keys and rots on field changes). `%Flip{}` has a single enforced key, so a literal is fine:

```elixir
describe "operation_names/1" do
  test "returns stable operation-name atoms in order across pipelines" do
    {:ok, resize} = ImagePipe.Plan.Operation.resize(:fit, {:px, 100}, :auto, enlargement: :deny)

    plan = %ImagePipe.Plan{
      pipelines: [
        %ImagePipe.Plan.Pipeline{
          operations: [resize, %ImagePipe.Plan.Operation.Flip{axis: :horizontal}]
        }
      ]
    }

    assert ImagePipe.Plan.operation_names(plan) == [:resize, :flip]
  end
end
```

> Confirm `Operation.resize/4`'s arity/return shape against the existing `resize_operation/0` helper in the file before relying on it; mirror it exactly.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs -v`
Expected: FAIL with `function ImagePipe.Plan.operation_names/1 is undefined`.

- [ ] **Step 3: Add `Plan.Operation.name/1`**

In `lib/image_pipe/plan/operation.ex`, add a public function. One derivation clause covers all 17 structs and any future op. The atom set is bounded by compile-time module names (not user input), and every derived atom already exists as a compile-time literal elsewhere in `lib/` (the 16 `invalid(:resize, …)`-style references in this module plus `:normalize_color_profile`), so `String.to_existing_atom/1` is both safe and the more defensive choice — it can never create a new atom:

```elixir
@doc """
Stable, product-neutral name atom for a semantic operation struct
(e.g. `%Operation.Resize{}` -> `:resize`). Derived from the struct module's
tail; used for telemetry metadata. Bounded by defined operation modules.
"""
@spec name(struct()) :: atom()
def name(%mod{}) when is_atom(mod) do
  mod
  |> Module.split()
  |> List.last()
  |> Macro.underscore()
  |> String.to_existing_atom()
end
```

> If a future op's underscored tail is referenced nowhere else as a literal, `String.to_existing_atom/1` will raise — that's the intended failure (add the name literal, or fall back to `String.to_atom/1` with a comment). Verified today: all 17 names pre-exist.

- [ ] **Step 4: Add `Plan.operation_names/1`**

In `lib/image_pipe/plan.ex`, add (alias `ImagePipe.Plan.Operation` is already present or add it):

```elixir
@doc """
Ordered list of semantic operation-name atoms across all pipelines.
Used as product-neutral aggregate metadata on the transform-execute span.
"""
@spec operation_names(t()) :: [atom()]
def operation_names(%__MODULE__{pipelines: pipelines}) do
  Enum.flat_map(pipelines, fn %Pipeline{operations: ops} ->
    Enum.map(ops, &Operation.name/1)
  end)
end
```

- [ ] **Step 5: Run the unit test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs -v`
Expected: PASS.

- [ ] **Step 6: Enrich the execute span start metadata**

In `lib/image_pipe/request/processor.ex`, replace the span call at line 132. Compute names from the in-scope `plan`:

```elixir
operation_names = Plan.operation_names(plan)

execute_start_meta = %{
  operations: operation_names,
  operation_count: length(operation_names)
}

Telemetry.span(Telemetry.telemetry_opts(opts), [:transform, :execute], execute_start_meta, fn ->
  result =
    with {:ok, final_state} <-
           execute_plan_pipelines(initial_state, plan, opts),
         {:ok, final_state} <-
           materialize_before_delivery(final_state, opts, source_response),
         :ok <- validate_result_image(final_state.image, opts) do
      {:ok, final_state}
    end

  {result, transform_stop_metadata(result)}
end)
```

(`Plan` is already aliased in this module. The `request` boundary already depends on `plan`, and the metadata is plain atoms — no concrete transform module is named, so the architecture boundary holds.)

- [ ] **Step 7: Run compile + focused processor/transform tests**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/plan_test.exs`
Expected: PASS, no warnings.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/plan/operation.ex lib/image_pipe/plan.ex lib/image_pipe/request/processor.ex test/image_pipe/plan_test.exs
git commit -m "feat(telemetry): add operation count/names to transform-execute span"
```

---

## Task 2: Wire-level telemetry tests for execute metadata and folded failures

Closes the "tests verify representative success and failure telemetry events" criterion for the new metadata and the folded sub-stages. Build on the existing `telemetry_test.exs` harness, verified against the file: `attach_telemetry/1` (line ~710), `telemetry_events/0` (~756), `assert_event/3` (~766, takes a 2-arity assertion), `base_opts/1` (~653, which merges overrides **before** `ImagePipe.Plug.init` — so init-time options like `:sources`, `:max_body_bytes`, `:max_input_pixels` MUST be passed as `base_opts(key: val)`, never `Keyword.put` onto the result), the `SourceBytes` adapter (~120), and the `stages/0` event list (~741).

**Files:**
- Test: `test/image_pipe/telemetry_test.exs`

- [ ] **Step 0 (MANDATORY — do first): register the `[:source, :fetch_decode]` stage so the harness attaches it**

The shared `stages/0` list (~line 741) drives `default_events/0` + `custom_events/0`. It does **not** currently include `[:source, :fetch_decode]`, so without this the failure assertions in Steps 3 & 5 silently `flunk` ("expected telemetry event … got …"). Add the stage:

```elixir
defp stages do
  [
    [:request],
    [:parse],
    [:source, :resolve],
    [:cache, :lookup],
    [:output, :negotiate],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:encode],
    [:cache, :write],
    [:send]
  ]
end
```

Run `mise exec -- mix test test/image_pipe/telemetry_test.exs` afterward to confirm the existing success test ("emits request and representative stage spans") still passes with the extra stage attached.

- [ ] **Step 1: Write the failing test for execute aggregate metadata**

Add inside `ImagePipe.TelemetryTest`:

```elixir
test "transform execute span carries operation count and names" do
  conn =
    :get
    |> conn("/_/rs:fit:100:0/f:jpeg/plain/images/beach.jpg")
    |> ImagePipe.Plug.call(base_opts())

  assert conn.status == 200
  events = telemetry_events()

  assert_event(events, [:image_pipe, :transform, :execute, :start], fn _measurements, metadata ->
    assert is_list(metadata.operations)
    assert :resize in metadata.operations
    assert metadata.operation_count == length(metadata.operations)
  end)
end
```

> Path verified: `rs:fit:100:0` parses to a `:resize` op under the imgproxy parser (`option_grammar.ex` maps `rs`, `0` height → `:auto`; corroborated by the `rs:fill:640:360:0` path in `simple_server_test.exs`). Assert only on `:resize` — it is identical in both the plan and executed-transform vocabularies, so the test stays valid regardless of the per-op/aggregate naming split.

- [ ] **Step 2: Run it to verify it passes (metadata already added in Task 1)**

Run: `mise exec -- mix test test/image_pipe/telemetry_test.exs -v`
Expected: PASS (this guards Task 1's change at the wire level).

- [ ] **Step 3: Write the failing test for body-size-limit telemetry**

Use the existing `SourceBytes` adapter, which **supplies the response bytes from its `body:` option and ignores the URL path** — so the path is only a parse target, not a filesystem fixture (`images/source.tiff` does not exist on disk, and that's fine). The body-size limit trips during fetch, before any decode, so no TIFF support is needed. Pass init-time options through `base_opts/1`, mirroring the existing `base_opts(sources: …)` usage at telemetry_test.exs:~410:

```elixir
test "fetch_decode stop metadata reports source_error for body-size limit" do
  big_body = :binary.copy(<<0>>, 50_000)

  opts =
    base_opts(
      sources: [path: {SourceBytes, body: big_body}],
      max_body_bytes: 1_000
    )

  # SourceBytes returns `big_body` regardless of this path; the path only has to parse.
  conn =
    :get
    |> conn("/_/plain/images/source.tiff")
    |> ImagePipe.Plug.call(opts)

  refute conn.status == 200
  events = telemetry_events()

  assert_event(events, [:image_pipe, :source, :fetch_decode, :stop], fn _measurements, metadata ->
    assert metadata.result == :source_error
    assert metadata.error == :body_too_large
  end)
end
```

> Default parser stays imgproxy (set by `opts/1`); no need to re-specify `:parser`. The `[:source, :fetch_decode]` stage must already be registered (Step 0).

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Write the failing test for input-pixel-limit telemetry**

Drive a real image (`beach.jpg`, served by the default `Source.File` root `priv/static`) with `:max_input_pixels` below its pixel count. Pass it through `base_opts/1`, not post-init `Keyword.put`:

```elixir
test "fetch_decode stop metadata reports processing_error for input-pixel limit" do
  opts = base_opts(max_input_pixels: 1)

  conn =
    :get
    |> conn("/_/f:jpeg/plain/images/beach.jpg")
    |> ImagePipe.Plug.call(opts)

  refute conn.status == 200
  events = telemetry_events()

  assert_event(events, [:image_pipe, :source, :fetch_decode, :stop], fn _measurements, metadata ->
    assert metadata.result == :processing_error
    assert metadata.error == :input_limit
  end)
end
```

- [ ] **Step 6: Run it to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry_test.exs -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add test/image_pipe/telemetry_test.exs
git commit -m "test(telemetry): cover execute metadata and folded fetch_decode failures"
```

---

## Task 3: Document the fold, the two undocumented events, and result categories

`docs/telemetry.md` lists `[:source, :fetch]` but never mentions the wrapping `[:source, :fetch_decode]` span or the per-op `[:transform, :operation]` span, and doesn't explain that decode/validation/body-limit are folded or enumerate which error categories appear where.

**Files:**
- Modify: `docs/telemetry.md`
- Modify: `lib/image_pipe/telemetry/logger.ex` (one message line)

- [ ] **Step 1: Add the `[:source, :fetch_decode]` section to docs/telemetry.md**

After the "Event names" stage list (around line 62), add a subsection:

````markdown
### Source fetch + decode (`[:source, :fetch_decode]`)

`[:image_pipe, :source, :fetch_decode]` wraps source fetch **and** image decode
as one span. By deliberate design it also folds in the two input guards that run
during decode — input-pixel-count validation and source body-size limiting —
rather than emitting separate spans for them.

This fold is intentional. libvips is lazy: a standalone `[:decode]` span would
time loader *construction*, not pixel work (real decode cost is realized later,
during transform materialization and encode). A separate timing span for it
would mislead, the same way per-operation durations would (see below). The
guards are likewise checks, not durationful stages. So their *outcomes* are
reported as stop metadata on this span instead of as their own spans.

The nested `[:source, :fetch]` span (source side effects only) lives inside it.

Success stop metadata:

- `:result` — `:ok`.
- `:load_option` — the shrink-on-load option chosen, `{:shrink, n}`, `{:scale, f}`, or absent when none.
- `:achieved_shrink` — `%{w: float, h: float}` realized shrink, when shrink-on-load fired.
- `:original_dims` — `{w, h}` of the stored image before decode.
- `:loaded_dims` — `{w, h}` actually decoded.

Failure stop metadata:

- Source-side failures: `result: :source_error`, `error:` a stable category atom
  (e.g. `:body_too_large` when the source body crosses `:max_body_bytes`).
- Decode / input-validation failures: `result: :processing_error`, `error:` a
  stable category atom (e.g. `:input_limit` when the decoded image exceeds
  `:max_input_pixels`, `:decode` for an undecodable body).
````

- [ ] **Step 2: Add the `[:transform, :operation]` section to docs/telemetry.md**

After the transform-execute mention, add:

````markdown
### Per-operation transform spans (`[:transform, :operation]`)

Each executed operation is wrapped in a nested
`[:image_pipe, :transform, :operation]` span, inside `[:transform, :execute]`.
Its **duration reflects pipeline construction, not pixel compute** — libvips
defers and fuses work to materialization/encode — so use it for tracing
execution *structure* (which operations ran, in what order), never as
per-operation timing. Honest aggregate timing lives on `[:transform, :execute]`.

Start metadata:

- `:operation` — the operation name atom (e.g. `:resize`, `:crop_region`).
- `:index` — zero-based position in the executed chain.
- `:params` — the full operation struct (product-neutral, derived from the
  public request).

Stop metadata: `:result` (`:ok` or `:error`).

The enclosing `[:transform, :execute]` start metadata carries the aggregate:

- `:operation_count` — number of **plan** operations.
- `:operations` — the ordered list of **plan** (semantic) operation-name atoms.

**These two name sets are deliberately different vocabularies.** The aggregate
`:operations` is the *semantic plan* view (`:crop_guided`, `:crop_region`,
`:canvas`, …). The per-op span's `:operation` is the *executed-transform* view
(`Transform.transform_name/1`), where e.g. both crop variants execute as
`:crop` and a canvas executes as `:extend_canvas`. A single plan operation can
also expand into several executed transform ops, so `:operation_count` (plan
ops) is **not** guaranteed to equal the number of `[:transform, :operation]`
spans. Treat the aggregate as "what the request asked for" and the per-op spans
as "what actually ran".
````

- [ ] **Step 3: Cross-reference stages → result categories**

In the "Result values" section (around line 122), append a stage mapping note:

```markdown
Representative stage → result mappings:

- `[:source, :fetch_decode]` → `:ok`, `:source_error` (e.g. `error: :body_too_large`),
  or `:processing_error` (e.g. `error: :input_limit`, `:decode`).
- `[:transform, :execute]` → `:ok` or `:processing_error`.
- `[:output, :negotiate]` → `:ok` or a negotiation failure category.

The `:error` field is a stable category atom (`ImagePipe.Error.tag/1`), never a
raw message or source-derived path.
```

- [ ] **Step 4: Update the attach-handlers example to include fetch_decode**

In the `@stages` list in the docs example (around line 274), add `[:source, :fetch_decode]` and `[:transform, :operation]` so the copy-paste handler covers them.

- [ ] **Step 5: Show operation count on the execute Logger line**

`[:transform, :execute]` currently has **no** specific clause — it falls through to the generic `message(suffix, _m, meta)` at [logger.ex:151](lib/image_pipe/telemetry/logger.ex:151), which prints `outcome(meta)` (i.e. the `:result`, so `processing_error` shows up on a non-raising transform failure). The new clause must **preserve that outcome** and merely append the count — dropping the outcome would regress failure visibility. Add it among the other specific clauses, **before** the generic fallback at line 151 (e.g. right after the `[:transform, :operation | _]` clause at [logger.ex:117](lib/image_pipe/telemetry/logger.ex:117)):

```elixir
defp message([:transform, :execute | _], _m, meta) do
  "image_pipe transform execute: #{outcome(meta)} (#{meta[:operation_count] || 0} ops)"
end
```

Design notes baked in:
- Shows the **count only**, not the operation names, on the aggregate line. The per-op `[:transform, :operation]` clause (line 117) already prints individual names; duplicating the semantic-vocabulary list here would both be noisy and invite confusion with the executed-transform names (see the two-vocabulary split). Operators who want the names read `:operations` from the raw metadata (`debug: true`) or their own handler.
- `outcome/1` ([logger.ex:159](lib/image_pipe/telemetry/logger.ex:159)) already returns `meta[:result] || :ok`, so success prints `ok` and failure prints the error result — no level change needed (exceptions still route through `exception_message/2`).

> Confirm the clause lands before line 151 and match the surrounding clause style exactly.

- [ ] **Step 6: Add a focused Logger test for the new execute line**

No existing test asserts the `[:transform, :execute]` message text (the per-op test at logger_test.exs:146 and the `events: [:cache]` exclusion test at :159 are unaffected — the latter still passes because the transform group isn't attached there). Add positive coverage, mirroring the existing per-op test style (`Telemetry.attach_default_logger(level: :debug)` + `capture_log`):

```elixir
test "renders the transform execute aggregate with outcome and operation count" do
  Telemetry.attach_default_logger(level: :debug)

  log =
    capture_log([level: :debug], fn ->
      :telemetry.execute(
        [:image_pipe, :transform, :execute, :stop],
        %{duration: 500},
        %{result: :ok, operations: [:resize, :flip], operation_count: 2}
      )
    end)

  assert log =~ "transform execute: ok (2 ops)"
end
```

- [ ] **Step 7: Run the Logger tests and compile**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS, no warnings.

- [ ] **Step 8: Commit**

```bash
git add docs/telemetry.md lib/image_pipe/telemetry/logger.ex test/image_pipe/telemetry/logger_test.exs
git commit -m "docs(telemetry): document fetch_decode fold, per-op span, execute metadata"
```

---

## Task 4: Verify acceptance criteria and close out

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: format clean, compile clean (warnings-as-errors), credo --strict clean, full suite green.

- [ ] **Step 2: Re-check each issue acceptance criterion**

Confirm against the codebase, not memory:
- [ ] Each major stage emits start/stop/exception — all spans present; decode/validation/body-limit folded into `[:source, :fetch_decode]` *by design*, with outcomes in metadata (documented in Task 3).
- [ ] Error events identify category without leaking source URLs — `error:` is an `Error.tag/1` atom; `refute` path-key test already in `telemetry_test.exs` still passes.
- [ ] Tests verify representative success + failure events — Task 2 adds execute-metadata + folded-failure assertions; per-op spans already tested in `transform_chain_test.exs`.
- [ ] Docs describe event names, measurements, metadata — Task 3 adds fetch_decode, per-op span, execute metadata, result table. **Scope:** this criterion is satisfied for issue #10's request-processing stages. The cache-*lifecycle* spans (`[:cache, :admission]`, `[:cache, :warm_start]`, and the `[:cache, :eviction|:flush|:cleanup]` stop events) remain thinly documented — they are cache-maintenance background events outside #10's scope and are tracked as a separate follow-up (Step 5). Do not claim `docs/telemetry.md` is exhaustively complete.

- [ ] **Step 3: Post the closing summary on the issue**

Run (adjust wording to the final diff):

```bash
gh issue comment 10 --repo hlindset/image_pipe --body "Closed the remaining gaps: added operation_count/operations metadata to [:transform, :execute]; documented the deliberate fetch_decode fold (decode + input-pixel validation + body-size limit folded, no misleading per-stage timing spans), the per-operation span, and a stage→result/error-category table; added wire-level failure-telemetry assertions for the folded sub-stages. Acceptance criteria met."
```

- [ ] **Step 4: Close the issue (or via the merging PR)**

```bash
gh issue close 10 --repo hlindset/image_pipe
```

- [ ] **Step 5: File the cache-lifecycle docs follow-up**

These spans are emitted (some wired into the default Logger group map at `logger.ex:17`) but not fully documented. Out of scope for #10; capture it so it isn't lost:

```bash
gh issue create --repo hlindset/image_pipe \
  --title "Document cache-lifecycle telemetry spans (admission, warm_start, eviction, flush, cleanup)" \
  --label "area:observability,priority:P3" \
  --body "Emitted but thinly/not documented in docs/telemetry.md: [:cache, :admission], [:cache, :warm_start], and the [:cache, :eviction|:flush|:cleanup] stop events. Add event names, measurements, and stop metadata. Split out from #10, which scoped to request-processing stages."
```

> Optional cleanup (separate, tiny): `test/parser/imgproxy_test.exs` (~line 1817) hand-maintains an `operation_name/1` helper producing the same atoms as the new `Plan.Operation.name/1`. Once this lands, that helper can delegate to it so the two don't drift — file as a NIT follow-up if desired.

---

## Self-review

- **Spec coverage:** All four acceptance criteria map to tasks (Task 1 → metadata; Task 2 → failure tests; Task 3 → docs; Task 4 → verify). The "distinct spans for decode/validation/body-limit" reading of the issue is deliberately answered with the documented fold (chosen design), not new spans.
- **Placeholder scan:** Exact emitted names, exact folded-failure metadata (`:body_too_large` / `:input_limit`), and real code blocks throughout. Two `> Note` callouts flag spots to align with existing fixtures (struct field sets, parser path spelling, `sources:` option shape) — these are alignment checks, not deferred logic.
- **Type consistency:** `Plan.Operation.name/1` (atom) → `Plan.operation_names/1` (list of atoms) → `operations`/`operation_count` start metadata → test assertions → docs are consistent *within the plan/semantic vocabulary*. This vocabulary is intentionally **distinct** from the executed-transform `:operation` on per-op spans (see the "Two distinct vocabularies" callouts); the tests assert only on `:resize`, which is identical in both, so they don't depend on the split.

## Pre-execution requirement (project guideline)

Per `CLAUDE.md`: before executing this plan, run a parallel subagent review cycle with disjoint focus areas, **including at least one reviewer checking observable compatibility against the relevant target(s)** (imgproxy above all — here that mainly means confirming the telemetry additions stay product-neutral and don't push ordered/dialect semantics into the native model). Apply accepted feedback, rerun doc checks, and commit the reviewed plan before implementation starts.
