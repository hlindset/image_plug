# Transform IR Design

## Status

Approved design direction, revised after review. This document is the basis for
a later implementation plan, not implementation approval by itself.

The accepted direction is semantic plan IR plus transform resolver plus backend
lowering. The revised scope is intentionally smaller than the original design
round: build the minimum semantic core needed to replace current
imgproxy-compatible behavior, then grow the IR from vendor mapping fixtures.

## Goals

ImagePlug needs a transform IR that can represent product-neutral image intent
before resolving that intent into local backend work. The IR should support the
current imgproxy-compatible path behavior first, while keeping room for
TwicPics, imgix, Cloudinary, Fastly, IIIF, and similar APIs.

Constraints:

- Backwards compatibility with current internal transform structs is not
  required.
- Prefer narrow Elixir structs and pattern matching over tagged mega-structs.
- Vendor-specific quirks belong in parser or adapter layers.
- Runtime must remain generic and must not depend on concrete transform
  operation modules.
- Parser and resolver validation failures that can be known before origin fetch
  must still fail before origin fetch or cache lookup.
- Do not build a broad image-transformation ontology before a second real
  adapter proves the abstraction is needed.

## Current Pressure Points

The current architecture already has useful boundaries:

- `ImagePlug.Plan` is the product-neutral request model.
- `ImagePlug.Plan.Pipeline` contains ordered operations.
- `ImagePlug.Transform` is the transform facade.
- `ImagePlug.Transform.State` carries the current image through execution.
- `ImagePlug.Transform.Chain` dispatches operations generically.
- Runtime dispatches through generic transform functions and boundary tests
  enforce that runtime does not name concrete transform modules.

The main issue is that current executable operations also act as semantic IR.
Several structs combine multiple meanings:

- `Crop` represents exact region extraction, gravity-guided crops,
  focus-guided crops, and result crops after cover/fill resizing.
- `Resize` represents several resize modes through `DimensionRule`.
- `ExtendCanvas` represents canvas extension and some padding/letterbox-like
  behavior.

This is manageable for the current imgproxy-compatible subset, but it will get
unclear as soon as another adapter needs different coordinate spaces, fallback
strategies, operation order, or smart-crop capability behavior.

## Architecture Decision

Use a semantic plan IR plus backend lowering.

Target flow:

```text
parser raw syntax
  -> parser-normalized dialect commands
       aliases, vendor defaults, option order, and scoped fields resolved
  -> adapter canonicalization
  -> ImagePlug.Plan
       source/output/policy/cache/response
       pipelines: [%ImagePlug.Plan.Pipeline{
         operations: [%ImagePlug.Plan.Operation.*{}]
       }]
  -> ImagePlug.Transform.resolve/3
       validates semantic operations
       applies source metadata
       applies backend capabilities
       records diagnostics and decisions
       lowers to executable backend work
  -> resolved transform plan
  -> ImagePlug.Transform facade
       executes without runtime naming concrete operation modules
```

`ImagePlug.Plan.Pipeline` remains the canonical request pipeline container.
Its `operations` field should contain canonical semantic operations with
explicit guides and normalized geometry. Parser-local compatibility commands
may exist before this point, but raw vendor syntax and parser context should
not leak into canonical plan material.

Adapter-local normalized commands are internal parser or adapter data. They
must not appear in canonical `ImagePlug.Plan.Pipeline.operations` unless a
later design explicitly promotes that command to a canonical semantic
operation. Example namespaces:

- `ImagePlug.Parser.Imgproxy.Command.ResizeAuto`
- `ImagePlug.Parser.TwicPics.Command.SetFocus`

The resolver belongs under `ImagePlug.Transform` because it owns transform
semantics, source-metadata resolution, decode implications, capability checks,
and backend lowering. `ImagePlug.Plan` should not depend on concrete backends.
Parsers may construct exported plan operation structs. Runtime should not
construct or reference concrete semantic or backend operation modules directly.

## Initial Semantic Operation Family

