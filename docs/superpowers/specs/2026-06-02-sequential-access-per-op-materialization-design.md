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

### Scope note: single-page only

ImagePipe has no animation/multi-frame handling — it decodes a single page (libvips default
`n=1`), so animated GIF/WebP flatten to their first frame. imgproxy's per-frame materialise +
watermark-after-`arrayjoin` model has no analog here, so the sequential-safety reasoning never
has to account for multi-page row semantics through a joined-frame image.

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

**Why "once true, true forever" is sound.** After a materialise, later ops stack lazy
`vips_rot`/`vips_flip`/resize nodes *on top of* the RAM-resident leaf; `state.image` is again
a lazy node, not itself a resident buffer. A subsequent random-access op (e.g. smart crop
after AutoOrient) still gets genuine random access, because libvips resolves any output pixel
by reading the mapped source pixel from the resident leaf — the buffer underneath satisfies
arbitrary pulls regardless of how many lazy nodes sit above it. This holds **only because no
op re-opens the source as a fresh sequential leaf** — every op derives its output from
`state.image`. That invariant is what makes the flag safe; a future op that re-opened the
source would silently break it (there is no architecture test guarding this, so keep it in
mind).

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
and `execute/2` are unaffected. Only **three modules** add an overriding clause returning
`true` — `Rotate`, `Flip`, and `Crop` (the latter two carry both `true` and `false` clauses
within one module; see §7). `AutoOrient` keeps the default `false` and self-materialises
internally. The facade dispatches directly — every module now defines the function:

```elixir
@spec requires_materialization?(operation()) :: boolean()
def requires_materialization?(%module{} = operation) do
  module.requires_materialization?(operation)
end
```

Two compile-gate notes (`mix compile --warnings-as-errors` + `credo --strict` are the
gate):

- **Override clauses carry `@impl ImagePipe.Transform`.** The `__using__` default is
  `@impl`-annotated; an overriding module replaces it via `defoverridable`, so its own
  clauses (`Rotate`/`Flip`/`Crop`) must each carry `@impl ImagePipe.Transform` too —
  mixing annotated and un-annotated clauses for one function warns. The §7 code samples
  omit the annotation for brevity; the real clauses include it.
- **Landing order is atomic where it must be.** Adding the `@callback`, the `__using__`
  macro, and converting all 17 ops from `@behaviour` to `use` must land in **one commit** —
  the new required callback has no implementers until the macro injects the default, so a
  split breaks the compile. Safe sequence: (a) `State.materialized?`; (b) callback +
  `__using__` + 17-op conversion (one commit); (c) the 3 override modules + AutoOrient
  self-materialisation; (d) facade dispatch; (e) Chain `maybe_materialize`; (f) Materializer
  rewrite; (g) DecodePlanner + Processor.

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

`maybe_materialize` runs **inside** the op's `[:transform, :operation]` telemetry span, so
the materialisation cost and any failure are attributed to the op that triggered it (and a
`copy_memory` failure surfaces through the same span as an op error). Placing it outside the
span would drop attribution for exactly the ops that pay for the copy (`Rotate`/`Flip`/
smart-`Crop`) while AutoOrient's internal copy stays visible — an avoidable asymmetry. The
result must be returned to `reduce_while` as a `{:cont, _}` / `{:halt, _}` tuple (a raw
`{:error, _}` would crash the reduce):

