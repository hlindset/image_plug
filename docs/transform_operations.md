# Transform Operations

## Purpose

This guide is for parser and dialect authors translating external URL syntax into
`ImagePlug.Plan`. It explains where semantic request intent belongs, where
executable transform work belongs, and how to keep parser-specific behavior out
of runtime/cache boundaries.

Parser authors should construct canonical semantic operations under
`ImagePlug.Plan.Operation.*` through `ImagePlug.Plan.Operation`. The executable
modules under `ImagePlug.Transform.Operation.*` are local execution targets used
by Transform Plan execution and `ImagePlug.Transform.Chain`; parsers shouldn't
emit them except for the explicit first-slice orientation primitive allowlist.

## Request Flow

Parser syntax is translated into parser-owned request structs, then into
`ImagePlug.Plan`, then into executable transform work only after the final cache
lookup boundary.

The request flow is:

1. A parser reads external syntax and validates parser-level fields.
2. Parser-owned request structs keep dialect syntax and compatibility details
   isolated.
3. Planner code translates compatible semantics into canonical
   `ImagePlug.Plan.Operation.*` structs.
4. Cache keys are built from source-fetch-free Plan key data plus source
   freshness, output, config, and the cache key's transform key data version.
5. On cache miss, `ImagePlug.Transform.execute_plan/3` executes semantic Plan
   operations in order, converting each one to executable
   `ImagePlug.Transform.Operation.*` work as an implementation detail.
6. Runtime observes only the final transform state returned by
   `ImagePlug.Transform`.

Runtime code shouldn't reference concrete operation modules such as
`ImagePlug.Plan.Operation.Resize` or `ImagePlug.Transform.Operation.Resize`.
For Plan execution, runtime calls `ImagePlug.Transform.execute_plan/3`;
executable structs stay inside Transform execution.

## Operation Ordering

Operation chains are ordered once represented in `ImagePlug.Plan`.

imgproxy URLs are declarative; imgproxy planner code emits semantic Plan
operations in imgproxy canonical order. URL option order doesn't define
imgproxy transform order. The imgproxy canonical order is documented in
`docs/imgproxy_path_api.md` and is an imgproxy API contract, not a universal
requirement for every future dialect.

Other dialects may have order-sensitive semantics. When the ordered semantics
map cleanly, emit an ordered `ImagePlug.Plan`; otherwise keep dialect-specific
quirks isolated in the parser/adapter layer. Don't force ordered command
semantics into the imgproxy API or into product-neutral Plan operations.

## Request Fields That Aren't Transform Operations

These request fields affect source selection, response policy, cache identity,
or output encoding. They should be translated into the appropriate
`ImagePlug.Plan` facets instead of transform operations:

- source path, source URL handling, and source identity
- output format and automatic output negotiation
- quality and format-specific quality
- cachebuster
- expires
- filename
- attachment disposition

Keeping these fields out of transform chains matters for cache key data and
runtime boundaries. Output negotiation, for example, may change the encoded
format without changing the transform operation sequence.

## Semantic Operation Catalog

Parser/planner code should use these semantic operations:

- `ImagePlug.Plan.Operation.Resize`: product-neutral resize intent with
  `mode: :fit`, `:cover`, `:stretch`, or `:auto`. `mode: :auto` is semantic
  Plan intent; the selected fit/cover branch is post-fetch execution state, not
  cache key data.
- `ImagePlug.Plan.Operation.CropGuided`: crop by size plus guide.
- `ImagePlug.Plan.Operation.CropRegion`: explicit region crop.
- `ImagePlug.Plan.Operation.Canvas`: place the current image on a target canvas.
- `ImagePlug.Plan.Operation.Padding`: add edge padding around the current image.
- `ImagePlug.Plan.Operation.Background`: place an alpha-capable color behind
  the current image.
- `ImagePlug.Plan.Color`: canonical product-neutral sRGB color data with alpha.

Plan pipelines may also contain the explicit orientation primitive allowlist:
`ImagePlug.Transform.Operation.AutoOrient`, `ImagePlug.Transform.Operation.Rotate`,
and `ImagePlug.Transform.Operation.Flip`. Parsers shouldn't use other
executable Transform operation modules as Plan output.

## Executable Operation Catalog

`ImagePlug.Transform.Operation.*` modules are executable operation targets. They
describe work over `ImagePlug.Transform.State`, not parser request syntax:

- `ImagePlug.Transform.Operation.Resize`: executable resize with flattened mode
  and dimension fields.
- `ImagePlug.Transform.Operation.Crop`: resolved crop using gravity, offsets,
  and explicit crop dimensions.
- `ImagePlug.Transform.Operation.ExtendCanvas`: resolved canvas/letterbox work.
- `ImagePlug.Transform.Operation.Padding`: resolved edge-padding work.
- `ImagePlug.Transform.Operation.Background`: resolved background composition.
- `ImagePlug.Transform.Operation.AutoOrient`: executable EXIF autorotation.
- `ImagePlug.Transform.Operation.Rotate`: executable right-angle rotation.
- `ImagePlug.Transform.Operation.Flip`: executable flip.
`ImagePlug.Transform.Operation.AdaptiveResize` is obsolete. Resize
`mode: :auto` belongs in `ImagePlug.Plan.Operation.Resize`; parsers must not
emit an executable adaptive-resize operation.

## Choosing Resize-Like Semantic Operations

Use `ImagePlug.Plan.Operation.Resize` with `mode: :fit` for aspect-preserving
fit semantics, `mode: :cover` for cover/fill semantics that require result
cropping, and `mode: :stretch` for force/stretch semantics.