This is not the full ImagePlug image ontology. It is the initial semantic core
for current imgproxy-compatible behavior plus a small set of near-term
extension points proven by vendor pressure tests.

### MVP Operations

Crop operations:

- `CropRegion`
- `CropGuided`

Resize operations:

- `ResizeFit`
- `ResizeCover`
- `ResizeStretch`
- `ResizeScale`, only if current imgproxy-compatible behavior needs standalone
  scale/factor semantics that cannot be expressed as fit, cover, or stretch

Layout operations:

- `Canvas`

Orientation operations:

- `AutoOrient`
- `Rotate`
- `Flip`

The canonical MVP does not include `SetFocus`, `SetGravity`, or a general
conditional resize operation. Canonical operations should carry explicit guide
values. Parser adapters may use context or compatibility commands internally
and lower them before canonical semantic material is produced.

## First Slice Hard Limits

The first implementation slice may introduce only:

- semantic operations required by current documented imgproxy-compatible
  behavior
- canonical material for those operations
- source-aware resolution for those operations
- lowering to existing executable transform operations where possible

The first implementation slice must not introduce:

- general capability planning
- backend operation structs unless existing executable operations cannot
  represent resolved work correctly
- smart, face, or object strategy execution
- second-wave parser implementations
- generalized conditional IR

### Deferred Operations

Do not implement these in the first slice unless a current imgproxy-compatible
feature cannot be represented without them:

- `CropAspectRatio`
- standalone `CropSmart`
- `ResizeContain`
- canonical `SetFocus`
- canonical `SetGravity`
- `Pad`
- `Trim`

`Pad` and `Trim` are expected later operations, but they are not required to
replace the current documented imgproxy-compatible subset unless that subset is
expanded first.

### Explicitly Rejected As Initial Operations

`ResizeContain` should not be an initial semantic operation. Model contain-like
visible output as:

```text
ResizeFit -> Canvas
```

This keeps "contain" as parser or vendor vocabulary instead of core IR
vocabulary unless a later adapter proves it has distinct semantic value.

`Canvas` places the current image onto a target canvas. It must not choose a
resize scale by itself. Scaling must be represented by a preceding resize
operation. This keeps `Canvas` from becoming a disguised contain/pad
mega-operation.

Standalone `CropSmart` should not be an initial semantic operation. Smartness
usually guides a concrete crop or cover operation. Represent smart behavior as
guide strategies attached to `CropGuided` or `ResizeCover`.

`resize:auto` should not introduce a general conditional IR in the first slice.
Represent it as an imgproxy adapter-local compatibility command, then lower it
to `ResizeCover` or `ResizeFit` after source dimensions are known. The selected
branch is resolver material.

## Adapter Context Commands And Guides

Some dialects, notably TwicPics-style chains, have context-changing commands
that affect later transformations without changing pixels. ImagePlug may model
those inside the adapter layer as parser-normalized commands such as focus or
gravity context updates.

Costs of making context commands canonical operations:

- They appear in step indexes and diagnostics.
- They complicate lowering and optimization.
- They need explicit pipeline-boundary rules.
- They can be mistaken for pixel-changing operations.

The design therefore constrains them:

- Context commands may be present in adapter-local parser output.
- Parser or resolver normalization should fold context into explicit guides on
  later geometry operations where possible.
- Canonical semantic material should represent the normalized effect, not raw
  parser spelling.
- A context command may be elided only after normalization proves it has no
  visible effect on any later supported operation in the same pipeline.
- Unknown, unsupported, or deferred operations must prevent context elision
  unless policy explicitly allows ignoring that context.

Guides should be explicit value structs:

```elixir
%ImagePlug.Plan.Guide.Focus{}
%ImagePlug.Plan.Guide.Gravity{}
%ImagePlug.Plan.Guide.Anchor{}
%ImagePlug.Plan.Guide.FocalPoint{}
%ImagePlug.Plan.Guide.StrategyList{}
```

Smart behavior belongs in strategy guides:

```elixir
%ImagePlug.Plan.Guide.StrategyList{
  ordered: [
    %ImagePlug.Plan.Strategy.Face{scope: :all},
    %ImagePlug.Plan.Strategy.Attention{},
    %ImagePlug.Plan.Strategy.Center{}
  ],
  fallback_policy: :first_available
}
```

`CropGuided` and `ResizeCover` may carry these guides directly. This avoids a
standalone smart-crop operation whose stage, dimensions, and output semantics
are ambiguous.

## Coordinate Spaces And Operation Order

Geometry-bearing operations must declare their coordinate space. The parser may
normalize vendor syntax into a common space, or it may preserve a source-space
request for resolver handling, but the plan must not leave this implicit.

Coordinates have both a reference space and a unit. A ratio coordinate is not a
space by itself; it must be resolved against the dimensions of its declared
space.

Coordinate spaces:

- `:current` means coordinates apply to the image as it exists at that point in
  the semantic pipeline.
- `:source` means coordinates apply to the original source image before later
  region/size/rotation stages.
- `:post_orient` means coordinates apply after orientation normalization but
  before later resize/crop work.
- `:vendor` is not allowed in canonical plan operations. Parser adapters must
  translate vendor-defined coordinates into one of the supported spaces or
  reject the request.

Coordinate units:

- `:pixels` means the coordinate value is pixel-based in the declared space.
- `:ratio` means the coordinate value is a deterministic rational value,
  usually in `0..1`, resolved against the declared space.

Examples:

```elixir
%ImagePlug.Plan.Geometry.Region{
  x: ...,
  y: ...,
  width: ...,
  height: ...,
  space: :source,
  unit: :pixels
}

%ImagePlug.Plan.Guide.FocalPoint{
  x: ...,
  y: ...,
  space: :source,
  unit: :ratio
}
```

Rules:

- `CropRegion` must carry a region with an explicit space.
- `CropGuided` must carry a size and guide with explicit units/spaces.
- `ResizeCover` guides must declare both reference space, such as `:current`,
  `:source`, or `:post_orient`, and unit, such as `:pixels` or `:ratio`.
- IIIF region syntax should map to `CropRegion` in source space.
- Imgproxy parser code should normalize crop/gravity syntax into explicit
  semantic value forms. Any value depending on source dimensions, current
  dimensions, orientation, DPR, or previous operations is resolved by
  `ImagePlug.Transform`, not by the parser.
- Resolver processes operations in order and updates current dimensions after
  each pixel-changing step.

Each geometry value struct must define its valid ratio range. Focal points are
normally bounded to `0..1`. Relative sizes may allow values greater than `1`
only when the operation explicitly supports enlargement. Offsets may allow
negative ratios only when documented by that operation.

Operation ordering remains a parser responsibility. Declarative parsers emit
operations in their canonical order. Ordered-command parsers emit operations in
the order required by the dialect.

## Orientation And Coordinate Semantics

Orientation operations must define how they affect later coordinate spaces:

- `AutoOrient` changes subsequent `:current` dimensions when it is present in
  the semantic operation order.
- `AutoOrient` does not change `:source` coordinates.
- `:post_orient` coordinates are resolved after EXIF orientation normalization
  and before later semantic operations.
- `Rotate` and `Flip` update subsequent `:current` dimensions or anchors.
- The MVP only supports orientation behavior that the current
  imgproxy-compatible surface already supports, including right-angle rotation
  if that is currently exposed. Arbitrary-angle rotation should be a fixture
  classification, not MVP behavior.

Geometry lowering should go through shared space-resolution helpers, for
example a future `ImagePlug.Transform.Geometry.Space.resolve_region/3`, instead
of duplicating coordinate conversion inside operations.

## Canonicalization Rules

Canonicalization is part of the semantic IR contract. It is not an
implementation afterthought, because cache material depends on it.

Rules:

- Parser aliases must be normalized before semantic operations are built.
- Output-affecting defaults must be explicit in canonical material.
- Equivalent aspect ratios should use reduced integer ratios, for example
  `{16, 9}` instead of `1.7777778`.
- Prefer integer pixels, integer ratios, and rational scale values over floats
  in semantic material.
- Parsed finite decimal values should be normalized to deterministic rational
  or scaled-integer forms before materialization.
- Strategy fallback list order is significant and must be preserved.
- Color values should normalize to a single representation, for example sRGB
  RGBA with integer color channels and deterministic alpha.
- Omitted dimensions must normalize according to the parser contract before
  materialization.
- Source-independent defaults should be inserted before prefetch-safe
  materialization when they affect output.
- Source-dependent values may remain as canonical semantic intent when the
  operation is deterministic for the source image and final pipeline order.
- No-op operations that do not affect visible output should be elided from
  canonical material after validation.
- Resolver decisions need separate material only when they introduce an
  output-affecting choice that is not already determined by source identity,
  canonical semantic material, configuration, backend profile, and pipeline
  order.

No canonical semantic operation may be introduced without a deterministic
material contract and tests proving parser-syntax-free equivalence. Example
shape:

```elixir
{:resize_fit, canonical_size, enlargement_policy}
{:crop_guided, canonical_size, canonical_guide}
{:canvas, canonical_size, canonical_placement, canonical_background}
```

The exact representation can be keyword lists or tuples, but it must be stable,
deterministic, and parser-syntax-free.

## Rounding, Clamping, And Error Policy

Every backend lowering eventually resolves to integer pixels. Rounding and
clamping must be centralized and documented per operation family.

The first implementation should preserve current imgproxy-compatible behavior
where it is already documented or tested. New behavior should choose explicit
rules before implementation.

Rules to define before each operation is implemented:

- size rounding: nearest, floor, or ceil
- crop origin rounding
- crop size minimums
- crop outside bounds: clamp, reject, or pad
- zero width/height after rounding
- negative offsets
- enlargement policy
- alpha/background behavior
- EXIF orientation impact on dimensions
- animated image behavior
- vector source behavior

Do not duplicate this logic across operation modules. Resolver and backend
lowering should call shared geometry helpers.

## DPR And Pixel Density

DPR must be explicit in plan material and resolver decisions when it affects
visible output.

Rules:

- Parser code records requested logical dimensions and requested DPR separately
  where the dialect exposes DPR.
- Canonical material must say whether a value is logical pixels, physical
  pixels, or a ratio.
- Resolver applies DPR at a documented phase before backend integer pixel
  lowering.
- Crop offsets or gravity offsets that are DPR-scaled must record that scaling
  decision in resolver material.
- DPR values that affect output must be part of cache material.

## Resolver Design

Expose a narrow public API:

```elixir
ImagePlug.Transform.resolve(%ImagePlug.Plan{} = plan, source_metadata, opts)
```

Internally, split responsibilities into phases even if they live under one
boundary:

```text
semantic validation
  -> source-independent normalization
  -> source-aware normalization
  -> capability planning
  -> backend lowering
  -> material decision collection
```

The external API should remain small. The implementation should avoid one
large `Resolver.resolve/3` function becoming the new overloaded center of the
system.

Inputs:

- semantic pipelines from `ImagePlug.Plan`
- source metadata: width, height, orientation metadata, alpha, format, and
  source type
- backend capability profile
- parser or compatibility policy
- config defaults that affect visible output

Outputs:

- resolved executable work
- diagnostics
- decisions that affect visible output
- optional resolver material contribution
- output metadata for later pipelines

Policy decides which diagnostics become errors. Decisions that affect pixels
are not just diagnostics. They become resolver material only when the existing
key material does not already determine the decision.

## Backend Representation

Resolved executable work should be internal to `ImagePlug.Transform`.

The initial implementation does not need to commit to a large backend operation
ontology. Two representations are acceptable:

- narrow internal structs under `ImagePlug.Transform.Backend.Operation.*`
- compact internal instructions such as `{:resize, args}` or `{:crop, args}`

