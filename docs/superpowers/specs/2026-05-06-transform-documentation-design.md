# Transform Documentation Design

## Purpose

ImagePlug needs clearer documentation for three related but distinct audiences:

- Users of the current Native path API, which uses imgproxy-compatible option names where supported.
- Parser and dialect authors mapping URL syntax into ImagePlug's neutral plan and transform model.
- Contributors maintaining or constructing a specific transform operation.

The documentation should make the current URL API easy to use without requiring users to learn internal transform structs, while also making the transform operation model explicit enough for future dialects such as Thumbor, TwicPics, imgix, or Cloudinary to translate into `ImagePlug.Plan` consistently.

## Documentation Structure

Add four documentation layers with different roles:

1. `docs/native_path_api.md`
   - User-facing reference for the current Native path API.
   - Documents URL structure, accepted options, aliases, values, examples, and response/cache/output behavior.
   - Treats imgproxy-compatible option names, where supported by ImagePlug, as the current public Native URL surface.
   - Documents Native's declarative fixed operation order as a Native API contract.

2. `docs/transform_operations.md`
   - Orientation guide for parser and dialect authors.
   - Explains the product-neutral transform model, operation ordering considerations, and how parsed dialect concepts map into operation choices.
   - Helps readers decide which `ImagePlug.Transform.*` operation should represent a dialect feature before they open a specific module reference.
   - Describes which request concepts are not transforms, such as output quality, cachebuster, expires, filename, and attachment disposition.

3. `@moduledoc` on exported transform modules
   - Authoritative per-operation contract for contributors maintaining or constructing that operation.
   - Documents struct fields, accepted values, execution semantics, decode-planning metadata, material/cache implications, and construction examples.

4. `@moduledoc` on shared transform contracts
   - Documents shared behaviours, protocols, state, and geometry helpers that operation module docs rely on.
   - Covers `ImagePlug.Transform`, `ImagePlug.Transform.Chain`, `ImagePlug.Transform.DecodePlanner`, `ImagePlug.Transform.Materializer`, `ImagePlug.Transform.State`, `ImagePlug.Transform.Material`, `ImagePlug.Transform.Geometry.DimensionRule`, `ImagePlug.Transform.Geometry.DimensionResolver`, and `ImagePlug.Transform.Geometry.CropCoordinateMapper`.

The README should remain a concise entry point and link to the two guide documents instead of duplicating their full content.

## Native Path API Guide

`docs/native_path_api.md` should be written for users building URLs. It should not require understanding internal parser modules or transform structs.

The guide should open with a mental model:

- A Native URL describes desired output, not a step-by-step image pipeline.
- ImagePlug normalizes aliases, resolves conflicts, builds a product-neutral plan, and executes transforms in canonical order.
- URL option order is not execution order.

It must document:

- URL shape, source path handling, and the `-` pipeline separator.
- Declarative semantics: URL option order does not define transform execution order.
- Conflict behavior: later assignments to the same canonical field win.
- Resize options, including `resizing_type`, the difference between fixed resize types and `auto`, and zero dimensions as auto dimensions.
- Width, height, min dimensions, zoom, DPR, enlarge behavior, and `force` resize behavior when one side is auto.
- Crop, top-level gravity, crop-specific gravity, focal-point gravity, result-crop behavior, and crop gravity inheritance.
- Crop and gravity offsets, including the current imgproxy-compatible unit rule where absolute values greater than or equal to `1` are pixels and absolute values below `1` are relative scale offsets.
- Orientation options: auto-orient, rotate, and flip.
- Canvas extension and extend-aspect-ratio behavior.
- Output negotiation: format, automatic output by omitting an explicit format, quality, and format-specific quality.
- Plain source `@extension` output syntax, including its current precedence relative to explicit `format` options.
- Cache and policy fields: cachebuster and expires.
- Response fields: filename and attachment disposition.
- Unsupported imgproxy options are not silently ignored. Options outside this supported Native slice are rejected.
- Examples for common URL patterns.

The guide must state that imgproxy-compatible naming is accepted at the Native grammar boundary, but ImagePlug processing remains declarative and product-neutral internally.

Native operation ordering must be explicit:

- Native URL option order is not transform execution order.
- Native planner order is orientation, crop, resize/adaptive resize, result crop, then canvas extension.
- Orientation suborder is auto-orient, rotate, then flip.
- Non-empty pipeline groups separated by `-` execute in URL group order.
- Within each pipeline group, transform options are still planned in Native canonical order.
- This fixed order is a Native API contract. It should not be described as a universal requirement for every future dialect.

