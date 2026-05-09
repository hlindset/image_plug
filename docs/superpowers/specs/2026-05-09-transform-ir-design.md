# Transform IR Design

## Status

Approved design for a later implementation plan. This document replaces the
earlier design seed from another worktree and records the decisions from the
2026-05-09 design round.

This is design only. It does not approve implementation by itself.

## Goals

ImagePlug needs a greenfield transform IR that can represent product-neutral
image intent before resolving that intent into local backend work. The design
must support imgproxy-compatible semantics now and leave room for TwicPics,
imgix, Cloudinary, Fastly, IIIF, and similar APIs without forcing vendor quirks
into the core model.

Constraints:

- Backwards compatibility with current internal transform structs is not
  required.
- Prefer narrow Elixir structs and pattern matching over tagged mega-structs.
- Vendor-specific quirks belong in parser or adapter layers.
- Runtime must remain generic and must not depend on concrete transform
  operation modules.
- Parser and resolver validation failures that can be known before origin fetch
  must still fail before origin fetch or cache lookup.

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

That is manageable for the current imgproxy-like subset, but it will become
unclear for TwicPics focus state, imgix fallback crop strategies, Cloudinary
automatic gravity, Fastly ordered transforms, and IIIF exact regions.

## Architecture Decision

Use a semantic plan IR plus backend lowering.

Target flow:

```text
ImagePlug.Parser.*
  -> ImagePlug.Plan
       source/output/policy/cache/response
       pipelines: [%ImagePlug.Plan.Pipeline{
         operations: [%ImagePlug.Plan.Operation.*{}]
       }]
  -> ImagePlug.Transform.Resolver
       validates semantic operations
       applies source metadata
       applies backend capabilities
       records diagnostics
       lowers to backend executable operations
  -> ImagePlug.Transform.Backend.Pipeline
       operations: [%ImagePlug.Transform.Backend.Operation.*{}]
  -> ImagePlug.Transform facade
       executes without runtime naming concrete operation modules
```

`ImagePlug.Plan.Pipeline` remains the canonical request pipeline container.
Its `operations` field should contain semantic `ImagePlug.Plan.Operation.*`
structs, not executable transform structs.

The resolver belongs under `ImagePlug.Transform` because it owns transform
semantics, source-metadata resolution, decode implications, capability checks,
and backend lowering. `ImagePlug.Plan` should not depend on concrete backends.
Parsers may construct exported plan operation structs. Runtime should not
construct or reference concrete semantic or backend operation modules directly.

## Semantic Operation Family

Define narrow operation structs under `ImagePlug.Plan.Operation.*`. Avoid tagged
structs where a `type` or `kind` field changes the required fields and behavior.

### Context Operations

`SetFocus` sets focus context for later focus-aware operations. It does not
modify pixels. It should support:

- anchor focus
- normalized coordinate focus
- absolute or relative coordinate focus
- smart focus intent

`SetGravity` sets gravity context for later gravity-aware operations. It does
not modify pixels. It should support:

- anchor gravity
- focal-point gravity
- offsets
- smart, face, object, or similar neutral strategy intent

Focus and gravity are related but not identical. Vendors use both terms with
different semantics, so the IR should not collapse them.

Parser adapters must not store vendor-specific state in these operations.
Adapters should translate vendor quirks into neutral focus/gravity values or
reject them before plan construction.

### Crop Operations

`CropRegion` represents exact or percent region extraction from current image
coordinates. It is the right model for IIIF pixel/percent regions and explicit
TwicPics coordinate crops.

`CropGuided` crops to a requested size using focus, gravity, or an explicit
guide. It is the right model for imgproxy crop, TwicPics focus-guided crop, and
similar guide-based crops.

`CropAspectRatio` crops the current image area to a target ratio before later
operations.

`CropSmart` represents content-derived crop intent with ordered strategies and
fallbacks. Strategies may include `:faces`, `:objects`, `:attention`,
`:entropy`, `:edges`, and `:center`. Face and object strategies require
external detector capabilities and are not available by default.

### Resize Operations

`ResizeFit` resizes proportionally inside a target box.