The semantic boundary benefits most from narrow structs. The backend boundary
may use whichever representation is simpler, as long as it provides:

- generic runtime dispatch through `ImagePlug.Transform`
- deterministic material for visible backend decisions
- testable lowering output
- no runtime references to concrete semantic plan operation modules

Avoid three parallel abstractions where backend structs only wrap facade calls
without adding material, validation, or planning value.

## Capabilities And Executability

Capabilities should distinguish more than true or false support.

For each feature or strategy, capability planning should be able to answer:

- parser can understand the syntax
- semantic IR can represent the request
- local backend can execute it exactly
- local backend can approximate it
- configured policy allows approximation

This is the target model for vendor fixture expansion. The first implementation
does not need a general capability-planning framework unless the
imgproxy-compatible slice requires one.

A pragmatic first resolver result is enough:

```elixir
{:ok, exact_plan}
{:ok, approximate_plan, decisions, diagnostics}
{:error, diagnostics}
```

The richer profile can be introduced when a non-imgproxy fixture requires
representable-but-not-executable behavior.

Examples:

- exact crop: representable and executable
- entropy smart crop: representable and executable when libvips smartcrop is
  available
- face crop: representable, not executable by default
- Cloudinary automatic gravity: representable only as a strategy guide, not
  exact without a compatible detector/backend

Unsupported capability handling:

- Core resolver emits diagnostics.
- Policy decides whether unsupported behavior is fatal, fallback, or ignored.
- Strict parser modes reject unsupported smart/object/face operations before
  origin fetch when the lack of capability is known from configuration.
- Compatibility modes may allow declared fallbacks such as
  `faces -> entropy -> center`.

## Diagnostics And Decisions

Diagnostics describe what happened or what could not happen. Decisions describe
which output-affecting choice the resolver made.

Diagnostic fields:

- `severity: :info | :warning | :error`
- `code: atom`
- `pipeline_index`
- `operation_index`
- compact `details` map

Useful diagnostic codes:

- `:strategy_unavailable`
- `:strategy_fell_back`
- `:smart_crop_approximated`
- `:gravity_offset_approximated`
- `:backend_capability_missing`
- `:vendor_semantics_preserved_by_adapter`

Decision examples:

- selected `:entropy` after `:faces` was unavailable
- selected cover branch for orientation-based resize
- selected fit branch for orientation-based resize
- applied approximation mode for a guide strategy

Diagnostics that do not affect visible output do not belong in cache keys.
Decisions that affect visible output do belong in cache keys.

## Decode And Request-Safety Phases

Keep request-safety boundaries explicit:

```text
parse validation
  -> early semantic validation
  -> prefetch-safe cache material subset
  -> cache lookup / origin fetch
  -> decode/open planning
  -> post-decode source-aware resolution
  -> backend execution
  -> output encoding
```

Early validation:

- Runs before cache lookup or origin fetch.
- Rejects parser syntax errors, malformed semantic operation structs, unsupported
  configured capabilities known without source metadata, and invalid policy.

Cache lookup:

- Uses deterministic canonical material.
- Must include enough configuration and capability profile material to avoid
  stale entries when output-affecting resolver behavior changes.
- Final output cache material may include unresolved semantic intent such as
  imgproxy `resize:auto` when the operation is deterministic for the resolved
  source image and final pipeline order.
- Final output cache lookup does not need to wait for source metadata merely to
  replace deterministic semantic intent with resolved backend decisions.
- Final output cache lookup must wait for source metadata only when the final
  cache material truly depends on metadata not already represented by source
  identity, canonical semantic material, configuration, backend profile, output
  negotiation, and pipeline order.
- A future metadata cache may optimize source-metadata-dependent planning, but
  it is not required for correctness when deterministic unresolved semantic
  material is sufficient.

Decode/open planning:

- Uses semantic operations before image decode.
- Must choose a safe source access mode.
- Crop, focus-guided geometry, cover, canvas/letterbox, output-only, and
  source-metadata-dependent requests should remain conservative unless proven
  safe.