Conflict normalization must be explicit:

- Aliases are normalized before conflict resolution.
- If multiple URL options map to the same canonical request field, the last occurrence in the URL wins.
- Conflict resolution applies to canonical request fields, not raw option names. For example, `w` and `width` conflict when both map to width; `rt` and `resizing_type` conflict when both map to resizing type.
- Generic quality and format-specific quality should be documented as separate canonical fields unless implementation tests prove otherwise.
- Pipeline separators create separate pipeline groups for transform options.
- Global options can appear across groups and still resolve by canonical field.
- Duplicate transform fields are scoped to their pipeline group.
- Empty pipeline groups are ignored if that remains current parser behavior.

Unsupported and invalid option behavior should include a small table:

| Case | Behavior |
| --- | --- |
| Unknown option | Rejected |
| Known imgproxy option outside the supported Native slice | Rejected |
| Supported option with invalid value | Rejected |
| Valid syntax with unsupported combined semantics | Rejected |
| Duplicate canonical field | Last value wins |

The guide should state the request-level result for rejected options, including the HTTP status and whether rejection happens before origin fetch and cache lookup. It should explicitly say that unsupported features such as trim are rejected if mentioned, not listed as supported behavior.

The guide should explicitly say `format:auto` is not accepted. Automatic output negotiation is selected by omitting an explicit format.

The guide should explicitly document plain source `@extension` as output format syntax. It should state that `@extension` bypasses `Accept` negotiation like explicit `format`, and it should document current precedence when both an option format and source `@extension` are present.

Semantic rejection examples must be verified against tests and current planner behavior. After the imgproxy Native parity fixes in `5b9eeff`, the Native guide must not describe these supported behaviors as rejection cases:

- Crop combined with auto-orient is supported and planned in Native canonical order.
- Top-level gravity offsets are supported for result crops.
- `force` resize with one zero dimension is supported by preserving the source dimension for the auto side.
- Explicit crop gravity variants, including focal-point crop gravity, are supported.
- Explicit crop without its own gravity inherits top-level gravity.

The remaining semantic rejection examples should focus on behavior that is still intentionally unsupported, such as smart gravity (`g:sm` or `c:<width>:<height>:sm`) returning `{:unsupported_gravity, :sm}`. SVG/vector-specific imgproxy parity remains out of scope for this documentation pass unless the implementation changes before docs are written.

The guide should document the current zero-dimension behavior:

- `w:0` and `h:0` map to auto dimensions.
- Fit/fill with both sides zero produces no geometry transform unless min dimensions or another meaningful size constraint is present.
- Zoom and DPR do not force raster enlargement for zero-dimension auto sides when `enlarge` is false.
- `rt:force` with one zero side keeps force semantics while preserving the source dimension for that side.

The guide should document the current crop/gravity behavior:

- Top-level `g:*` applies to result crops produced by fill/fill-down/auto resize planning.
- Top-level result-crop absolute offsets are resolved by crop execution using the effective DPR.
- Explicit crop gravity overrides top-level gravity for that crop.
- Explicit crop without gravity inherits top-level gravity.
- Crop focal-point gravity uses crop gravity fields, not `ImagePlug.Transform.Focus`.
- Crop offset signs and unit interpretation must match current imgproxy-compatible parsing and execution tests.

## Transform Operations Guide

`docs/transform_operations.md` should be written for parser and dialect authors translating external syntax into `ImagePlug.Plan`. It should answer "which operation should I use for this image-processing concept?" rather than repeat every field-level contract from module docs.

It must document:

- The canonical request flow: parser syntax -> parser request structs -> `ImagePlug.Plan` -> transform operations -> runtime execution.
- Operation ordering as a parser/adapter design concern:
  - Operation chains are ordered once represented in `ImagePlug.Plan`.
  - Native URLs are declarative, and Native planner code emits operations in the Native canonical order documented in `docs/native_path_api.md`.
  - Other dialects may have order-sensitive semantics. If a compatibility dialect needs ordered command behavior, that behavior belongs in the dialect parser/adapter and should not force ordered semantics into the Native API or product-neutral transform operation contracts.
  - Dialect parsers should still translate into `ImagePlug.Plan` when semantics match cleanly; dialect-specific quirks stay isolated in parser/adapter code.