`ResizeCover` resizes proportionally to cover a target box. It should carry
guide or alignment fields so imgix `fit=crop&crop=...`, Cloudinary gravity,
and imgproxy fill gravity stay coherent as one semantic request.

`ResizeContain` resizes proportionally inside a target box with optional
canvas/letterbox intent. When visible background expansion is needed, the
resolver lowers it to resize plus backend canvas/embed work.

`ResizeStretch` resizes non-proportionally to requested width and height.

`ResizeScale` scales by one factor or independent x/y factors.

`ResizeAdaptive` models imgproxy `auto` behavior where fit versus cover depends
on source and target orientation.

### Layout Operations

`Pad` models side-specific padding around the current image.

`Canvas` models a target canvas by dimensions or aspect-ratio frame, with
placement and background. It replaces the current overloaded `ExtendCanvas`.

Do not introduce `Letterbox` as a first-class operation initially. Represent
letterboxing as contain/fit plus canvas intent.

### Orientation And Content Operations

Keep narrow semantic operations for:

- `AutoOrient`
- `Rotate`
- `Flip`
- `Trim`

`Trim` removes uniform or near-uniform borders and needs threshold/background
options.

## Shared Value Structs

Use small shared value structs where they reduce ambiguity across operations:

- `ImagePlug.Plan.Geometry.Size`
- `ImagePlug.Plan.Geometry.Region`
- `ImagePlug.Plan.Geometry.Ratio`
- `ImagePlug.Plan.Geometry.Offset`
- `ImagePlug.Plan.Geometry.Gravity`
- `ImagePlug.Plan.Geometry.Focus`
- `ImagePlug.Plan.Geometry.Color`

These structs should model semantic request values. Backend-specific resolved
values belong under `ImagePlug.Transform.Backend` or resolver internals.

## Resolver Design

The resolver is a pure transform-boundary step:

```elixir
ImagePlug.Transform.Resolver.resolve(pipelines, source_metadata, opts)
```

Inputs:

- semantic pipelines from `ImagePlug.Plan`
- source metadata: width, height, orientation metadata, alpha, format, and
  source type
- backend capabilities
- parser or compatibility policy

Context:

- current width and height
- current focus, default center
- current gravity, default center
- current orientation state after semantic orientation operations
- diagnostics accumulated in order
- selected backend capabilities

Output:

```elixir
%ImagePlug.Transform.Resolved{
  pipelines: [%ImagePlug.Transform.Backend.Pipeline{}],
  diagnostics: [%ImagePlug.Transform.Resolver.Diagnostic{}],
  material: term()
}
```

The resolver returns `{:ok, resolved}` or `{:error, reason}`. Policy decides
which diagnostics become errors.

## Backend Operations

Resolved executable work should live under an internal backend namespace, not
in the semantic plan namespace.

Initial backend operation family:

- `ImagePlug.Transform.Backend.Operation.Resize`
- `ImagePlug.Transform.Backend.Operation.Crop`
- `ImagePlug.Transform.Backend.Operation.EmbedCanvas`
- `ImagePlug.Transform.Backend.Operation.Trim`
- `ImagePlug.Transform.Backend.Operation.SmartCrop`
- `ImagePlug.Transform.Backend.Operation.AutoOrient`
- `ImagePlug.Transform.Backend.Operation.Rotate`
- `ImagePlug.Transform.Backend.Operation.Flip`

Backend operations may be lower-level than semantic operations. They represent
what the selected local backend will actually execute through Image, Vix, or
libvips-backed calls.

Runtime must still execute through generic transform facade functions. Boundary
tests should reject direct runtime references to concrete backend operations in
the same way they currently reject direct runtime references to concrete
transform operations.

## Capabilities

Use a capability struct, not a raw map. Default local capabilities should be
explicit and conservative.

Initial capability fields should cover:

- exact crop
- resize
- canvas embed
- trim
- smartcrop attention
- smartcrop entropy
- face detection
- object detection
- edge detection

Capability checks belong in the resolver. Parser syntax validation remains in
parser modules.

Unsupported capability handling:

- Core resolver emits diagnostics.
- Parser policy decides whether diagnostics are fatal, fallback, or ignored.
- Strict parser modes reject unsupported smart/object/face operations before
  origin fetch when the lack of capability is known from configuration.
- Compatibility modes may allow declared fallbacks such as
  `faces -> entropy -> center`.

## Diagnostics

Use structured diagnostic structs instead of loose atoms.

Fields:

- `severity: :info | :warning | :error`
- `code: atom`
- `pipeline_index`
- `operation_index`
- compact `details` map
- policy result after application: `:fatal | :fallback | :ignored`

Useful diagnostic codes:

- `:strategy_unavailable`
- `:strategy_fell_back`
- `:smart_crop_approximated`
- `:gravity_offset_approximated`
- `:backend_capability_missing`
- `:vendor_semantics_preserved_by_adapter`

Diagnostics that do not affect visible output do not belong in cache keys.
Resolver decisions that change pixels must be deterministic cache material.

## Decode Planning

Decode planning needs two phases.

Pre-decode planning:

- Uses semantic operations.
- Runs before origin decode.
- Must be conservative.
- Empty/no-geometry, crop, focus, cover, letterboxing/canvas, output-only, and
  source-metadata-dependent requests should continue to use random access.

Post-resolution planning:

- Uses resolved backend operations.
- Can guide materialization between pipelines and final delivery.
- Must not weaken the conservative pre-decode decision for already-opened
  sources.

This preserves the current safety stance while allowing source-aware lowering.

## Chained Pipelines

`ImagePlug.Plan.pipelines` remains a list. Each `ImagePlug.Plan.Pipeline` is a
semantic group boundary, not just a list chunk.

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
- Semantic context does not implicitly flow across pipeline boundaries.
- Each pipeline starts with default focus and gravity unless the parser emits
  `SetFocus` or `SetGravity` in that pipeline.

If a dialect truly has cross-group persistent context, its parser should
re-emit context setters in later pipelines or a future explicit persistence
field can be designed. Persistence must not be the default.

The resolver processes pipelines sequentially:

```text
source metadata
  -> resolve pipeline 1, producing backend ops and output metadata
  -> reset semantic context to defaults
  -> resolve pipeline 2 against pipeline-1 output metadata
  -> ...
```

Resolved output preserves the same grouping.

## Cache Material

Cache material should be based primarily on semantic plan material:

- source identity
- semantic pipeline material, preserving pipeline boundaries
- output negotiation material
- cachebuster and configured vary inputs

If the resolver makes a capability-sensitive or fallback decision that changes
pixels, that decision must become deterministic cache material. Examples:

- smart crop falls back from `:faces` to `:entropy`
- `ResizeAdaptive` resolves to cover versus fit
- a capability approximation changes the backend operation sequence

The cache key should not include parser-specific option names, aliases, or raw
vendor syntax.

## Parser And Vendor Mapping

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

- `gravity` maps to `SetGravity`, scoped to the current pipeline group.
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
- `resize:auto` maps to `ResizeAdaptive`.
- `extend` and `extend_aspect_ratio` map to `Canvas`.
- Explicit side padding maps to `Pad`.
- Smart/object/face gravity maps to neutral smart strategies only when parser
  policy supports those strategies.

### TwicPics

Mapping:

- `focus=<anchor>` maps to `SetFocus`.
- `focus=<x,y>` maps to `SetFocus`.
- `focus=auto` maps to smart focus intent and is capability-gated.
- `crop=<w>x<h>` maps to `CropGuided` with `guide: :focus`.
- `crop=<w>x<h>@<x,y>` maps to `CropRegion`.
- Omitted crop dimensions mean current input dimensions on that axis, not
  aspect-ratio completion.
- Coordinates may mix units.
- Explicit coordinate crop resets focus to the center of the resulting image
  for later operations in the same pipeline.

### Imgix

Mapping:

- `fit=crop&w=...&h=...` maps to `ResizeCover`, not source-region crop.
- `crop=top,bottom,left,right` maps to cover alignment or guide preferences.
- Ordered fallback lists preserve order.
- `crop=focalpoint` plus `fp-x` and `fp-y` maps to focal guided cover.
- `fp-z` needs explicit zoom or focus-region semantics; do not hide it in
  gravity.
