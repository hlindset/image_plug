# Per-Op Materialization: Sequential-Access Parity with imgproxy

**Issue:** #143 (gap 3 — sequential-access coverage)
**Date:** 2026-06-02
**Status:** reviewed (parallel subagent review applied 2026-06-02)

## Background

ImagePipe currently decides access mode once at load time: `DecodePlanner` scans the
full operation chain, and if any operation is classified `:random`, the image is opened
with `VIPS_ACCESS_RANDOM`. A single "random" op in the chain forces the entire decode
into RAM from the start.

imgproxy takes a different approach: it always opens images with `VIPS_ACCESS_SEQUENTIAL`
and calls `vips_image_copy_memory()` just before any operation that genuinely requires
random pixel access. Every other operation streams lazily through libvips's demand-driven
pipeline without ever materialising to RAM.

### What imgproxy's source proves — and what it doesn't

Reading imgproxy's `mainPipeline` (`processing/processing.go`) and every `CopyMemory`
call site gives us **positive evidence** for some ops and **no evidence** for others.
The distinction matters: imgproxy not materialising before an op is real evidence it
streams; imgproxy *always* materialising before an op tells us nothing about whether it
*could* stream.

**Positive evidence — imgproxy streams these from a sequential source (no `CopyMemory`):**

- `vips_extract_area` (fixed-gravity/anchor crop) — `crop.go:29-30`, only the smart-gravity
  branch copies (`crop.go:22-26`)
- `vips_resize` (all modes) — `scale.go` calls no `CopyMemory`. ImagePipe's "cover" mode
  decomposes into a fill-style resize followed by a separate anchor `Crop`; imgproxy does
  the same (`scale` then `cropToResult`, both copy-free), so the trailing crop is an
  ordinary sequential-safe `vips_extract_area` and does not change the story
- `vips_embed` (canvas, padding) — `extend.go:19`, `padding.go:17-22`
- `vips_flatten` (background) — `flatten.go:8`

**No evidence either way — imgproxy *always* materialises before these:**

- `vips_gaussblur`, `vips_sharpen`, pixelate — `apply_filters.go` calls `CopyMemory`
  *before* (line 12) and *after* (line 24) the filters, so imgproxy never runs them on a
  streaming source. This neither proves nor disproves sequential-safety. We classify them
  sequential-safe on the basis of libvips's demand-driven convolution model (gaussblur and
  sharpen are area operations with a bounded vertical window; libvips inserts its own
  sequential line cache where needed) **and gate that classification on the Layer 1/2
  equivalence + property tests below** — not on imgproxy.
- All flips — `rotate_and_flip.go:16` does one `CopyMemory` up front, then runs EXIF flip,
  horizontal flip, and vertical flip on the resident image. imgproxy is silent on whether
  a horizontal flip alone could stream.

**Ops that genuinely need random access:**

- `vips_rot` (90°, 270°) — axis transpose; imgproxy materialises (`rotate_and_flip.go:16`)
- `vips_flip(VERTICAL)` / `vips_flip(BOTH)` — reads rows in reverse order; libvips raises
  `"VipsSequential: non-sequential read"` if given a sequential source
- Smart/object-detect crop — needs arbitrary pixel access for the attention model
  (`crop.go:22-26`)

### Horizontal flip

`vips_flip(HORIZONTAL)` mirrors pixels within each row and preserves row order, so a
top-to-bottom sequential reader is satisfied; `VERTICAL`/`BOTH` reverse row order and need
random access. This is the expected behaviour from libvips flip semantics, but the author
did not read libvips source directly and imgproxy is silent (it materialises before all
flips). Horizontal flip is therefore classified sequential-safe **provisionally, gated on
its Layer 1/2 tests** — not asserted as proven.

### Between-pipeline materialisation workaround

