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

- `Resize` with `mode: :auto` needs current dimensions.
- ratio crops need current dimensions.
- canvas ratios may need current dimensions.
- DPR, enlargement, and backend rounding can affect actual results.
- orientation can change dimensions.

The wrong long-term answer is to predict all of that in a whole-plan compiler
context. The image is already open during execution, and querying its current
dimensions is cheap compared with the transform work. The executor should ask
the image directly instead of maintaining a shadow model of current geometry.

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
- No `BackendProfile` or backend-profile cache-key input in the first slice.
  If transform key-data semantics change, bump the cache-owned transform key
  data version.
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
  `CropRegion` before `Resize`.
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
  -> cache lookup from semantic key data
  -> Transform.execute_plan/4 one operation at a time
  -> existing executable Transform operations/libvips
```

The canonical Plan should stay close to executable image work. It should not
become a universal vendor ontology, a capability planner, or a framework of
compatibility reports.

ImagePlug should still prefer narrow structs over raw tagged tuples for the
canonical request model. Structs give us constructor validation, stable key
data, boundary ownership, and clear pattern matching without accepting
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
        %ImagePlug.Plan.Operation.Resize{mode: :cover, ...},
        %ImagePlug.Plan.Operation.CropRegion{...}
      ]
    }
  ],
  output: %ImagePlug.Plan.Output{...}
}
```

The number of semantic operation types should remain small. The first-slice
target is one narrow resize operation with
`mode: :fit | :cover | :stretch | :auto`, tagged tuple geometry values, and
only the explicit product-neutral orientation primitive allowlist described
below. Older snippets that mention split resize modules, geometry structs, or
Plan wrappers for one-to-one orientation primitives are migration context, not
the current target.

Target first-slice operation shape:

```elixir
%ImagePlug.Plan.Operation.Resize{mode: :fit | :cover | :stretch | :auto, ...}
%ImagePlug.Plan.Operation.CropGuided{...}
%ImagePlug.Plan.Operation.CropRegion{...}
%ImagePlug.Plan.Operation.Canvas{...}
%ImagePlug.Transform.Operation.AutoOrient{}
%ImagePlug.Transform.Operation.Rotate{}
%ImagePlug.Transform.Operation.Flip{}
```

Geometry values should stay as small tagged values such as
`:auto`, `:full_axis`, `{:px, n}`, and `{:ratio, numerator, denominator}`
unless a struct proves necessary.

Output format and quality should remain under `ImagePlug.Output` /
`ImagePlug.Plan.Output`, not in the transform operation list.

## Layers

### Plan Layer

`ImagePlug.Plan` owns canonical request intent. Plan operations are prefetch
safe:

- they can produce normalized key data for the final cache key before source
  fetch;
- they do not contain source metadata;
- they do not contain resolved backend execution traces;
- they represent canonical ImagePlug image operations, not raw vendor syntax.

Examples:

- `Resize` with `mode: :auto` remains unresolved semantic intent.
- `Resize` with `mode: :cover` means cover/fill intent plus guide.
- `CropRegion` stores a region relative to the current image at that point.
- `Canvas` stores target canvas intent.

### Canonical Plan Operation Contract

A canonical Plan operation:

- is prefetch-safe;
- has stable cache key data;
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

- assumes request-time code has already validated prefetch-safe Plan shape
  before cache lookup and origin fetch;
- may call the same validation facade as an internal assertion, but must not be
  the first request-safety boundary for parser/planner errors;
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
executable layer is allowed to contain backend-oriented concepts like flattened
resize sizing fields, explicit result crops, and concrete crop coordinates.

## Public Entry Points

The long-term runtime-facing entry point should be:

```elixir
ImagePlug.Transform.execute_plan(plan, initial_state, source_metadata, opts)
```

Runtime should call this from the processor after source fetch/decode and source
metadata discovery. Runtime should not ask for fully resolved executable
pipelines up front.

These whole-plan compile helpers are not the long-term runtime API:

```elixir
ImagePlug.Transform.resolve(plan, source_metadata, opts)
ImagePlug.Transform.executable_pipelines(plan, source_metadata, opts)
```

