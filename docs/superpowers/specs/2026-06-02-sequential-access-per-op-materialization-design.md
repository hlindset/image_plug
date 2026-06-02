# Per-Op Materialization: Sequential-Access Parity with imgproxy

**Issue:** #143 (gap 3 — sequential-access coverage)
**Date:** 2026-06-02

## Background

ImagePipe currently decides access mode once at load time: `DecodePlanner` scans the
full operation chain, and if any operation is classified `:random`, the image is opened
with `VIPS_ACCESS_RANDOM`. A single "random" op in the chain forces the entire decode
into RAM from the start.

imgproxy takes a different approach: it always opens images with `VIPS_ACCESS_SEQUENTIAL`
and calls `vips_image_copy_memory()` just before any operation that genuinely requires
random pixel access. Every other operation streams lazily through libvips's demand-driven
pipeline without ever materialising to RAM.

Investigation of imgproxy's source confirmed that most operations we currently classify
as `:random` do not actually need random access:

- `vips_embed` (canvas, padding) — sequential-safe
- `vips_flatten` (background) — sequential-safe
- `vips_extract_area` (fixed-gravity crop) — sequential-safe
- `vips_resize` (all modes including fill/cover) — sequential-safe
- `vips_gaussblur`, `vips_sharpen` — sequential-safe; imgproxy's `CopyMemory` before
  filters was for a preceding `RgbColourspace` call, not the filter ops themselves
- Point/convolution colour ops (brightness, contrast, saturation, monochrome, duotone,
  pixelate) — sequential-safe
- `vips_flip(HORIZONTAL)` — sequential-safe; libvips source confirms it reads the same
  rows as the output strip (row order is preserved, only x is mirrored)

Ops that genuinely need random access:
- `vips_rot` (90°, 180°, 270°) — axis transpose or row-order reversal
- `vips_flip(VERTICAL)` / `vips_flip(BOTH)` — reads rows in reverse order; libvips
  raises "VipsSequential: non-sequential read" if given a sequential source
- Smart/object-detect crop — needs arbitrary pixel access for the attention model

Additionally, the between-pipeline forced `copy_memory` in `Request.Processor` was a
workaround for `DecodePlanner` only analysing the first pipeline. With per-op
materialisation, that workaround is no longer needed.

## Goal

Replace the binary load-time access decision with always-sequential loading and
inline per-op materialisation. Each transform operation declares whether it needs a
RAM-resident image before it runs. The chain executor materialises exactly once when
the first declaring op is reached; subsequent ops in all pipelines work on the already
materialized image without redundant copies.

## Design

### 1. `Transform.State` — new `materialized?` field

```elixir
defstruct [
  ...,
  materialized?: false
]
```

Set to `true` after the first successful `copy_memory`. Lets the chain executor skip
redundant materialisation for later ops in the same pipeline chain.

### 2. `Transform` behaviour — new optional callback

```elixir
@callback requires_materialization?(operation()) :: boolean()
```

Declared as `@optional_callbacks [requires_materialization?: 1]`. A default
implementation returning `false` is injected via `defmacro __using__` (with
`defoverridable`), so only the five ops that need materialization need to override it.
Operation modules that don't `use ImagePipe.Transform` must add the clause explicitly.
The Transform facade must not use `function_exported?` as a fallback — that is a
duck-typing probe, which the codebase guidelines prohibit.

`Transform.requires_materialization?/1` dispatches to the operation module:

```elixir
def requires_materialization?(%module{} = operation) do
  module.requires_materialization?(operation)
end
```

### 3. `Transform.Chain` — inline materialisation

`Chain.execute/3` gains a private `maybe_materialize/2` helper. Called before each op;
is a no-op if the state is already materialised or the op doesn't need it.

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

`Chain` already depends on `Transform`; calling `Materializer` is a new intra-boundary
dep (both are under `ImagePipe.Transform`), which is permitted. `Materializer` does not
call back into `Transform` or `Chain`, keeping the dependency graph acyclic.

### 4. `Transform.Materializer` — simplified

`materialize/1` becomes the single public entry point (the `State`-level variant):

```elixir
@spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
def materialize(%State{} = state) do
  case VipsImage.copy_memory(state.image) do
    {:ok, image} -> {:ok, %{state | image: image, materialized?: true}}
    {:error, _} = error -> error
  end
end
```

The `@callback materialize(State.t(), keyword())` for the injectable test double
(`image_materializer` opt) is retained for `Request.Processor`'s delivery materialisation.
That site passes opts so its signature stays as-is; the new `Chain`-internal
`maybe_materialize` calls `Materializer.materialize/1` (no opts) directly.

### 5. `Transform.DecodePlanner` — access mode always `:sequential`

`open_options/4` always includes `access: :sequential`. The binary
`access(chain)` / `resolve_access` / `access_requirement` functions are deleted.

The shrink-on-load computation (`compute_load_shrink`, `shrink_blocked_before_resize?`,
`resize_load_shrink`, etc.) is unchanged — it is orthogonal to access mode.

### 6. `Request.Processor` — remove between-pipeline forced copy; simplify delivery

**Remove:** `maybe_materialize_between_pipelines` and `materialize_between_pipelines`.
Multi-pipeline plans now rely entirely on per-op materialisation within each pipeline's
`Chain.execute` call. No forced `copy_memory` at pipeline boundaries.

**Simplify `materialize_before_delivery`:** No longer branches on `:sequential` vs
`:random`. Always runs the source-error check; only materialises if the final state is
not yet materialised (i.e. the plan was fully sequential-safe and `copy_memory` was
never triggered):