```elixir
Enum.reduce_while(chain_with_index, {:ok, state}, fn {operation, index}, {:ok, state} ->
  result =
    Telemetry.span(telemetry_opts, [:transform, :operation], %{operation: name, index: index, params: operation}, fn ->
      res =
        with {:ok, state} <- maybe_materialize(state, operation) do
          Transform.execute(operation, state)
        end
      {res, %{result: elem(res, 0)}}
    end)

  case result do
    {:ok, %State{} = next} -> {:cont, {:ok, next}}
    {:error, reason} -> {:halt, {:error, {:transform_error, reason}}}
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
(State) and arity-2 callback (State + opts) do not collide. The existing
`test/image_pipe/image_materializer_test.exs`, which calls the deleted `VipsImage`
`materialize/1` form directly, is **deleted** alongside the function (not kept alive to pin
a removed entry point). The arity-2 test stub at
`test/support/.../request_processor_test/materializer.ex` keeps its signature and needs no
change.

`Chain.maybe_materialize` calls `Materializer.materialize/1` directly, with no opts — it
does **not** use the injectable `image_materializer`. Chain materialisation behaviour is
therefore verified by observable `materialized?`/pixel outcomes, not by injecting a stub
(see Testing, Layer 3).

### 5. `Transform.DecodePlanner` — access mode always `:sequential`

`open_options/4` always includes `access: :sequential`. The binary `access(chain)` /
`resolve_access` / `access_requirement` functions and the now-dead `@type
access_requirement()` are deleted.

The shrink-on-load computation (`compute_load_shrink`, `shrink_blocked_before_resize?`,
`resize_load_shrink`, etc.) is unchanged — it is orthogonal to access mode.

**Behaviour change to acknowledge:** the empty chain (`access([]) -> :random` today) and a
`NormalizeColorProfile`-alone chain (`:neutral -> :random` today) flip from `:random` to
`:sequential`. End state is equivalent — an output-only request that never materialises
mid-chain now drains and materialises once at delivery (§6) instead of opening random — but
it *is* a visible change to the pinned planner values. Tests that assert the old access
values must be updated, not just the moduledoc:

- `test/image_pipe/decode_planner_test.exs` — the whole "Access selection" block (empty-chain
  `:random`, neutral-alone `:random`, composition/crop `:random` pins)
- `test/image_pipe/plug_test.exs` — "cover opens origin with random access" (~`:1858`)
- `test/image_pipe/processor_test.exs` — `decode_options == [access: :random, ...]` (~`:120`)

The module doc and comments describing the binary access decision are updated in the same
change (per the keep-docs-in-sync discipline).

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

`decode_options` is still consumed independently at decode time (shrink, decode metadata) —
only its use in the *delivery* call is removed.

The `Materializer` moduledoc currently describes "decode planning uses only the first
pipeline" and "materialize between pipelines"; update it to describe per-op materialisation.

#### Source-error surfacing needs no new wrap (verified against the code)

An earlier draft proposed wrapping pipeline execution with `prefer_source_body_limit` /
`prefer_source_stream_error` to catch mid-chain materialisation failures. That is **dead
code** and is not adopted. The source body-limit and stream-error flags are backed by
`:atomics` on a `Source.WrappedStream`, mutated *only* while that stream is enumerated.
The only enumeration is the eager `Enum.to_list` drain in `seekable_input` (HTTP/S3 stream
sources), which completes at decode time, before any transform op — already covered by the
two existing decode-time `prefer_source_*` wraps. **Path** sources carry no `WrappedStream`
(`Source.File.fetch` returns `%Response{stream: nil}`), so `body_limit_exceeded?` /
`stream_error_reason` are structural no-ops for them; a truncated/I/O-failed path read at a
mid-chain `copy_memory` is a genuine libvips decode error, correctly classified
`{:transform_error, _}` → `{:decode, _}`. There is no `{:source, _}` reclassification owed
to a path read, so no wrap is needed and a test asserting `{:source, _}` for a path source
would pin wrong behaviour. (Should a future source kind stream lazily *into* libvips at
materialisation time, the wrap becomes real — add it then, with that producer and a test,
per the codebase's add-validation-when-the-caller-appears rule.)

### 7. Per-op `requires_materialization?` declarations

| Operation module | Returns | Reason |
|---|---|---|
| `Operation.Rotate` | `true` | Axis transpose / row-order reversal (planner never emits 0°) |
| `Operation.Flip{axis: :vertical}` | `true` | Reads rows in reverse order |
| `Operation.Flip{axis: :both}` | `true` | Includes vertical component |
| `Operation.Flip{axis: :horizontal}` | `false` (provisional) | Same rows, x mirrored — gated on Layer 1/2 |
| `Operation.Crop` (smart/detect gravity) | `true` | Attention model needs arbitrary access |
| `Operation.Crop` (anchor/focal gravity) | `false` | `vips_extract_area` is sequential-safe |
| `Operation.AutoOrient` | `false` (self-manages) | Data-dependent; materialises *internally* — see below |
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

#### AutoOrient — data-dependent, self-managed materialisation

`AutoOrient.execute` calls `Image.autorotate/1`, applying the image's EXIF orientation.
Whether that needs random access depends on the **orientation value**, which lives in the
image header, not the op struct — so `requires_materialization?(%AutoOrient{})` cannot
decide it and returns `false` (it does not force a Chain-level materialise). AutoOrient
instead **manages its own materialisation internally**, because it is the one op whose need
is data-determined rather than struct-determined.

EXIF orientation safety:

- `1` (identity) and `2` (pure horizontal flip) — sequential-safe; stream.
- `3` (180°), `4` (vertical flip), `5`/`7` (transpose/transverse), `6`/`8` (90°/270°) —
  reverse row order or transpose axes; **need random access**.

Note these split into two sub-cases for the shrink-axis-swap machinery: only `5`/`6`/`7`/`8`
transpose axes (`exif_quarter_turn?` matches exactly `[5,6,7,8]`), so they exercise the
`shrink_axes`/`auto_orient_before_resize?` swap; `3`/`4` reverse rows without an axis swap and
take the non-swap branch. The equivalence test must cover both branches (it is not one
uniform case across 3–8).

So `AutoOrient.execute` reads the orientation header first (`VipsImage.header_value(image,
"orientation")`, the same read the processor's `exif_quarter_turn?` already does). For the
random-access set it materialises **via `Materializer.materialize/1`** — not a hand-coded
`copy_memory` + manual flag — so the copy-and-set-`materialized?` logic has a single owner
(§4). Then it **autorotates the materialised image**, not the original lazy `state.image`:

```elixir
def execute(%AutoOrient{}, %State{} = state) do
  with {:ok, %State{} = state} <- maybe_materialize_for_orientation(state),
       {:ok, {image, _flags}} <- Image.autorotate(state.image) do
    {:ok, sync_source_dimensions(set_image(state, image), ...)}
  end
