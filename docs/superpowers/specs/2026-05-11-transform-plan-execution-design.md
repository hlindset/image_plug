# Transform Plan Execution Design

## Status

Proposed long-term design refinement for the current Transform IR branch.

This document narrows the plan execution part of the Transform IR design after
implementation review. It changes the target from "resolve the whole plan, then
execute" to "execute ordered Plan operations against the current image state."

## Problem

ImagePlug has the right high-level cache boundary:

```text
Plan semantic intent
  -> source-fetch-free final cache lookup
  -> origin fetch/decode on miss
  -> transform plan execution
  -> output encoding/storage under the original key
```

The weak part is treating source-aware transform work as a whole-plan compiler
or as a metadata-only geometry simulator.

Some operation choices need current image dimensions:

- `ResizeAuto` needs current dimensions.
- ratio crops need current dimensions.
- canvas ratios may need current dimensions.
- DPR, enlargement, and backend rounding can affect actual results.
- orientation can change dimensions.

The wrong long-term answer is to predict all of that in a resolver context. The
image is already open during execution, and querying its current dimensions is
cheap compared with the transform work. The executor should ask the image
directly instead of maintaining a shadow model of current geometry.

## Goals

- Keep final transformed-output cache lookup source-fetch-free and
  source-metadata-free.
- Keep runtime generic. Runtime may call `ImagePlug.Transform` facades and pass
  canonical plans/states through opaquely, but must not branch on concrete
  Plan or Transform operation modules.
- Keep parser/vendor quirks outside `ImagePlug.Transform`.
- Make Plan operation order define the image state each operation sees.
- Execute Plan operations one at a time against the actual current image state;
  any conversion to executable operations is local to that operation.
- Avoid source-space/current-space flags in Transform. By the time a request is
  a canonical Plan, coordinate semantics are represented by operation order.
- Do not carry pipeline/operation indexes unless structured diagnostics
  actually use them.
- Do not reintroduce derivation structs. Source-aware choices are reflected in
  executed work and tests.
- Keep first-slice scope narrow: current imgproxy-compatible behavior only.

## Non-Goals

- No broad backend capability planner.
- No smart/face/object crop execution.
- No second-wave parser implementation.
- No backend operation ontology unless existing executable operations cannot
  represent first-slice behavior.
- No requirement to produce a complete `%ResolvedPlan{}` before executing a
  request.
- No general admission path for arbitrary executable Transform operations into
  Plan pipelines.
- No coordinate mapping for "original source coordinates after later
  transforms" in the first slice.

## Core Rule

Plan operation order defines state.

Every Plan operation is interpreted against the image state at its position in
the pipeline.

Therefore Transform must not depend on whether a crop originally came from
source-space syntax, current-space syntax, or some vendor-specific region
syntax. Parser/adapter canonicalization owns that translation.

Examples:

- If a dialect means "crop source region, then resize", the parser emits
  `CropRegion` before `ResizeFit`.
- If a dialect lists resize before source-region crop but defines source-region
  semantics, the adapter reorders into canonical Plan order.
- If a dialect truly means "apply original source coordinates after arbitrary
  later transforms", that is not ordinary crop. It needs a future explicit
  mapped-coordinate operation and should remain out of the first slice.

Long-term `CropRegion` should not carry `space: :source | :current`. It should
mean "crop this region from the current image at this operation point."

## Thin Ordered Plan Shape

This design adopts the useful part of a thin op-list architecture:

```text
vendor parser
  -> ordered canonical Plan operations
  -> cache lookup from semantic material
  -> Transform.execute_plan/4 one operation at a time
  -> existing executable Transform operations/libvips
```

The canonical Plan should stay close to executable image work. It should not
become a universal vendor ontology, a capability planner, or a framework of
compatibility reports.

ImagePlug should still prefer narrow structs over raw tagged tuples for the
canonical request model. Structs give us constructor validation, stable cache
material, boundary ownership, and clear pattern matching without accepting
arbitrary keyword shapes. The target is therefore not:

```elixir
[
  {:resize, width: 1200, height: 800, fit: :cover, position: :center}
]
```

but the same level of thinness expressed as canonical Plan operations:

```elixir
%ImagePlug.Plan{
  pipelines: [
    %ImagePlug.Plan.Pipeline{
      operations: [
        %ImagePlug.Plan.Operation.ResizeCover{...},
        %ImagePlug.Plan.Operation.CropRegion{...}
      ]
    }
  ],
  output: %ImagePlug.Plan.Output{...}
}
```