They may remain temporarily while tests migrate, but the target implementation
does not add stable resolved-plan boundary exports. If a private helper module
is useful, prefer a boring Plan-execution name such as
`ImagePlug.Transform.PlanExecutor`.

## Runtime Materialization Boundaries

`ImagePlug.Runtime.*` owns origin streams, decoded-origin bookkeeping, and
materialization decisions that involve `Origin.Response`. Transform must not
receive or reference `Origin.Response`, `DecodedOrigin`, or runtime modules.

`Transform.execute_plan/4` owns only transform state transitions. If the current
runtime needs materialization between pipelines, use an execution-only
runtime-owned hook or a narrow Transform pipeline-step facade. The hook may
materialize `%State{}` between non-final pipelines, but it must not change output
identity and must not expose runtime types to Transform.

Final pre-delivery materialization for sequential source reads remains runtime
work after `execute_plan/4` returns.

## Source Metadata And Options

Do not introduce a whole-plan context struct for the primary execution path.

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
Plan/output/config/vary key data. Options that affect execution mechanics only
may remain outside cache-key identity data.

`Transform.execute_plan/4` should only read execution options from an explicit
allowlist. If a new option changes output bytes, it must first be represented
in Plan/output/config/vary key data or in the cache-owned transform key-data
version.

The cache key's transform key-data version is owned by `ImagePlug.Cache.Key`.

## Cache Key Data Contract

Final transformed-output cache keys are built before source fetch from:

| Component | Owner | Notes |
| --- | --- | --- |
| canonical Plan operation key data | `ImagePlug.Plan` / `ImagePlug.Transform.KeyData` | normalized, source-fetch-free, no resolved execution branch data |
| source freshness identity | `ImagePlug.Runtime.*` source identity boundary | caller/runtime supplied identity or freshness key data for the origin object |
| output/config/vary key data | `ImagePlug.Output.*` and runtime config | includes normalized `Accept` inputs for `format:auto` and other byte-affecting output choices |
| transform key-data version | `ImagePlug.Cache.Key` | cache-owned version bump for transform key-data semantics |

Execution-time branch choices, resolved geometry, and source metadata never
mutate the final key used for lookup or storage.

## DPR And Pixel Density

Parser/constructor boundaries normalize DPR into canonical key data. Plan
operations store logical dimensions plus normalized DPR. Equivalent inputs such
as `1`, `1.0`, and `"1.00"` must produce identical key data, for example:

```elixir
dpr: [unit: :ratio, numerator: 1, denominator: 1]
```

Decimal strings should parse exactly. Float inputs use a documented fixed
decimal precision policy, then reduce with `Integer.gcd/2`.

Per-operation executable conversion is the only phase that applies DPR to
logical geometry. DPR-derived physical dimensions do not replace semantic Plan
key data.

Do not carry:

- `pipeline_index`;
- `operation_index`;
- `source_aligned?`;
- predicted current dimensions;
- a mutable context cache.

## Plan Executor Walk

The executor preserves pipeline grouping and consumes operation lists in order.
Each Plan operation is converted to executable work and executed before moving
to the next Plan operation. Pipeline boundaries must remain visible enough for
runtime-owned materialization between non-final pipelines.

Target shape:

```elixir
def execute_plan(%Plan{} = plan, %State{} = state, %SourceMetadata{} = metadata, opts) do
  with {:ok, pipelines} <- assert_prefetch_valid_plan(plan),
       {:ok, state} <- execute_pipelines(pipelines, state, metadata, opts) do
    {:ok, state}
  end
end
```

Runtime must call the public prefetch validation facade before cache lookup and
origin fetch. `assert_prefetch_valid_plan/1` above represents an internal
assertion/reuse of the same validation, not the primary request-safety check.

Pipeline walk:

```elixir
defp execute_pipelines(pipelines, state, metadata, opts) do
  Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
    case execute_pipeline_with_boundary(pipeline, state, metadata, opts) do
      {:ok, state} -> {:cont, {:ok, state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end
```