The between-pipeline forced `copy_memory` in `Request.Processor` exists because
`DecodePlanner` only analyses the *first* pipeline; a random-access op in pipeline 2+ would
otherwise run against a sequentially-loaded image. With per-op materialisation, every
random-access op self-materialises inline in any pipeline, so this workaround is removed.

## Goal

Replace the binary load-time access decision with always-sequential loading and inline
per-op materialisation. Each transform operation declares whether it needs a RAM-resident
image before it runs. The chain executor materialises exactly once when the first declaring
op is reached; subsequent ops in all pipelines work on the already-materialised image
without redundant copies.

## Design

### 1. `Transform.State` — new `materialized?` field

```elixir
defstruct [
  ...,
  materialized?: false
]
```

Set to `true` after the first successful `copy_memory`. Lets the chain executor skip
redundant materialisation for later ops in the same chain and across pipelines.

### 2. `Transform` behaviour — required callback via `use`

Add the callback to the behaviour:

```elixir
@callback requires_materialization?(operation()) :: boolean()
```

**Mechanism (corrected after review).** No operation module currently uses
`use ImagePipe.Transform` — all 17 ops declare `@behaviour ImagePipe.Transform` directly,
and `ImagePipe.Transform` defines no `__using__` macro. An `@optional_callbacks` default
would therefore reach zero modules and the facade dispatch would raise
`UndefinedFunctionError`. Using `function_exported?` as a fallback is prohibited by the
codebase guidelines (duck-typing probe).

Resolution: add a `__using__` macro to `ImagePipe.Transform` and convert all 17 operation
modules from `@behaviour ImagePipe.Transform` to `use ImagePipe.Transform`:

```elixir
defmacro __using__(_opts) do
  quote do
    @behaviour ImagePipe.Transform

    @impl ImagePipe.Transform
    def requires_materialization?(_operation), do: false

    defoverridable requires_materialization?: 1
  end
end
```

The 17 ops swap one line (`@behaviour` → `use`); their existing `@impl`-annotated `name/1`
and `execute/2` are unaffected. Only the five ops that need `true` add an overriding
clause. The facade dispatches directly — every module now defines the function:

```elixir
def requires_materialization?(%module{} = operation) do
  module.requires_materialization?(operation)
end
```

### 3. `Transform.Chain` — inline materialisation

`Chain.execute/3` gains a private `maybe_materialize/2` helper, called before each op;
a no-op if the state is already materialised or the op doesn't need it.

```elixir
defp maybe_materialize(%State{materialized?: true} = state, _op), do: {:ok, state}
defp maybe_materialize(%State{} = state, operation) do
  if Transform.requires_materialization?(operation) do
    Materializer.materialize(state)
  else
    {:ok, state}
  end
end
```

`Chain.execute/3` calls this before `Transform.execute/2` for each operation:

```elixir
Enum.reduce_while(chain_with_index, {:ok, state}, fn {operation, index}, {:ok, state} ->
  with {:ok, state} <- maybe_materialize(state, operation) do
    # ... existing telemetry span + Transform.execute call ...
  end
end)
```

`Chain` already depends on `Transform`; adding a `Materializer` call is intra-boundary
(both under `ImagePipe.Transform`). `Materializer` references only `State` and `Vix` —
it does not call `Transform` or `Chain`, so no dependency cycle is introduced.

### 4. `Transform.Materializer` — State-level `materialize/1`

The current module has a `materialize/1` taking a `%VipsImage{}` and a `materialize/2`
callback (`State`, opts) whose body delegates via `materialize(state.image)`. The new
design replaces the `VipsImage` `materialize/1` with a `State` `materialize/1` that sets
the `materialized?` flag:

```elixir
@spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
def materialize(%State{} = state) do
  case VipsImage.copy_memory(state.image) do
    {:ok, image} -> {:ok, %{state | image: image, materialized?: true}}
    {:error, _} = error -> error
  end
end
```