The number of semantic operation types should remain small. If separate
resize structs stop paying for themselves, a later cleanup may collapse them
into one narrow resize operation with `mode: :fit | :cover | :stretch | :auto`.
That is optional; the required alignment is ordered Plan execution, not a tuple
representation.

Output format and quality should remain under `ImagePlug.Output` /
`ImagePlug.Plan.Output`, not in the transform operation list.

## Layers

### Plan Layer

`ImagePlug.Plan` owns canonical request intent. Plan operations are prefetch
safe:

- they can be materialized for the final cache key before source fetch;
- they do not contain source metadata;
- they do not contain resolved backend execution traces;
- they represent canonical ImagePlug image operations, not raw vendor syntax.

Examples:

- `ResizeAuto` remains unresolved semantic intent.
- `ResizeCover` means cover/fill intent plus guide.
- `CropRegion` stores a region relative to the current image at that point.
- `Canvas` stores target canvas intent.

### Canonical Plan Operation Contract

A canonical Plan operation:

- is prefetch-safe;
- has stable cache material;
- does not contain source metadata;
- does not contain resolved backend traces;
- is interpreted against the current image state at its position in the Plan;
- is constructed by parser/planner boundary code, not by runtime;
- must not encode vendor-specific parser quirks, except as explicit
  parser-owned unsupported/degraded intent that Transform does not interpret as
  normal geometry;
- should stay small enough to map directly to a simple ordered op-list form.

`CropRegion` is not a representation of vendor crop syntax. It is a canonical
image operation: crop this region from the current image at this operation
point. Vendor source/current/original coordinate semantics must be consumed
before Plan construction. Future unusual source-mapped behavior should use a
distinct semantic operation rather than adding flags to `CropRegion`.

### Plan Execution Layer

`ImagePlug.Transform.execute_plan/4` owns source-aware Plan execution.

Inputs:

- `%ImagePlug.Plan{}`
- `%ImagePlug.Transform.State{}` with decoded source image
- `%ImagePlug.Transform.SourceMetadata{}`
- runtime transform options

Output:

```elixir
{:ok, %ImagePlug.Transform.State{}}
| {:error, transform_error}
```

The Plan executor:

- validates the prefetch-safe plan through the public Transform facade;
- trusts `%SourceMetadata{}` as already validated at the runtime/source
  boundary;
- walks pipelines and operations in order;
- refreshes current image facts from `Transform.State.image` before converting
  each Plan operation to executable work;
- executes one Plan operation at a time through a small operation execution
  step;
- keeps any executable-operation conversion inside that operation execution step;
- returns the final transform state.

### Executable Transform Layer

`ImagePlug.Transform.Operation.*` modules own executable work over
`ImagePlug.Transform.State`.

Runtime executes these through generic Transform/Chain entry points. The
executable layer is allowed to contain backend-oriented concepts like
`DimensionRule`, target-rule result crops, and concrete crop coordinates.

## Public Entry Points

The long-term runtime-facing entry point should be:

```elixir
ImagePlug.Transform.execute_plan(plan, initial_state, source_metadata, opts)
```

Runtime should call this from the processor after source fetch/decode and source
metadata discovery. Runtime should not ask for fully resolved executable
pipelines up front.

These whole-plan compile helpers may remain temporarily for tests or migration,
but they are not the long-term runtime API:

```elixir
ImagePlug.Transform.resolve(plan, source_metadata, opts)
ImagePlug.Transform.executable_pipelines(plan, source_metadata, opts)
```

`ImagePlug.Transform.Resolver.*` modules should be treated as internal
implementation. They should not be exported as stable boundary entry points.

## Source Metadata And Options

Do not introduce a resolver context struct for the primary execution path.

Plan operation execution receives:

- the current `ImagePlug.Transform.State`;
- the already validated `ImagePlug.Transform.SourceMetadata`;
- execution options that do not affect output identity.

Current image facts should come from the actual image:

```elixir
current_width = Image.width(state.image)
current_height = Image.height(state.image)
```

or existing `Transform.State`/geometry helpers. Operations should prefer
current image facts from `State.image`. `SourceMetadata` is only for facts that
the current decoded image cannot provide.

Facts the current image cannot provide stay in `SourceMetadata` or execution
options:

- original source orientation metadata;
- original source type/format;
- runtime transform options that affect execution mechanics but not output
  identity.

Runtime options that affect output bytes must be represented in semantic
Plan/output/config/vary material. Options that affect execution mechanics only
may remain outside cache-key identity material.

The cache key's transform material version is owned by `ImagePlug.Cache.Key`.

Do not carry:

- `pipeline_index`;
- `operation_index`;
- `source_aligned?`;
- predicted current dimensions;
- a mutable context cache.

## Plan Executor Walk

The executor preserves pipeline grouping and consumes operation lists in order.
Each Plan operation is converted to executable work and executed before moving
to the next Plan operation.

Target shape:

```elixir
def execute_plan(%Plan{} = plan, %State{} = state, %SourceMetadata{} = metadata, opts) do
  with {:ok, pipelines} <- Transform.validate_prefetch_safe_plan(plan),
       {:ok, state} <- execute_pipelines(pipelines, state, metadata, opts) do
    {:ok, state}
  end
end
```

Pipeline walk:

```elixir
defp execute_pipelines(pipelines, state, metadata, opts) do
  Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
    case execute_pipeline(pipeline, state, metadata, opts) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end
```

Operation walk:

```elixir
defp execute_pipeline(%Pipeline{operations: operations}, state, metadata, opts) do
  Enum.reduce_while(operations, {:ok, state}, fn operation, {:ok, state} ->
    case execute_operation(operation, state, metadata, opts) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end

defp execute_operation(operation, state, metadata, opts) do
  with {:ok, executable_operations} <- executable_operations(operation, state, metadata, opts),
       {:ok, state} <- Chain.execute(state, executable_operations) do
    {:ok, state}
  end
end
```

The exact `Chain.execute/2` call should preserve the repo's existing
error/warning behavior. The Plan executor must not accidentally drop
diagnostics or warnings from previously executed Plan operations. The important
design point is that the next Plan operation sees the actual image state
produced by the previous Plan operation.

The main walk should be framed as ordered Plan execution. Converting a Plan
operation to executable operations is an implementation detail of
`execute_operation/4`, not a whole-plan compiler phase.

## Executable Operations Contract

Executable operation conversion is an implementation detail of Plan operation
execution. It converts one Plan operation at a time as part of executing that
operation.

```elixir
@spec executable_operations(
        Plan.Operation.operation(),
        State.t(),
        SourceMetadata.t(),
        keyword()
      ) ::
        {:ok, [ImagePlug.Transform.operation()]}
        | {:error, transform_error()}
```

Executable operation conversion must handle every prefetch-valid first-slice
operation explicitly: produce executable operations or return a tagged error.

It must not rely on missing function clauses for reachable invalid state.

Recommended error shapes:

```elixir
{:unsupported_canvas_geometry, operation}
{:invalid_resolved_geometry, operation, details}
{:invalid_source_metadata, reason}
```

Do not add a separate return value to split execution into pending segments.
Each Plan operation is already an execution boundary.

## Executable Operation Responsibilities

### Resize

`ResizeFit`, `ResizeCover`, and `ResizeStretch` convert to existing executable
`Resize` and optional result `Crop`.

`ResizeAuto`:

- reads current dimensions from `state.image`;
- stores the requested auto behavior in cache material, not the execution-time
  branch;
- computes branch from current orientation and requested target orientation;
- selects cover when both orientations are known and equal, including
  square-to-square;
- selects fit otherwise;
- emits the existing executable sequence for that branch.

### Crop

`CropGuided` converts to executable gravity/focal crop.

`CropRegion` converts against the current image at its operation point:

- ratio dimensions use current image width/height;
- logical pixel dimensions are emitted directly after validation;
- ratio-derived crop dimensions clamp to at least `1` pixel;
- coordinates may resolve to `0`.

There is no source-space flag in Transform long term. Parser/adapter
canonicalization owns operation ordering for dialects with source-region
syntax.

`CropRegion` should remain narrow. It should not grow `space`,
`source_aligned?`, `mapped_from_source`, or similar flags.

### Canvas

Canvas conversion must choose one coherent executable representation:

- both axes ratio -> aspect-ratio canvas;
- both axes pixel/auto -> dimensions canvas;
- mixed ratio and pixel/auto -> unsupported unless first-slice imgproxy
  behavior proves a compatible interpretation.

Recommended first-slice behavior for mixed ratio/pixel canvas:

```elixir
{:error, {:unsupported_canvas_geometry, operation}}
```

Mixed-unit canvas is not invalid in principle; it is unsupported until an
imgproxy-compatible interpretation is deliberately implemented.

### Orientation

`AutoOrient`, `Rotate`, and `Flip` convert to existing executable operations.

Because each Plan operation is executed before the next one is converted, later
operations can read the actual image dimensions after orientation has run.
There is no need to predict swapped dimensions in resolver state.

## Parser And Planner Ordering