- The complete exported operation catalog:
  - `ImagePlug.Transform.Scale`
  - `ImagePlug.Transform.Contain`
  - `ImagePlug.Transform.Cover`
  - `ImagePlug.Transform.Crop`
  - `ImagePlug.Transform.Focus`
  - `ImagePlug.Transform.Resize`
  - `ImagePlug.Transform.AdaptiveResize`
  - `ImagePlug.Transform.ExtendCanvas`
  - `ImagePlug.Transform.AutoOrient`
  - `ImagePlug.Transform.Rotate`
  - `ImagePlug.Transform.Flip`
- Decision guidance for similar operations:
  - Use `Resize` when the resize mode is known at planning time.
  - Use `AdaptiveResize` for runtime-dependent auto resize semantics.
  - Use `Resize` plus result `Crop` for fill/cover-style target crops when that matches the dialect.
  - Use `ExtendCanvas` for letterboxing/padding/canvas expansion, not for normal resize.
  - Use `Focus` to set focus state for later crop operations rather than as a visible image operation by itself.
- The relationship between resize-like operations:
  - `ImagePlug.Transform.Resize` represents the newer planned resize operation whose mode is known at planning time.
  - `ImagePlug.Transform.AdaptiveResize` represents runtime-dependent auto resize semantics.
  - `ImagePlug.Transform.Scale`, `ImagePlug.Transform.Contain`, and `ImagePlug.Transform.Cover` are exported standalone operations and should be documented as such, including when dialect authors should emit them directly instead of `Resize`.
  - The guide must avoid implying that `Scale`, `Contain`, or `Cover` are merely implementation details of `Resize` unless the code changes to make that true.
- Why operation choice matters for decode planning:
  - Dialect authors should choose the most semantically accurate operation instead of forcing everything into generic resize/crop operations.
  - Operation metadata can affect sequential versus random image access.
  - The exact `metadata/1` contract belongs in module docs.
- Cache material implications:
  - Transform material should represent canonical operation semantics.
  - Parser-specific quirks should not leak into transform material.
- A named section for request fields that are not transform operations:
  - Source path and source URL handling.
  - Output format and automatic output negotiation.
  - Generic quality and format-specific quality.
  - Cachebuster.
  - Expires.
  - Filename.
  - Attachment disposition.
- Boundary rules:
  - Runtime dispatches through `ImagePlug.Transform`.
  - Runtime should not depend on parser-specific Native structs.
  - Parser-specific request structs must not leak into runtime execution.
  - Parser and planner modules may construct exported operation structs.

The guide should include mapping examples from Native URLs to operation chains, including at least fixed resize, adaptive resize, fill with result crop, crop with gravity, focal-point gravity crop, explicit crop inheriting top-level gravity, orientation, canvas extension, and zero-dimension resize.
Native mapping examples should reflect current Native behavior. Native focal-point gravity should be shown as `ImagePlug.Transform.Crop` gravity, not as `ImagePlug.Transform.Focus`, unless the planner starts emitting `Focus`. Result-crop examples should show top-level gravity and top-level gravity offsets flowing into result `Crop` operations, while explicit crop examples should show crop-specific gravity overriding top-level gravity.

The guide may describe `ImagePlug.Transform.Focus` as an exported operation available to future parsers, but it should not claim that current Native URLs emit Focus operations.

Future dialect docs should describe dialect-specific URL syntax separately from `docs/transform_operations.md`. The operations guide should remain product-neutral and should receive new dialect examples only when they clarify operation semantics across dialects.

## Module Documentation

Each exported transform operation module should get `@moduledoc` for contributors maintaining or constructing that specific operation. The module docs are the field-level source of truth and should answer:

- What product-neutral operation the module represents.
- When parser/dialect code should construct it.
- How parser/planner code should construct the operation struct and where validation occurs.
- Which fields are required and what values are accepted.
- How the operation affects `ImagePlug.Transform.State`.
- What `metadata/1` means for decode planning.
- The exact canonical material fields emitted for cache keys.
- A short construction example.

The module docs should stay precise and avoid dialect-specific option names except where an example explicitly says a parser might translate a dialect option into the operation. They may duplicate short construction examples from the guide, but detailed field constraints and edge cases belong in the module docs rather than in `docs/transform_operations.md`.

Use a consistent module documentation template:

```elixir
@moduledoc """
Represents the product-neutral operation in one short paragraph.

## Construct When

State which parser or planner situations should construct this operation.

## Struct Contract

Document direct struct construction, accepted fields, and validation behavior.

## Fields

List required and optional struct fields, accepted values, and defaults.

## Execution Semantics

Describe how the operation changes `ImagePlug.Transform.State`.

## Decode Planning Metadata

Describe `metadata/1` and its sequential/random access implications.

## Cache Material

List the exact canonical material keyword fields emitted for cache keys.

## Examples

Include a short construction example using a struct literal.
"""
```

The Native guide is authoritative for URL grammar and aliases. Module docs are authoritative for operation struct fields and transform semantics. When the same concept appears in both, tests or review must verify that URL-facing values map correctly into the operation contract.

Operation docs should prefer construction examples that use raw struct literals. The docs should explain that `ImagePlug.Plan` validation rejects malformed operation structs before runtime side effects.

Each operation module owns documentation of its exact `ImagePlug.Transform.Material` keyword shape. The shared `Material` protocol docs should describe the purpose and cache-key role of material, but the per-operation module docs should list the operation-specific material fields so cache key contracts do not live only in defimpl code.

## Shared Transform Contract Documentation

Shared transform modules and protocols that operation docs depend on should also receive module docs or explicit guide coverage:

- `ImagePlug.Transform` should document the behaviour callbacks, runtime dispatch facade, and the expectation that runtime callers dispatch through this module.
- `ImagePlug.Transform.Chain` should document ordered transform-chain execution because `ImagePlug.Plan.Pipeline` uses this type.
- `ImagePlug.Transform.DecodePlanner` should document how operation metadata is interpreted for sequential versus random access, including fallback behavior when metadata is missing or errors.
- `ImagePlug.Transform.Materializer` should document the boundary between decode/materialization and transform execution at the level needed by operation docs.
- `ImagePlug.Transform.State` should document the state carried through a transform chain at the level operation docs need.
- `ImagePlug.Transform.Material` should document canonical transform material and its cache-key role.
- `ImagePlug.Transform.Geometry.DimensionRule` should document dimension fields and allowed modes because it is the shared field contract for `Resize`, `AdaptiveResize`, and crop target rules.
- `ImagePlug.Transform.Geometry.DimensionResolver` and `ImagePlug.Transform.Geometry.CropCoordinateMapper` should document enough semantics for operation docs to link to them without duplicating their contracts.

If any shared module should remain internal despite being exported, the implementation plan must explicitly choose where its contract is documented so operation module docs do not link to hidden or undocumented field types.

## Out Of Scope

This documentation pass should not introduce new transform behavior, new parser semantics, or new dialects. It should describe the current Native path API and the current exported transform operation model.

It should not attempt to document unimplemented Thumbor, TwicPics, imgix, or Cloudinary URL syntax. Future dialects can add mapping notes when their parser work begins.

## Testing And Review

The implementation plan should include:

- Updating `mix.exs` docs configuration so `docs/native_path_api.md` and `docs/transform_operations.md` are included in ExDoc extras.
- Documentation link checks where practical.
- `mise exec -- mix docs` verification, with warnings treated as failures if practical, and a check that both new guides appear in generated docs.
- Doctest or compile checks only where module examples are intentionally executable.
- Parser fixture tests for Native examples included in `docs/native_path_api.md`.
- Parser or planner tests for Native semantic rejection examples included in `docs/native_path_api.md`, currently including smart gravity rejection.
- Parser or planner tests for parity-sensitive supported Native examples included in `docs/native_path_api.md`, including auto-orient plus crop, top-level gravity offsets, force resize with one zero side, crop focal-point gravity, crop gravity inheritance, and crop offset unit parsing.
- Plan-shape tests for each mapping example included in `docs/transform_operations.md`.
- Plan-shape tests that show non-empty Native pipeline groups execute in URL group order while each group uses Native canonical operation order.
- A focused review that verifies docs match parser behavior and transform module contracts.
- A boundary review confirming docs do not suggest runtime dependencies on parser-specific modules or concrete transform modules.
- A review checklist item: no document says URL option order controls execution order.

## Success Criteria

The work is complete when:

- Native path users can find a complete option reference without reading internal transform modules.
- Dialect authors can decide which transform operation to emit for each supported image-processing concept.
- ExDoc module pages explain each exported operation contract clearly.
- README points to the detailed guides and remains concise.
- The docs preserve ImagePlug's product-neutral transform model and declarative Native API contract.