Use `mode: :auto` only for the imgproxy-compatible source-dependent rule:
orientation match derives cover, orientation mismatch derives fit, and unknown
target orientation derives fit. The unresolved semantic resize operation is the
cache-addressing key data; the selected branch is resolved after a cache miss.

Don't use `mode: :auto` as a generic conditional resize operation. If a future
adapter has different source-dependent branch rules, add a new semantic
operation or adapter policy instead of extending `mode: :auto` implicitly.

## Crop And Gravity

Use `CropGuided` for visible crop operations expressed as size plus guide. Use
`CropRegion` for explicit source/current-space region crops. Parser-specific
gravity spellings, focal-point tokens, and default inheritance rules should be
translated into explicit Plan guide values before cache key data is built.

Current imgproxy focal-point gravity maps to semantic guide values. The first
slice doesn't model a separate focus operation; future dialects can add one if
they expose focus state independently from visible crop/canvas/cover work.

## Orientation Operations

Use the explicit `AutoOrient`, `Rotate`, and `Flip` orientation primitive
allowlist for orientation intent.

imgproxy orientation suborder is auto-orient, rotate, then flip. Other dialects
should preserve their own semantics in the adapter layer and emit the ordered
Plan operation chain that matches those semantics.

## Canvas Operations

Use semantic `Canvas` when a dialect requests target canvas expansion,
letterboxing, or aspect-ratio extension around the transformed image. Don't use
it as a substitute for resize, contain, or cover semantics unless the dialect
really requests a larger canvas around image content.

The `Canvas.fill` value applies only to output from that canvas operation. It's
`:transparent` by default and can also be `{:solid, ImagePlug.Plan.Color.t()}`.
Don't use canvas fill to model a whole-image background flattening request.

Use semantic `Padding` when a dialect requests edge insets around the current
image. Padding expands relative to current dimensions; it isn't a target canvas
size. Padding has logical top/right/bottom/left sides, a requested pixel ratio,
and a fill value. The pixel ratio can be explicit, or it can request the
effective scale produced by a preceding resize for compatibility dialects whose
padding follows resize DPR semantics. Execution scales sides with
round-half-to-even semantics.

Use semantic `Background` when a dialect requests a color behind the current
image. Opaque backgrounds remove alpha as a consequence of composition; alpha
backgrounds preserve alpha until output encoding resolves a non-alpha format.
Background composition applies to source alpha and to transparent areas
generated by earlier canvas or padding operations, and it doesn't change
dimensions.

`ImagePlug.Plan.Color` is the canonical Plan color model. It represents sRGB
RGB channels with alpha and serializes into structured cache key data.
Third-party color package structs stay behind `ImagePlug.Plan.Color` and must
not leak into parser request structs, runtime state, or cache key data.

## Decode Planning

Before source metadata is available, semantic Plan operations must be treated
conservatively for decode/open planning. After a cache miss, source metadata may
be discovered and Transform Plan execution may convert semantic intent to
executable work. The exact executable `metadata/1` contract belongs in the
`ImagePlug.Transform.Operation.*` module docs.

## Cache Key Data

Final output cache key data is canonical semantic intent, not resolved execution
details. It should be stable for equivalent plans and independent of
parser-specific spelling, aliases, and compatibility quirks.

Parser-specific quirks must not leak into transform key data. If a dialect has
behavior that can't be represented cleanly by product-neutral semantic Plan
operations, keep that behavior isolated in parser/adapter code rather than
encoding dialect syntax into operation cache key data.

Source-aware execution choices such as resize `mode: :auto` selecting
fit/cover, ratio crop resolution, and DPR conversion are reflected in
executable work after a cache miss, but they don't participate in the normal
final output cache key.

## Mapping Examples

These examples show current imgproxy URL concepts translated into semantic Plan
operations. They describe imgproxy planner behavior only; future dialect docs
should describe their own URL syntax separately.

| Imgproxy URL concept | Semantic Plan operations |
| --- | --- |
| `w:300` | `Resize` with `mode: :fit` |
| `rt:force/w:0/h:200` | `Resize` with `mode: :stretch` and auto width |
| `rt:auto/w:300/h:200` | `Resize` with `mode: :auto` |
| `rt:fill/w:300/h:200/g:fp:0.25:0.75` | `Resize` with `mode: :cover` and focal-point guide |
| `rt:fill/w:300/h:200/g:soea:12:-0.25` | `Resize` with `mode: :cover` and top-level gravity offsets |
| `c:100:100/g:so` | `CropGuided` inheriting explicit top-level guide |
| `c:100:100:fp:0.25:0.75` | `CropGuided` with crop-specific focal-point guide |
| `ar/rot:90/fl:true:false/c:100:100` | `AutoOrient`, `Rotate`, `Flip`, `CropGuided` |
| `extend:true/w:300/h:200` | `Resize` with `mode: :fit`, `Canvas` |
| `pd:10/bg:f00` | `Padding`, `Background` |

## Boundary Rules

Runtime dispatches through `ImagePlug.Transform` and must not depend on concrete
Plan or Transform operation modules. Runtime shouldn't depend on parser-specific
imgproxy structs, and parser-specific request structs must not leak into runtime
execution.

Parser and planner modules construct exported semantic Plan operation structs
when they translate syntax into `ImagePlug.Plan`. Transform Plan execution may
reference both semantic Plan operations and executable Transform operations
because it owns conversion between those boundaries.

Boundary exports should stay narrow: export behaviours and stable
public/internal entry points, not implementation helpers.