Parser/adapter canonicalization owns dialect-specific operation ordering.

For imgproxy-compatible behavior, the parser should emit canonical Plan order
that reproduces existing observable semantics. If a dialect exposes a
source-region concept, the adapter must emit the crop where that region is
meaningful.

Two parser modes are enough conceptually:

- Fixed-order/declarative parsers, such as imgproxy-compatible syntax, parse
  vendor options into a bag and then emit canonical Plan operations in the
  ImagePlug order that matches the vendor's semantics.
- Ordered-chain parsers, such as TwicPics-style syntax, emit canonical Plan
  operations in URL-chain order because each operation is interpreted after the
  previous operation.

After parsing, Transform does not care which mode produced the Plan. It only
executes the ordered operation list.

Transform should not carry source/current coordinate-space flags to compensate
for parser ordering. If a future dialect needs original-source coordinates after
later transforms, introduce a distinct semantic operation with explicit mapping
semantics rather than overloading ordinary `CropRegion`.

If a parser cannot translate a vendor's coordinate semantics into ordinary
ordered Plan operations, it must either reject the request or apply an explicit
parser-owned degradation policy. It must not add vendor-specific coordinate
flags to canonical Transform operations.

Positions and guides should also remain small:

- anchors such as `:center`, `:top_left`, `:bottom_right`;
- focal points when first-slice behavior already supports them;
- explicit vendor/smart intent only as unsupported or degraded parser policy,
  not as a fake universal smart-crop model.

Smart/object/face crop strategies should stay out of first-slice Transform
execution unless ImagePlug can reproduce the underlying detection behavior.

## Source Metadata

Runtime must not lie about orientation.

Runtime/source-opening code owns source metadata validation. It should build
metadata through:

```elixir
SourceMetadata.new(
  width: Image.width(image),
  height: Image.height(image),
  orientation: discovered_orientation,
  format: source_format,
  source_type: source_type
)
```

`execute_plan/4` accepts `%SourceMetadata{}` and trusts it. It should
not revalidate metadata fields on every internal call just to protect against
malformed hand-built structs.

Hardcoding:

```elixir
orientation: :normal
```

is only correct if orientation metadata has been read and proven normal.

Long-term policy:

- if orientation metadata is known, pass `{:exif, n}` or `:normal`;
- if metadata cannot be read in the first slice, pass `:unknown`;
- never default unknown metadata to `:normal`.

## Primitive Orientation Operations

The semantic wrappers:

- `ImagePlug.Plan.Operation.AutoOrient`
- `ImagePlug.Plan.Operation.Rotate`
- `ImagePlug.Plan.Operation.Flip`

add little semantic value because they lower one-to-one to product-neutral
executable operations.

Long-term preferred direction:

- allow a narrow set of canonical executable primitives directly in request
  plans: `ImagePlug.Transform.Operation.AutoOrient`,
  `ImagePlug.Transform.Operation.Rotate`, and
  `ImagePlug.Transform.Operation.Flip`;
- do not allow arbitrary executable Transform operations into Plan pipelines;
- keep parser construction behind a facade so parser code does not depend on a
  broad Transform operation namespace;
- keep cache material protocol-based and source-fetch-free;
- keep validation in `ImagePlug.Transform.validate_prefetch_safe_plan/1`.

This cleanup may happen in the same PR as Plan execution alignment, but it
must be a separate step with focused boundary and cache-material tests. Do not
mix it into the executor rewrite. If this boundary becomes awkward, keep the
wrappers.

## Cache Invariant

Final cache keys continue to use semantic Plan material:

```text
semantic plan material
source freshness identity
output/config/vary material
Cache.Key transform material version
```

Plan execution output never mutates the final key.

Tests should prove:

- `ResizeAuto` cache material remains unresolved semantic intent;
- different current image states can execute through different branches while
  cache material remains semantic;
- source freshness identity changes the final key;
- cache hit does not enter Plan execution;
- cache miss stores under the original prefetch-safe key.

## Boundary Rules

- `ImagePlug.Runtime.*` may call `ImagePlug.Transform.execute_plan/4`.
- `ImagePlug.Runtime.*` must not alias, construct, or pattern match on concrete
  Plan or Transform operation modules.
- `ImagePlug.Cache.*` must not reference resolver, source metadata, resolved
  plan, or Plan executor internals.
- `ImagePlug.Parser.*` must not reference resolver, source metadata, resolved
  plan, or Plan executor internals.
- `ImagePlug.Transform.Resolver.*` may reference semantic Plan operations and
  executable Transform operations.