Post-decode resolution:

- May refine backend operations and future materialization decisions.
- Cannot invalidate an already-started source access mode.

This separates origin fetch, cache lookup, decode/open mode, and post-decode
execution planning instead of treating them as one boundary.

## Chained Pipelines

`ImagePlug.Plan.pipelines` remains a list. Each `ImagePlug.Plan.Pipeline` is a
semantic group boundary.

For imgproxy-style chained pipelines:

```text
/_/group1-options/-/group2-options/plain/image.jpg
```

the parser emits:

```elixir
%ImagePlug.Plan{
  pipelines: [
    %ImagePlug.Plan.Pipeline{operations: group1_semantic_ops},
    %ImagePlug.Plan.Pipeline{operations: group2_semantic_ops}
  ]
}
```

Semantics:

- Pipelines execute in list order.
- Pixel state flows from one pipeline to the next.
- Runtime preserves the materialization boundary between pipelines.
- Cache material preserves pipeline boundaries.
- Semantic context resets at each pipeline boundary by default.
- Each pipeline starts with default focus and gravity unless the adapter emits
  context commands that normalize into explicit guides for that pipeline.

If a dialect has persistent cross-group context, its parser must re-emit
context setters in later pipelines or use a future explicit persistence
mechanism. Persistence is not the default.

Tests should prove that repeated parser-emitted context gives the intended
cross-group behavior.

## Cache Material

Use explicit material layers:

```text
transform_material_version
semantic_material(plan)
resolver_material(extra_output_affecting_decisions)
backend_profile_material(profile)
output_material(output_negotiation)
```

The final key combines those layers with:

- resolved origin identity
- source path or source identity material
- configured vary inputs
- cachebuster
- parser compatibility mode
- config defaults that affect visible output

The transform material version must change when canonicalization, rounding,
resolver semantics, or backend decision material changes in a way that could
alter output or key interpretation.

Raw parser syntax, aliases, and vendor option spelling must not appear in cache
material.

Image operations are expected to be deterministic for a resolved source image
and final canonical pipeline order. Therefore, unresolved deterministic
semantic intent can be cache material. For example, imgproxy `resize:auto` may
remain `resize:auto` in semantic material instead of forcing the selected fit
or cover branch into the key.

Resolver decisions appear in resolver material only when they add
output-affecting information not already determined by source identity,
semantic material, backend profile, configuration, output negotiation, and
pipeline order. Backend capability profile changes that can alter pixels must
appear in backend profile material. This prevents a deployment that gains face
detection or changes smartcrop strategy support from reusing stale cache entries
produced by older behavior.

## Parser And Vendor Mapping

Vendor mapping fixtures should drive IR expansion. Each fixture should classify
a mapping as:

- supported now
- representable but not executable
- intentionally unsupported
- lossy approximation

Add new semantic operations only when a fixture cannot be represented cleanly
with the current core.

First-wave fixtures:

- imgproxy, the compatibility target
- TwicPics, to test context mutation and ordered chains
- IIIF, to test source-space region/size semantics

Second-wave fixtures:

- imgix
- Cloudinary
- Fastly

### Imgproxy

The current `ImagePlug.Parser.Native` should be renamed to
`ImagePlug.Parser.Imgproxy`.

The current `docs/native_path_api.md` should become imgproxy-specific
documentation, for example `docs/imgproxy_path_api.md`.

The previous "Native" URL semantics are an imgproxy-compatible subset, not an
ImagePlug-native URL API. The native ImagePlug model is the Plan IR, not a URL
syntax. A future ImagePlug-native URL syntax should be designed separately and
must not inherit imgproxy quirks by default.

Mapping:

- `gravity` maps to an adapter-local gravity context command, scoped to the
  current pipeline group, or directly to explicit guides on crop/cover
  operations.
- `crop` maps to `CropGuided`; crop-specific gravity becomes an explicit guide
  or local gravity override.
