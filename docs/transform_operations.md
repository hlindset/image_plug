# Transform Operations

## Purpose

This guide is for parser and dialect authors translating external URL syntax into
`ImagePlug.Plan`. It explains where semantic request intent belongs, where
executable transform work belongs, and how to keep parser-specific behavior out
of runtime/cache boundaries.

Parser authors should construct canonical semantic operations under
`ImagePlug.Plan.Operation.*` through `ImagePlug.Plan.Operation`. The executable
modules under `ImagePlug.Transform.Operation.*` are local lowering targets used
by `ImagePlug.Transform.Resolver` and `ImagePlug.Transform.Chain`; parsers
should not emit them.

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
4. Cache keys are built from source-fetch-free plan material plus source
   freshness, output, config, and the cache key's transform material version.
5. On cache miss, `ImagePlug.Transform.Resolver` lowers semantic Plan
   operations to executable `ImagePlug.Transform.Operation.*` work.
6. Runtime executes resolved work by dispatching through `ImagePlug.Transform`.

Runtime code should not reference concrete operation modules such as
`ImagePlug.Plan.Operation.ResizeFit` or `ImagePlug.Transform.Operation.Resize`.
It may carry resolved executable structs opaquely through generic
`ImagePlug.Transform` facades.

## Operation Ordering

Operation chains are ordered once represented in `ImagePlug.Plan`.

Imgproxy URLs are declarative; Imgproxy planner code emits semantic Plan
operations in Imgproxy canonical order. URL option order does not define
Imgproxy transform order. The Imgproxy canonical order is documented in
`docs/imgproxy_path_api.md` and is an Imgproxy API contract, not a universal
requirement for every future dialect.

Other dialects may have order-sensitive semantics. When the ordered semantics
map cleanly, emit an ordered `ImagePlug.Plan`; otherwise keep dialect-specific
quirks isolated in the parser/adapter layer. Do not force ordered command
semantics into the Imgproxy API or into product-neutral Plan operations.

## Request Fields That Are Not Transform Operations

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

Keeping these fields out of transform chains matters for cache material and
runtime boundaries. Output negotiation, for example, may change the encoded
format without changing the transform operation sequence.

## Semantic Operation Catalog

Parser/planner code should use these semantic operations:

- `ImagePlug.Plan.Operation.ResizeFit`: aspect-preserving fit resize.
- `ImagePlug.Plan.Operation.ResizeCover`: aspect-preserving cover/fill resize
  plus guide for the result crop.
- `ImagePlug.Plan.Operation.ResizeStretch`: force/stretch resize.
- `ImagePlug.Plan.Operation.ResizeAuto`: imgproxy-compatible source-dependent
  resize intent. The selected fit/cover branch is post-fetch execution state,
  not cache key material.
- `ImagePlug.Plan.Operation.CropGuided`: crop by size plus guide.
- `ImagePlug.Plan.Operation.CropRegion`: explicit region crop.
- `ImagePlug.Plan.Operation.Canvas`: place the current image on a target canvas.
- `ImagePlug.Plan.Operation.AutoOrient`: EXIF-aware auto orientation intent.
- `ImagePlug.Plan.Operation.Rotate`: explicit right-angle rotation.
- `ImagePlug.Plan.Operation.Flip`: horizontal, vertical, or both-axis flip.

## Executable Operation Catalog

`ImagePlug.Transform.Operation.*` modules are executable lowering targets. They
describe work over `ImagePlug.Transform.State`, not parser request material:

- `ImagePlug.Transform.Operation.Resize`: resolved resize with a known
  dimension-rule mode.
- `ImagePlug.Transform.Operation.Crop`: resolved crop using gravity, offsets,
  optional orientation context, and optional target rule.
- `ImagePlug.Transform.Operation.ExtendCanvas`: resolved canvas/letterbox work.
- `ImagePlug.Transform.Operation.AutoOrient`: executable EXIF autorotation.
- `ImagePlug.Transform.Operation.Rotate`: executable right-angle rotation.
- `ImagePlug.Transform.Operation.Flip`: executable flip.
- `ImagePlug.Transform.Operation.Focus`, `Scale`, `Contain`, and `Cover`:
  standalone executable operations retained for local transform execution and
  future lowering paths, not first-slice parser output.

## Choosing Resize-Like Semantic Operations