```elixir
defp materialize_before_delivery(%State{} = state, opts, source_response) do
  result =
    if state.materialized? do
      {:ok, state}
    else
      materialize_state(state, opts)
    end

  result
  |> handle_materialization_result(source_response)
end
```

`handle_materialization_result` (with `prefer_source_body_limit` /
`prefer_source_stream_error`) still wraps the result — this is now the single location
where source errors are surfaced, running unconditionally after all pipelines complete.

### 7. Per-op `requires_materialization?` declarations

| Operation module | Returns | Reason |
|---|---|---|
| `Operation.Rotate` (angle ≠ 0) | `true` | Axis transpose / row-order reversal |
| `Operation.Rotate` (angle = 0) | `false` | No-op |
| `Operation.Flip{axis: :vertical}` | `true` | Reads rows in reverse order |
| `Operation.Flip{axis: :both}` | `true` | Includes vertical component |
| `Operation.Flip{axis: :horizontal}` | `false` | Same rows, x mirrored — confirmed by libvips flip.c |
| `Operation.Crop` (smart/detect gravity) | `true` | Attention model needs arbitrary access |
| `Operation.Crop` (anchor gravity) | `false` | `vips_extract_area` is sequential-safe |
| All other operations | `false` (default) | Sequential-safe per imgproxy source analysis |

`Operation.Crop` pattern-matches on its gravity field:

```elixir
def requires_materialization?(%Crop{gravity: :smart}), do: true
def requires_materialization?(%Crop{gravity: {:smart, _}}), do: true
def requires_materialization?(%Crop{gravity: {:detect, _}}), do: true
def requires_materialization?(%Crop{}), do: false
```

All other operation modules that override the default do so with a single clause
returning `true` unconditionally (e.g. `Rotate` guards on `angle != 0` or just
always returns `true` and relies on the planner never emitting a 0° rotation).

## Testing strategy

### Layer 1 — Per-op sequential-vs-random equivalence tests

New file: `test/image_pipe/transform/sequential_access_test.exs`

For every operation declared `requires_materialization?: false`, verify that executing
it against a sequentially-opened source produces pixel-identical output to executing
it against a random-access source. Covers: `Crop` (anchor), `Resize` (fit/cover/stretch),
`ExtendCanvas`, `Padding`, `Background`, `Blur`, `Sharpen`, `Pixelate`, `Brightness`,
`Contrast`, `Saturation`, `Monochrome`, `Duotone`, `Flip{horizontal}`.

Pattern:

```elixir
defp assert_sequential_matches_random(op, image_binary) do
  {:ok, seq_img} = open(image_binary, access: :sequential)
  {:ok, rnd_img} = open(image_binary, access: :random)
  {:ok, seq_state} = Transform.execute(op, state(seq_img))
  {:ok, rnd_state} = Transform.execute(op, state(rnd_img))
  assert_pixels_equal(seq_state.image, rnd_state.image)
end
```

### Layer 2 — Property tests over geometry space

Same file, using StreamData. Sequential-safety can be input-dependent (e.g. a crop
near the bottom of a tall image). Property tests generate varied sizes, anchor
positions, scale factors, and sigma values for each recategorised op:

- `Crop` (anchor): varied crop dimensions and anchor positions
- `Resize` (all modes): varied source and target dimensions
- `ExtendCanvas` / `Padding`: varied extent values
- `Blur` / `Sharpen`: varied sigma values
- `Flip{horizontal}`: varied image sizes including non-square

### Layer 3 — Chain materialisation behaviour tests

Additions to `test/image_pipe/transform/chain_test.exs`:

- A `requires_materialization?: true` op triggers exactly one `Materializer.materialize/1`
  call
- A second `requires_materialization?: true` op in the same chain does **not** trigger a
  second materialisation (`state.materialized?` is already `true`)
- A fully sequential-safe chain never calls `Materializer.materialize/1`
- `state.materialized?` is `false` on entry, `true` after the first materialisation

Use a stub materialiser (injectable via opts) to observe call counts without needing
real images.

### Layer 4 — Wire conformance additions

Additions to `test/image_pipe/imgproxy_wire_conformance_test.exs` for chains that are
now fully sequential (previously forced random by a single op):

- Anchor crop + blur (previously random due to blur)
- Resize cover + canvas + padding + background (all sequential)
- Transparent source + blur + background (exercises the tail-order path sequentially)

Assert on decoded output dimensions and representative pixel properties — not
byte-identical output, but sufficient to confirm the sequential path is correct.

### What we do not write

- Tests for `requires_materialization?: true` ops — correctness is guaranteed by always
  materialising before them
- Memory high-water benchmarks — deferred to a follow-up

## What changes and what doesn't

| Component | Change |
|---|---|
| `Transform.State` | Add `materialized?: false` field |
| `Transform` behaviour | Add optional `requires_materialization?/1` callback |
| `Transform` facade | Add `requires_materialization?/1` dispatch function |
| `Transform.Chain` | Add `maybe_materialize/2` private helper; call it before each op |
| `Transform.Materializer` | Simplify `materialize/1` to set `materialized?` flag; no new public API |
| `Transform.DecodePlanner` | Delete binary access decision; always return `access: :sequential` |
| `Request.Processor` | Remove between-pipeline forced copy; simplify delivery materialisation |
| Operation modules (5) | Add `requires_materialization?/1` returning `true` |
| Operation modules (rest) | Inherit default `false` — no change needed |
| Shrink-on-load logic | Unchanged |
| Plan/Parser modules | Unchanged |
| Cache/Output/Source | Unchanged |