- `crop=faces`, `crop=entropy`, and `crop=edges` map to ordered smart
  strategies.
- `fit=fill` and background modes map to `ResizeContain` plus `Canvas` when
  visible padding/background is requested.

### Cloudinary

Cloudinary fill, fit, pad, and fill-pad semantics should map to `ResizeCover`,
`ResizeFit`, `ResizeContain`, `Canvas`, and smart strategy guides where
semantics match cleanly. Automatic gravity, face gravity, and object gravity
are capability-gated smart strategies.

### Fastly

Fastly has a documented operation order. Its parser should emit an ordered
semantic pipeline matching that order. If Fastly exposes meaningful group or
materialization boundaries, those should become separate `Plan.Pipeline`
entries; otherwise one ordered semantic pipeline is sufficient.

### IIIF

IIIF region syntax maps cleanly to `CropRegion` with parser-owned pixel and
percent validation plus clamp behavior. IIIF size syntax should map to fit,
stretch, or scale depending on the exact IIIF size form.

## Boundary Rules

Boundary direction should remain explicit:

- Parser depends on Plan and exported semantic operation constructors.
- Plan owns the canonical request model and semantic operation structs.
- Transform owns resolver, backend operations, decode planning, execution, and
  materialization.
- Runtime depends on Plan, Cache, Output, and generic Transform entry points.
- Runtime must not reference concrete plan operation modules or backend
  operation modules.
- Cache may depend on Plan semantic material and Transform resolver material
  facades, but not parser-specific structs.

Boundary exports should stay narrow. Do not export implementation helpers just
to satisfy compile errors.

## Test Strategy

Resolver tests should come first:

- TwicPics focus coordinates guide a later crop.
- TwicPics anchor focus guides a later crop.
- TwicPics explicit crop coordinates create a region crop and reset focus.
- TwicPics omitted crop dimensions use current image dimensions.
- imgproxy crop `0`, `<1`, and `>=1` dimensions resolve correctly.
- imgproxy gravity offsets resolve with DPR behavior.
- imgix `fit=crop` maps to cover resize, not source-region crop.
- imgix ordered crop strategy fallback is preserved.
- IIIF pixel and percent regions clamp at image edges.
- `CropSmart` emits unsupported capability diagnostics for face/object crops.
- `CropSmart` lowers entropy/attention to Vix smartcrop when available.
- Padding and canvas update dimensions independently from crop.
- Chained pipelines reset semantic focus/gravity context while preserving pixel
  state and pipeline material boundaries.

Parser tests should assert syntax-to-semantic mapping, not backend execution.

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
- resolver fallback decisions that affect pixels are included deterministically

Boundary tests should assert:

- runtime does not depend on concrete plan operation modules
- runtime does not depend on concrete backend operation modules
- runtime does not depend on parser-specific structs

## Migration Strategy

Because the project is greenfield, prefer replacement over compatibility shims.

Likely implementation sequence for a later plan:

1. Rename `Native` parser/docs/tests to `Imgproxy`.
2. Introduce semantic plan operation structs and shared plan geometry structs.
3. Add semantic material support for plan operations.
4. Add resolver context, capabilities, diagnostics, and resolved pipeline
   structs.
5. Add backend operation namespace and backend material/execution facade.
6. Implement resolver lowering for current imgproxy-compatible behavior.
7. Replace current parser output with semantic plan operations.
8. Update runtime/cache/decode planning to use resolver outputs through generic
   facades.
9. Remove or rewrite overloaded current operations and tests.
10. Add TwicPics, imgix, IIIF, Cloudinary, and Fastly mappings incrementally.

## Non-Goals

- Implementing this design in this document.
- Full parser implementations for TwicPics, imgix, Cloudinary, Fastly, IIIF,
  Thumbor, or ImageKit.
- External face or object detector integration.
- Output format negotiation changes.
- Cache storage adapter changes.
- Public backwards compatibility for current internal transform operation
  structs.