Use `ResizeFit` for aspect-preserving fit semantics. Use `ResizeCover` for
cover/fill semantics that require result cropping. Use `ResizeStretch` for
force/stretch semantics.

Use `ResizeAuto` only for the imgproxy-compatible source-dependent rule:
orientation match derives cover, orientation mismatch derives fit, and unknown
target orientation derives fit. The unresolved `ResizeAuto` operation is the
cache-addressing material; the selected branch is resolved after a cache miss.

Do not use `ResizeAuto` as a generic conditional resize operation. If a future
adapter has different source-dependent branch rules, add a new semantic
operation or adapter policy instead of extending `ResizeAuto` implicitly.

## Crop, Gravity, And Focus

Use `CropGuided` for visible crop operations expressed as size plus guide. Use
`CropRegion` for explicit source/current-space region crops. Parser-specific
gravity spellings, focal-point tokens, and default inheritance rules should be
translated into explicit Plan guide values before cache material is built.

Current Imgproxy focal-point gravity maps to semantic guide values. The first
slice does not model a separate semantic focus operation; future dialects can
add one if they expose focus state independently from visible crop/canvas/cover
work.

## Orientation Operations

Use semantic `AutoOrient`, `Rotate`, and `Flip` for orientation intent.

Imgproxy orientation suborder is auto-orient, rotate, then flip. Other dialects
should preserve their own semantics in the adapter layer and emit the ordered
Plan operation chain that matches those semantics.

## Canvas Operations

Use semantic `Canvas` when a dialect requests canvas expansion, letterboxing,
padding, or aspect-ratio extension around the transformed image. Do not use it
as a substitute for resize, contain, or cover semantics unless the dialect
really requests a larger canvas around image content.

## Decode Planning

Before source metadata is available, semantic Plan operations must be treated
conservatively for decode/open planning. After a cache miss, source metadata may
be discovered and the Transform resolver may lower semantic intent to
executable work. The exact executable `metadata/1` contract belongs in the
`ImagePlug.Transform.Operation.*` module docs.

## Cache Material

Final output cache material is canonical semantic intent, not resolved backend
execution. It should be stable for equivalent plans and independent of
parser-specific spelling, aliases, and compatibility quirks.

Parser-specific quirks must not leak into transform material. If a dialect has
behavior that cannot be represented cleanly by product-neutral semantic Plan
operations, keep that behavior isolated in parser/adapter code rather than
encoding dialect syntax into operation cache material.

Source-aware resolver choices such as `ResizeAuto` selecting fit/cover, ratio
crop resolution, and DPR conversion are reflected in resolved executable work
after a cache miss, but they do not participate in the normal final output
cache key.

## Mapping Examples

These examples show current Imgproxy URL concepts translated into semantic Plan
operations. They describe Imgproxy planner behavior only; future dialect docs
should describe their own URL syntax separately.

| Imgproxy URL concept | Semantic Plan operations |
| --- | --- |
| `w:300` | `ResizeFit` |
| `rt:force/w:0/h:200` | `ResizeStretch` with auto width |
| `rt:auto/w:300/h:200` | `ResizeAuto` |
| `rt:fill/w:300/h:200/g:fp:0.25:0.75` | `ResizeCover` with focal-point guide |
| `rt:fill/w:300/h:200/g:soea:12:-0.25` | `ResizeCover` with top-level gravity offsets |
| `c:100:100/g:so` | `CropGuided` inheriting explicit top-level guide |
| `c:100:100:fp:0.25:0.75` | `CropGuided` with crop-specific focal-point guide |
| `ar/rot:90/fl:true:false/c:100:100` | `AutoOrient`, `Rotate`, `Flip`, `CropGuided` |
| `extend:true/w:300/h:200` | `ResizeFit`, `Canvas` |

## Boundary Rules

Runtime dispatches through `ImagePlug.Transform` and must not depend on concrete
Plan or Transform operation modules. Runtime should not depend on parser-specific
Imgproxy structs, and parser-specific request structs must not leak into runtime
execution.

Parser and planner modules construct exported semantic Plan operation structs
when they translate syntax into `ImagePlug.Plan`. The Transform resolver may
reference both semantic Plan operations and executable Transform operations
because it owns lowering between those boundaries.

Boundary exports should stay narrow: export behaviours and stable
public/internal entry points, not implementation helpers.