- `ImagePlug.Transform.Resolver.*` should not be exported as stable boundary
  entry points.

Architecture tests should scan the whole cache namespace, not only
`lib/image_plug/cache/key.ex`.

The `Resolver` namespace may remain during migration, but its long-term role is
local executable-operation conversion, not whole-plan resolution. A rename to a
boring Plan-execution namespace is allowed in this PR if it is done as a
separate mechanical step with boundary tests.

## Test Strategy

Add focused Plan executor tests:

- `rotate(0)` alone and before `ResizeAuto` is a no-op.
- resize followed by ratio `CropRegion` executes the resize first, then
  converts the crop using actual post-resize image dimensions.
- auto-orient followed by `ResizeAuto` executes orientation first, then
  converts resize using actual post-orientation dimensions.
- ratio crop dimensions on tiny images clamp to `1`.
- mixed ratio/pixel canvas is rejected, or explicitly converts if support is
  intentionally added.

Add parser/planner tests:

- dialect source-region syntax emits ordinary ordered `CropRegion` at the
  correct point in the canonical Plan.
- parsed/canonicalized plans do not rely on `space: :source | :current`.

Add runtime/source metadata tests:

- unknown orientation is not converted to `:normal`;
- if EXIF orientation is supported, runtime passes it into `SourceMetadata`.

Add cache/runtime invariant tests:

- cache hit does not enter Plan execution;
- cache miss stores under the original key;
- execution branch differences do not enter key material.

Remove tests that only prove impossible internal misuse, such as fake transform
modules with broken callback metadata, unless those modules represent a real
public boundary.

## Migration Order

1. Introduce Plan executor facade.
   - Add `Transform.execute_plan/4`.
   - Route runtime miss/uncached processing through it.
   - Keep existing whole-plan resolve helpers temporarily for tests if needed.

2. Make executable-operation conversion one-operation-at-a-time and state-aware.
   - Pass current `State` into executable-operation conversion.
   - Query current image dimensions directly when needed.
   - Do not introduce pending segment or explicit execution-boundary return
     values.
   - Fix `rotate(0)`.
   - Clamp ratio crop dimensions.
   - Reject unsupported canvas geometry.

3. Remove resolver context from the primary path.
   - Pass `State`, `SourceMetadata`, and opts to executable-operation
     conversion.
   - Keep source metadata in `SourceMetadata`; keep execution-only options in
     opts.
   - Remove predicted current dimensions.
   - Remove `source_aligned?`.
   - Remove `pipeline_index` and `operation_index`.

4. Move coordinate-space responsibility to parser/planner.
   - Remove `space` from long-term `CropRegion`.
   - Update parser canonicalization so operation order expresses source/current
     semantics.
   - Keep any temporary compatibility fields behind migration tests only.

5. Tighten boundaries.
   - Stop exporting resolver internals.
   - Rename resolver internals if doing so clarifies that the long-term role is
     Plan operation execution, not whole-plan resolution.
   - Expand architecture tests for cache/parser post-fetch dependencies.

6. Correct source metadata orientation.
   - Use real metadata when available.
   - Otherwise use `:unknown`, not `:normal`.

7. Revisit orientation wrappers.
   - Either keep them deliberately, or replace them with a narrow canonical
     primitive allowlist.
   - Do not allow arbitrary executable Transform operations into Plan.
   - This may be a later step in the same PR after the Plan executor path is
     covered by focused boundary/cache-material tests.

8. Collapse overly split operation structs if it simplifies the final model.
   - Evaluate `ResizeFit`, `ResizeCover`, `ResizeStretch`, and `ResizeAuto`
     after Plan execution is in place.
   - Collapse them only if one narrow resize struct with an explicit mode makes
     material, parser construction, and executable-operation conversion
     simpler.
   - This may be a later step in the same PR, but only after the Plan executor
     path is covered and only as a separate step with focused
     constructor/material/parser/execution tests.

## Success Criteria

- `Transform.execute_plan/4` executes Plan operations in order, consulting the
  actual current image before converting each operation to executable work.
- No valid semantic Plan causes a resolver/executable-conversion
  `FunctionClauseError`.
- Runtime remains generic.
- Cache lookup remains source-fetch-free.
- Resolver/executor internals are not public boundary exports.
- There is no mutable resolver context duplicating backend geometry behavior.
- Transform does not know source-space/current-space crop flags in the long
  term.
- Parser/planner canonical order owns dialect coordinate semantics.
- Orientation/resize/crop/canvas behavior is covered by focused tests.
- No derivation structs or derived branch material are introduced.