`execute_pipeline_with_boundary/4` is illustrative. The implementation may keep
the boundary in runtime instead. The invariant is that Transform does not own
origin stream side effects, while ordered Plan execution still observes the
actual image produced by previous operations.

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
{:invalid_resolved_geometry, operation, details}
{:invalid_source_metadata, reason}
```

Errors fully knowable from prefetch-safe Plan shape, such as first-slice
unsupported mixed-unit canvas geometry, belong in prefetch validation and must
fail before cache lookup or origin fetch.

Do not add a separate return value to split execution into pending segments.
Each Plan operation is already an execution boundary.

## Executable Operation Responsibilities

### Resize

`Resize` converts to existing executable `Resize` and optional result `Crop`
according to its mode.

`Resize` with `mode: :auto`:

- reads current dimensions from `state.image`;
- stores the requested auto behavior in key data, not the execution-time
  branch;
- computes branch from current aspect orientation, derived from
  `Image.width/height(state.image)` after prior operations, and requested target
  aspect orientation;
- selects cover when both aspect orientations are known and equal, including
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

Recommended first-slice behavior for mixed ratio/pixel canvas is prefetch
validation failure:

```elixir
{:error, {:unsupported_canvas_geometry, operation}}
```

Mixed-unit canvas is not invalid in principle; it is unsupported until an
imgproxy-compatible interpretation is deliberately implemented. Because this
unsupported shape is knowable from the Plan, it must fail before cache lookup
or origin fetch, not during `execute_plan/4`.

### Orientation

`AutoOrient`, `Rotate`, and `Flip` convert to existing executable operations.

Because each Plan operation is executed before the next one is converted, later
operations can read the actual image dimensions after orientation has run.
There is no need to predict swapped dimensions in shadow executor state.

## Parser And Planner Ordering

Parser/adapter canonicalization owns dialect-specific operation ordering.
In this document, parser/planner means parser-owned Plan construction and
canonicalization adapters under `ImagePlug.Parser.*`. It does not mean a
runtime transform planner.

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

First-slice imgproxy-compatible parser mapping should be explicit enough that
Transform does not have to infer vendor intent:

| Parser feature | Canonical Plan order |
| --- | --- |
| auto-orient / rotate / flip | explicit orientation primitive at the point matching imgproxy-compatible behavior |
| resize fit/cover/stretch/auto | one `Resize` operation with explicit mode, guide, enlargement policy, logical dimensions, and DPR |
| guided crop or gravity/focal crop | `CropGuided` at the canonical point where the crop is meaningful |
| exact region crop | ordinary ordered `CropRegion`; source/current dialect semantics are consumed by parser ordering |
| canvas / extend | `Canvas` only for first-slice supported unit combinations; unsupported mixed-unit shapes fail prefetch validation |
| smart/object/face crop | reject or apply explicit parser-owned degradation; do not smuggle vendor strategy into Transform geometry |

## Source Metadata

Runtime must not lie about orientation.

Runtime/source-opening code owns source metadata validation. It should build
metadata through:

```elixir
SourceMetadata.new(
  orientation: discovered_orientation,
  format: source_format,
  source_type: source_type
)
```

First-slice `SourceMetadata` should not carry current width/height. Plan
execution reads current dimensions from `State.image`. Only add original-source
dimensions later if a real non-current-geometry caller needs them.

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

The target direction is:

- allow a narrow set of canonical executable primitives directly in request
  plans: `ImagePlug.Transform.Operation.AutoOrient`,
  `ImagePlug.Transform.Operation.Rotate`, and
  `ImagePlug.Transform.Operation.Flip`;
- do not allow arbitrary executable Transform operations into Plan pipelines;
- expose the allowlist through a narrow Plan construction/validation facade so
  parser code does not depend on a broad Transform operation namespace;
- keep key data source-fetch-free;
- keep validation in `ImagePlug.Transform.validate_prefetch_safe_plan/1`.

This should be implemented as a separate step with focused boundary and key
data tests. If the Boundary dependency becomes awkward, keep temporary Plan
wrappers until the facade is clear.

## Cache Invariant

Final cache keys continue to use semantic Plan key data:

```text
semantic plan key data
source freshness identity
output/config/vary key data
Cache.Key transform key-data version
```

Plan execution output never mutates the final key.

Tests should prove:

- `Resize` with `mode: :auto` key data remains unresolved semantic intent;
- different current image states can execute through different branches while
  key data remains semantic;
- source freshness identity changes the final key;
- cache hit does not enter Plan execution;
- cache miss stores under the original prefetch-safe key.

## Boundary Rules

- `ImagePlug.Runtime.*` may call `ImagePlug.Transform.execute_plan/4`.
- `ImagePlug.Runtime.*` must not alias, construct, or pattern match on concrete
  Plan or Transform operation modules.
- `ImagePlug.Cache.*` must not reference source metadata, resolved plan, or
  Plan executor internals.
- `ImagePlug.Parser.*` must not reference source metadata, resolved plan, or
  Plan executor internals.
- `ImagePlug.Transform.PlanExecutor` or equivalent private internals may
  reference semantic Plan operations and executable Transform operations.
- Plan-execution internals should not be exported as stable boundary entry
  points.

Architecture tests should scan the whole cache namespace, not only
`lib/image_plug/cache/key.ex`.

Do not add a new `Resolver` namespace for this design. Existing resolver
exports should be removed as the executor becomes the runtime API.

## Test Strategy

Add focused Plan executor tests:

- `rotate(0)` alone and before `Resize` with `mode: :auto` is a no-op.
- resize followed by ratio `CropRegion` executes the resize first, then
  converts the crop using actual post-resize image dimensions.
- auto-orient followed by `Resize` with `mode: :auto` executes orientation
  first, then converts resize using actual post-orientation dimensions.
- ratio crop dimensions on tiny images clamp to `1`.
- mixed ratio/pixel canvas is rejected by prefetch validation before cache
  lookup or origin fetch, unless support is intentionally added.

Add parser/planner tests:

- dialect source-region syntax emits ordinary ordered `CropRegion` at the
  correct point in the canonical Plan.
- parsed/canonicalized plans do not rely on `space: :source | :current`.

Add runtime/source metadata tests:

- unknown orientation is not converted to `:normal`;
- if EXIF orientation is supported, runtime passes it into `SourceMetadata`.

Add cache/runtime invariant tests:

- cache hit does not enter Plan execution;
- prefetch-known validation failures, such as unsupported mixed-unit canvas,
  return without origin fetch;
- cache miss stores under the original key;
- execution branch differences do not enter key data.

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
   - Reject unsupported canvas geometry during prefetch validation.

3. Remove whole-plan resolver context from the primary path.
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
   - Stop exporting resolved-plan internals.
   - Replace resolved-plan internals with a Plan-execution namespace if a helper
     module is still useful.
   - Expand architecture tests for cache/parser post-fetch dependencies.

6. Correct source metadata orientation.
   - Use real metadata when available.
   - Otherwise use `:unknown`, not `:normal`.

7. Replace orientation wrappers with a narrow canonical primitive allowlist.
   - Do not allow arbitrary executable Transform operations into Plan.
   - This may be a later step in the same PR after the Plan executor path is
     covered by focused boundary/key-data tests.

8. Use one narrow resize operation.
   - Replace `ResizeFit`, `ResizeCover`, `ResizeStretch`, and `ResizeAuto`
     with one `Resize` struct with an explicit mode.
   - Keep key data, parser construction, and executable-operation conversion
     centered on that one operation.
   - This may be a later step in the same PR, but only after the Plan executor
     path is covered and only as a separate step with focused
     constructor/key-data/parser/execution tests.

## Success Criteria

- `Transform.execute_plan/4` executes Plan operations in order, consulting the
  actual current image before converting each operation to executable work.
- No valid semantic Plan causes an executable-conversion
  `FunctionClauseError`.
- Runtime remains generic.
- Cache lookup remains source-fetch-free.
- Plan-executor internals are not public boundary exports.
- There is no mutable whole-plan context duplicating backend geometry behavior.
- Transform does not know source-space/current-space crop flags in the long
  term.
- Parser/planner canonical order owns dialect coordinate semantics.
- Orientation/resize/crop/canvas behavior is covered by focused tests.
- No derivation structs or derived branch key data are introduced.