- Crop dimension rules remain parser-owned:
  - `0` means full current/source dimension for that axis.
  - `abs(value) < 1` means relative scale.
  - `abs(value) >= 1` means pixels.
- `resize:fit` maps to `ResizeFit`.
- `resize:fill` and `resize:fill-down` map to `ResizeCover` with enlargement
  policy.
- `resize:force` maps to `ResizeStretch`.
- `resize:auto` maps to an imgproxy adapter-owned compatibility command and is
  resolved to `ResizeCover` or `ResizeFit` after source dimensions are known.
  The selected branch is resolver material.
- `extend` and `extend_aspect_ratio` map to `Canvas`.
- Smart/object/face gravity maps to strategy guides only when parser policy
  supports those strategies.

### TwicPics

Mapping pressure tests:

- `focus=<anchor>` maps to adapter-local focus context.
- `focus=<x,y>` maps to adapter-local focus context.
- `focus=auto` maps to a strategy guide and is capability-gated.
- `crop=<w>x<h>` maps to `CropGuided` with focus guide.
- `crop=<w>x<h>@<x,y>` maps to `CropRegion`.
- Omitted crop dimensions mean current input dimensions on that axis, not
  aspect-ratio completion.
- Coordinates may mix units.
- Explicit coordinate crop resets focus to the center of the resulting image
  for later operations in the same pipeline.

### Imgix

Second-wave mapping notes:

- `fit=crop&w=...&h=...` maps to `ResizeCover`, not source-region crop.
- `crop=top,bottom,left,right` maps to cover alignment or guide preferences.
- Ordered fallback lists preserve order.
- `crop=focalpoint` plus `fp-x` and `fp-y` maps to focal guided cover.
- `fp-z` needs explicit zoom or focus-region semantics; do not hide it in
  gravity.
- `crop=faces`, `crop=entropy`, and `crop=edges` map to ordered strategy
  guides on a concrete crop or cover operation.
- `fit=fill` and background modes map to `ResizeFit` plus `Canvas` when visible
  padding/background is requested.

### Cloudinary

Second-wave mapping notes:

- fill maps to cover-style resize/crop behavior.
- fit maps to fit-style resize behavior.
- pad and fill-pad map to fit/cover plus explicit canvas behavior where
  semantics match cleanly.
- automatic gravity, face gravity, and object gravity map to strategy guides
  and require capability planning.
- Cloudinary-specific automatic behavior should be classified as exact,
  representable-but-not-executable, approximate, or unsupported; do not hide it
  behind generic smart crop.

### Fastly

Second-wave mapping notes:

- Fastly has a documented operation order. Its parser should emit an ordered
  semantic pipeline matching that order.
- If Fastly exposes meaningful group or materialization boundaries, those
  should become separate `Plan.Pipeline` entries; otherwise one ordered
  semantic pipeline is sufficient.

### IIIF

IIIF region syntax maps to `CropRegion` with source-space coordinates and
parser-owned pixel/percent validation plus clamp behavior. IIIF size syntax
should map to fit, stretch, or scale depending on the exact IIIF size form.

## Boundary Rules

Boundary direction should remain explicit:

- Parser depends on Plan and exported semantic operation constructors.
- Plan owns the canonical request model and semantic operation structs.
- Transform owns resolver phases, backend representation, decode planning,
  execution, and materialization.
- Request runtime/orchestration depends on Plan, Cache, Output, and generic
  Transform entry points. It must not contain operation-specific branching or
  reference concrete plan operation modules.
- The Transform resolver/executor may pattern match on concrete semantic
  operations and backend instructions inside the Transform boundary.
- Cache may depend on Plan semantic material and Transform resolver material
  facades, but not parser-specific structs.

Boundary exports should stay narrow. Do not export implementation helpers just
to satisfy compile errors.

## Test Strategy

Resolver tests should come first for the current imgproxy-compatible subset:

- imgproxy crop `0`, `<1`, and `>=1` dimensions resolve correctly.
- imgproxy gravity offsets resolve with DPR behavior.
- imgproxy fill/down/force/fit map to the expected semantic operations.
- imgproxy auto behavior chooses the expected fit or cover branch.
- canvas extension updates dimensions independently from crop.
- chained pipelines reset semantic focus/gravity context while preserving pixel
  state and pipeline material boundaries.

Characterization and old-vs-new equivalence tests should freeze current
imgproxy-compatible behavior before replacing internals:

- parser output for documented options
- output dimensions for representative resize/crop/canvas/orientation requests
- crop regions or backend operation parameters where stable
- encoded image hash where stable, or pixel/perceptual diff where encoding is
  not stable
- cache key material expectations

Canonicalization tests should cover:

- aliases normalize away before material
- equivalent ratios produce identical material
- strategy fallback order is preserved
- parser defaults become explicit material only when output-affecting
- no-op operations are elided when they do not affect visible output
- color and unit normalization are deterministic
- normalization is idempotent
- material generation is deterministic across repeated normalization
- visibly different outputs do not intentionally collapse to the same material

Geometry helper tests should cover:

- clamped crop regions never produce dimensions outside resolved bounds
- rounding never produces zero-size backend operations unless validation rejects
  the request first
- no-op elimination is idempotent

Vendor mapping fixtures should cover imgproxy, TwicPics, and IIIF first as
non-executing tests before full parsers are implemented. Each fixture should
classify support as supported, representable, intentionally unsupported, or
approximate. Imgix, Cloudinary, and Fastly fixtures are second-wave pressure
tests after the first resolver slice lands.

Runtime tests should stay focused:

- no origin fetch/cache lookup before parser or early resolver validation
  failures
- runtime dispatch remains generic
- decode planning remains conservative for random-access operations
- multi-pipeline materialization still happens between pipeline groups

Cache tests should assert:

- semantic material changes when semantic operation fields change
- parser aliases do not affect material after normalization
- pipeline boundaries are preserved in material
- deterministic unresolved semantic intent, such as imgproxy `resize:auto`, is
  sufficient cache material when source identity and pipeline order determine
  the output
- resolver fallback decisions are included only when they add output-affecting
  information not already determined by existing key material
- backend capability profile changes that affect pixels change material

Boundary tests should assert:

- runtime does not depend on concrete plan operation modules
- runtime does not depend on concrete backend operation modules
- runtime does not depend on parser-specific structs

## Revised Implementation Sequence

Because the project is greenfield, prefer replacement over compatibility shims,
but keep the first slice narrow.

1. Add characterization tests for current imgproxy-compatible parser,
   transform, cache, and chained-pipeline behavior.
2. Rename `Native` parser/docs/tests to `Imgproxy`.
3. Add canonical geometry/value structs and material functions.
4. Introduce minimal semantic operations needed for current
   imgproxy-compatible behavior.
5. Add resolver phases that validate and lower only the current
   imgproxy-compatible subset.
6. Initially lower to the existing executable transform representation where
   possible.
7. Add backend instruction or operation representation only when existing
   operations block correctness, materialization, or generic dispatch.
8. Switch parser output to semantic operations.
9. Switch cache/decode/runtime to consume resolved output through generic
   facades.
10. Add first-wave vendor mapping fixtures for imgproxy, TwicPics, and IIIF as
   non-executing tests.
11. Expand semantic IR only for mappings that fail those fixtures.
12. Add second-wave mapping fixtures for imgix, Cloudinary, and Fastly.
13. Add actual parsers incrementally.

## Non-Goals

- Implementing this design in this document.
- Full parser implementations for TwicPics, imgix, Cloudinary, Fastly, IIIF,
  Thumbor, or ImageKit.
- External face or object detector integration.
- Output format negotiation changes.
- Cache storage adapter changes.
- Public backwards compatibility for current internal transform operation
  structs.
- A complete image-transformation ontology before vendor fixtures prove the
  need.