The `@callback materialize(State.t(), keyword())` (arity 2) is retained for
`Request.Processor`'s injectable delivery materialiser (`image_materializer` opt). **Its
body must be rewritten** — it can no longer call the removed `VipsImage` `materialize/1`;
it sets the flag the same way (or delegates to the new `materialize/1`). The arity-1 form
(State) and arity-2 callback (State + opts) do not collide.

`Chain.maybe_materialize` calls `Materializer.materialize/1` directly, with no opts — it
does **not** use the injectable `image_materializer`. Chain materialisation behaviour is
therefore verified by observable `materialized?`/pixel outcomes, not by injecting a stub
(see Testing, Layer 3).

### 5. `Transform.DecodePlanner` — access mode always `:sequential`

`open_options/4` always includes `access: :sequential`. The binary `access(chain)` /
`resolve_access` / `access_requirement` functions are deleted.

The shrink-on-load computation (`compute_load_shrink`, `shrink_blocked_before_resize?`,
`resize_load_shrink`, etc.) is unchanged — it is orthogonal to access mode.

The module doc and any comments describing the binary access decision must be updated in
the same change (per the project's keep-docs-in-sync discipline).

### 6. `Request.Processor` — remove between-pipeline copy; simplify delivery

**Remove** `maybe_materialize_between_pipelines` and `materialize_between_pipelines`.
Multi-pipeline plans rely on per-op materialisation within each pipeline's `Chain.execute`.
The state threads through `execute_plan_pipelines` (one `%State{}` carried pipeline to
pipeline), so once pipeline 1 sets `materialized?: true`, pipeline 2 short-circuits. The
source image is opened exactly once in `decode_validate_source_response` and carried in
`State.image` — a later pipeline never needs a fresh sequential stream.

**Simplify `materialize_before_delivery`:** drop the `decode_options` parameter and the
`:sequential`/`:random` branch (the planner now always returns `:sequential`). Always run
the source-error check; materialise only if the final state is not yet materialised:

```elixir
defp materialize_before_delivery(%State{} = state, opts, source_response) do
  result =
    if state.materialized? do
      {:ok, state}
    else
      materialize_state(state, opts)
    end

  handle_materialization_result(result, source_response)
end
```

`handle_materialization_result` (`prefer_source_body_limit` / `prefer_source_stream_error`)
remains the single place source errors are surfaced, now running unconditionally after all
pipelines. `decode_options` is still consumed independently at decode time (shrink, decode
metadata) — only its use in the *delivery* call is removed.

The `Materializer` moduledoc currently describes "decode planning uses only the first
pipeline" and "materialize between pipelines"; update it to describe per-op materialisation.

### 7. Per-op `requires_materialization?` declarations

| Operation module | Returns | Reason |
|---|---|---|
| `Operation.Rotate` | `true` | Axis transpose / row-order reversal (planner never emits 0°) |
| `Operation.Flip{axis: :vertical}` | `true` | Reads rows in reverse order |
| `Operation.Flip{axis: :both}` | `true` | Includes vertical component |
| `Operation.Flip{axis: :horizontal}` | `false` (provisional) | Same rows, x mirrored — gated on Layer 1/2 |
| `Operation.Crop` (smart/detect gravity) | `true` | Attention model needs arbitrary access |
| `Operation.Crop` (anchor/focal gravity) | `false` | `vips_extract_area` is sequential-safe |
| `Operation.AutoOrient` | see below | EXIF orientation may imply a quarter turn |
| All other operations | `false` (default) | See Background for per-op basis |

`Operation.Crop` pattern-matches on its gravity field (the executable gravity shapes
`PlanExecutor` produces are `{:anchor,_,_}`, `{:fp,_,_}`, `:smart`, `{:smart, :face_assist}`,
`{:detect, {spec, weights}}`):

```elixir
def requires_materialization?(%Crop{gravity: :smart}), do: true
def requires_materialization?(%Crop{gravity: {:smart, _}}), do: true
def requires_materialization?(%Crop{gravity: {:detect, _}}), do: true
def requires_materialization?(%Crop{}), do: false
```

`Operation.Rotate` always returns `true` (the planner never emits a 0° rotate —
`plan_builder` drops `rotate: 0`).

#### AutoOrient — open structural question (must resolve during implementation)

`AutoOrient.execute` calls `Image.autorotate/1`, which for EXIF orientations 5/6/7/8
performs a **90°/270° rotation** — the same axis transpose that makes manual `Rotate{90}`
require materialisation (the op's own `sync_source_dimensions` comment acknowledges the
swap). The current `DecodePlanner` already classifies `AutoOrient` as `:sequential`, but
under the old binary model that classification was rarely exercised in isolation (any other
random op forced the whole chain random). The new model **newly exercises** AutoOrient-only
sequential chains.

Two structural facts make this the riskiest op:

1. `requires_materialization?(operation)` sees only the **op struct**, not the image. An
   AutoOrient's need depends on the image's EXIF header, which is not in the struct. The
   per-op model cannot conditionally materialise "only when EXIF ∈ {5,6,7,8}".
2. So the choice is binary: either libvips `vips_autorot` is sequential-safe for
   quarter-turn EXIF (in which case `AutoOrient` stays `false`), or it is not (in which
   case `AutoOrient` must return `true` unconditionally — conservatively materialising even
   for non-rotating EXIF, since the struct can't distinguish).

Resolution gate: a dedicated equivalence test using EXIF 5/6/7/8 fixtures (the conformance
suite already has an orientation-6 `ExifOrientationOriginImage`), opened from a genuinely
streamed source with `fail_on: :error`. If sequential autorot raises or diverges on any
quarter-turn orientation, `AutoOrient` returns `true`. This must be settled before the
classification ships; the spec does not assume the favourable outcome.

## Testing strategy

### Layer 1 — Per-op sequential-vs-random equivalence tests

New file: `test/image_pipe/transform/sequential_access_test.exs`

For every operation declared `requires_materialization?: false`, verify that executing it
against a sequentially-opened source produces pixel-identical output to executing it against
a random-access source.

**Critical: the source must genuinely stream.** Opening from an in-memory binary via
`Image.from_binary/2` strips `:access` (the processor documents this) and libvips buffers
regardless — making the comparison a tautology that passes even for a mis-categorised op.
The test must mirror the deleted `sequential_compatibility_test.exs` mechanics: open from a
**stream / seekable loader** with `access: :sequential` and `fail_on: :error`, using real
image fixtures (JPEG/PNG, including an alpha PNG). `fail_on: :error` is what turns a bad
sequential read into a hard failure (failure mode 1); the pixel comparison catches silent
wrong pixels (failure mode 3). The spec requires the helper to assert the chosen loader
actually honours `access: :sequential` (e.g. by confirming a known-random op like
`Rotate{90}` *raises* under the same harness).

Covers: `Crop` (anchor/focal), `Resize` (fit/cover/stretch), `ExtendCanvas`, `Padding`,
`Background`, `Blur`, `Sharpen`, `Pixelate`, `Brightness`, `Contrast`, `Saturation`,
`Monochrome`, `Duotone`, `Flip{horizontal}`, and `AutoOrient` (with EXIF 5/6/7/8 fixtures —
see the AutoOrient gate above).

These tests construct `ImagePipe.Transform.Operation.*` structs directly (e.g. `%Crop{}`,
`%Blur{}`). This is the sanctioned convention, not impossible-internal-misuse: these are
exactly the executable structs `PlanExecutor` produces and feeds to `Chain` in real flows,
and the existing `ImagePipe.Transform.ChainTest` already builds them this way.

### Layer 2 — Property tests over geometry space

Same file, using StreamData. Sequential-safety can be input-dependent (e.g. a crop near the
bottom of a tall image, or a particular orientation). Same streaming harness as Layer 1.

- `Crop` (anchor): varied crop dimensions and anchor positions
- `Resize` (all modes): varied source and target dimensions
- `ExtendCanvas` / `Padding`: varied extent values
- `Blur` / `Sharpen`: varied sigma values (the real gate for the filter ops, since imgproxy
  provides no evidence)
- `Flip{horizontal}`: varied image sizes including non-square
- `AutoOrient`: varied EXIF orientations including the quarter-turn set

### Layer 3 — Chain materialisation behaviour tests

Additions to the existing `ImagePipe.Transform.ChainTest` at `test/transform_chain_test.exs`
(note: there is no `test/image_pipe/transform/chain_test.exs`; the real file is at the
top-level `test/` path).

Assert on the **observable contract**, not call counts via an injected stub (the spec's
Chain design calls `Materializer.materialize/1` directly with no injection point):

- `state.materialized?` is `false` on entry
- after a chain containing one `requires_materialization?: true` op, `state.materialized?`
  is `true` and pixels/dimensions are correct
- a chain with a second `true` op still produces correct output (idempotent — the
  short-circuit means no double copy; verified by output correctness, not a counter)
- a fully sequential-safe chain leaves `materialized?` `false`

### Layer 4 — Wire conformance additions

Additions to `test/image_pipe/imgproxy_wire_conformance_test.exs` for chains now fully
sequential (previously forced random by a single op):

- Anchor crop + blur (previously random due to blur)
- Resize cover + canvas + padding + background (all sequential)
- Transparent source + blur + background (exercises the tail-order path sequentially)

Assert on decoded output dimensions and representative pixel properties — not byte-identical
output, but enough to confirm the sequential path is correct.

### Delivery-path test

Add a test asserting that a fully sequential-safe single-pipeline plan (so
`materialized? == false` at delivery) still routes through `handle_materialization_result`
and surfaces a late source-stream error (body-too-large / stream failure). This path's
error-surfacing shape changes under §6 and is the one most likely to regress.

### What we do not write

- Tests for `requires_materialization?: true` ops — correctness is guaranteed by always
  materialising before them. (Their *correct categorisation* is what Layer 1/2 protect, but
  only because the streaming harness genuinely raises on a mis-categorised `false`.)

### Residual risk — memory benchmark deferred (explicit)

The memory high-water benchmark is **deferred by deliberate decision**, but it is the only
check for failure mode 2 (silent buffering): an op can be classified `false`, pass every
Layer 1–4 correctness test, and still silently insert a line/tile cache — correct output,
no memory win. Until the benchmark lands, "fully sequential / no materialisation" is an
**unverified performance claim**: a recategorisation could regress to silent buffering with
no test going red. Tracked as a follow-up; not a blocker for the correctness work.

## What changes and what doesn't

| Component | Change |
|---|---|
| `Transform.State` | Add `materialized?: false` field |
| `Transform` behaviour | Add `requires_materialization?/1` callback + `__using__` macro with default |
| `Transform` facade | Add `requires_materialization?/1` dispatch function |
| Operation modules (all 17) | Swap `@behaviour ImagePipe.Transform` → `use ImagePipe.Transform` |
| Operation modules (5) | Add overriding `requires_materialization?/1` returning `true` |
| `Transform.Chain` | Add `maybe_materialize/2`; call before each op |
| `Transform.Materializer` | Replace VipsImage `materialize/1` with State `materialize/1` setting the flag; rewrite arity-2 body; update moduledoc |
| `Transform.DecodePlanner` | Delete binary access decision; always `access: :sequential`; update doc |
| `Request.Processor` | Remove between-pipeline copy; simplify delivery materialisation |
| Shrink-on-load logic | Unchanged |
| Plan/Parser/Cache/Output/Source | Unchanged |
| `architecture_boundary_test.exs` | No change (all new dispatch is intra-transform-boundary) |