end
# maybe_materialize_for_orientation/1: Materializer.materialize(state) when the header
# is in 3..8 (sets materialized?: true), else {:ok, state} unchanged.
```

This ordering is load-bearing: `Image.autorotate/1` builds a lazy `vips_rot`/`vips_flip`
node over its input, so it gains random access only because its input (`state.image`) is now
the RAM-resident buffer the prior `materialize` produced. Autorotating the un-materialised
`state.image` would read a fresh lazy node off the sequential source and fail. When a resize
follows, the shrink is already applied at decode (`shrink_blocked_before_resize?` deliberately
permits shrink before AutoOrient — verified: AutoOrient is not in its halt set), so the copy
is on the shrunk image. When **no resize** precedes AutoOrient (e.g. auto-orient + format
change), no shrink applies and the copy is on the **full-resolution** decode — the same cost
as today's `:random` open for that request, so not a regression.

The exact safe set is **gated on the EXIF equivalence test** (libvips `vips_autorot` may
self-cache for some orientations; the conservative default is to materialise for `3`–`8`).
The conformance suite already has an orientation-6 `ExifOrientationOriginImage`, but there are
**no on-disk EXIF fixtures** — each orientation is synthesised in-memory
(`Image.set_orientation!(img, n) |> Image.write!(:memory, suffix: ".jpg")`), and the test must
then re-open those bytes as a streamed/iodata source with `access: :sequential` and
`fail_on: :error`, **with a shrink load option active** (orientation-plus-shrink is the path
this design relies on, and the orientation header must survive the shrink). So "add 3/4/5/7/8
fixtures" is per-orientation synthesis work, not drop-in files. The streamed-open + sampled-
pixel-compare harness is recoverable from the deleted `sequential_compatibility_test.exs`.

**AutoOrient is the single sanctioned exception to Chain-owned materialisation.** Every other
op either declares `requires_materialization?` (and `Chain.maybe_materialize` does the copy)
or streams; AutoOrient is the only op that materialises through its own path, because its
need is data-determined (the EXIF header) and the struct-only callback cannot see it. An
audit of "what sets `materialized?`" must look in two places: `Chain.maybe_materialize` and
`AutoOrient.execute`. (#146 removes this asymmetry by hoisting orientation into pending state
+ flush.) Its correctness rests on a three-place axis-swap invariant kept coherent today:
the planner's `shrink_axes`/`auto_orient_before_resize?`, the processor's `exif_quarter_turn?`
header read, and the op's `sync_source_dimensions` — changing one without the others resizes
against the wrong axes.

This is the **minimal-correct** handling for this spec. A more faithful imgproxy-parity
model — carry rotation/flip as *pending* state, compensate crop+resize, and flush late
(fusing with the smart-crop/ML/final materialisation) — is deferred to **issue #146**. That
model supersedes self-materialisation; it is a performance/parity optimisation, not a
correctness fix, and depends on this spec's per-op signal landing first.

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

Covers every `false`-classified op: `Crop` (anchor/focal), `Resize` (fit/cover/stretch),
`ExtendCanvas`, `Padding`, `Background`, `Blur`, `Sharpen`, `Pixelate`, `Brightness`,
`Contrast`, `Saturation`, `Monochrome`, `Duotone`, `NormalizeColorProfile`,
`Flip{horizontal}`, and `AutoOrient` (with EXIF 3/4/5/7/8 fixtures in addition to the
existing orientation-6 fixture — see the AutoOrient gate above).

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
- `AutoOrient`: varied EXIF orientations including the row-reversing/transposing set (3–8)

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
| Operation modules (3) | `Rotate`, `Flip`, `Crop` add overriding `requires_materialization?/1` (`true` clauses) |
| `Operation.AutoOrient` | Read orientation header; call `Materializer.materialize/1` for EXIF 3–8 then autorotate the materialised image; stream 1/2 |
| `Transform.Chain` | Add `maybe_materialize/2`; call before each op |
| `Transform.Materializer` | Replace VipsImage `materialize/1` with State `materialize/1` setting the flag; rewrite arity-2 body; update moduledoc |
| `Transform.DecodePlanner` | Delete binary access decision; always `access: :sequential`; update doc |
| `Request.Processor` | Remove between-pipeline copy; simplify delivery materialisation (no new source-error wrap — see §6) |
| Shrink-on-load logic | Unchanged |
| Plan/Parser/Cache/Output/Source | Unchanged |
| `architecture_boundary_test.exs` | No change (all new dispatch is intra-transform-boundary) |
