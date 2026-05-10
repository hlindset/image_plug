# Transform Operations

## Purpose

This guide is for parser and dialect authors translating external URL syntax into
`ImagePlug.Plan`. It answers which product-neutral transform operation should
represent an image-processing concept before you open the field-level module
documentation for a specific `ImagePlug.Transform.*` module.

Transform operations should describe reusable image behavior over
`ImagePlug.Transform.State`. Parser-specific and vendor-specific syntax belongs
in `ImagePlug.Parser.*` request structs and adapters, not in transform operation
contracts.

## Request Flow

Parser syntax is translated into parser-owned request structs, then into
`ImagePlug.Plan`, then into ordered transform operation chains.

The request flow is:

1. A parser reads external syntax and validates parser-level fields.
2. Parser-owned request structs keep dialect syntax and compatibility details
   isolated.
3. Planner code translates compatible semantics into `ImagePlug.Plan`.
4. `ImagePlug.Plan.Pipeline` contains ordered transform operations.
5. Runtime code executes the plan by dispatching through `ImagePlug.Transform`.

Runtime code should not reference concrete operation modules such as
`ImagePlug.Transform.Resize`, `ImagePlug.Transform.Crop`, or
`ImagePlug.Transform.Focus`. Parser and planner modules may construct exported
operation structs when translating syntax into a product-neutral plan.

## Operation Ordering

Operation chains are ordered once represented in `ImagePlug.Plan`.

Imgproxy URLs are declarative; Imgproxy planner code emits operations in Imgproxy
canonical order. URL option order does not define Imgproxy transform order. The
Imgproxy canonical order is documented in `docs/imgproxy_path_api.md` and is a
Imgproxy API contract, not a universal requirement for every future dialect.

Other dialects may have order-sensitive semantics. When the ordered semantics
map cleanly, emit an ordered `ImagePlug.Plan`; otherwise keep dialect-specific
quirks isolated in the parser/adapter layer. Do not force ordered command
semantics into the Imgproxy API or into product-neutral transform operation
contracts.

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

## Operation Catalog

- `ImagePlug.Transform.Resize`: planned resize with a known dimension rule mode.
- `ImagePlug.Transform.AdaptiveResize`: runtime-dependent auto resize that
  chooses fit or fill from source and target orientation.
- `ImagePlug.Transform.Crop`: crop using gravity, offsets, optional orientation
  context, and optional target rule.
- `ImagePlug.Transform.Focus`: state-only focus operation for future parsers
  that separate focus from crop.
- `ImagePlug.Transform.ExtendCanvas`: canvas/letterbox expansion.
- `ImagePlug.Transform.AutoOrient`: EXIF-aware auto orientation.
- `ImagePlug.Transform.Rotate`: explicit right-angle rotation.
- `ImagePlug.Transform.Flip`: horizontal, vertical, or both-axis flip.
- `ImagePlug.Transform.Scale`: standalone scale operation.
- `ImagePlug.Transform.Contain`: standalone contain operation.
- `ImagePlug.Transform.Cover`: standalone cover operation.

## Choosing Resize-Like Operations

Use `Resize` when the resize mode is known at planning time. Use
`AdaptiveResize` for Imgproxy `auto` behavior, because execution chooses
fit or fill after source dimensions are known.

`Scale`, `Contain`, and `Cover` remain exported standalone operations. Do not
describe them as implementation details of `Resize`; parser authors should emit
them directly when the source dialect's semantics are specifically scale,
contain, or cover operations and those semantics do not need the newer planned
`Resize` dimension-rule model.

Use `Resize` plus a result `Crop` for fill/cover-style target crops when that
matches the dialect. Use `ExtendCanvas` for letterboxing, padding, or canvas
expansion, not for normal resize.

## Crop, Gravity, And Focus

Use `Crop` for visible crop operations. Crop gravity, offsets, target rules, and
orientation context belong on `ImagePlug.Transform.Crop` when the dialect maps
cleanly to those fields.

Imgproxy focal-point gravity maps to `ImagePlug.Transform.Crop` gravity. Current
Imgproxy URLs do not emit `ImagePlug.Transform.Focus`.

`Focus` is available for future parsers that model focus as state for later crop
operations rather than as a visible operation by itself. Do not use `Focus` to
represent current Imgproxy focal-point crop syntax.

## Orientation Operations

Use `AutoOrient` for EXIF-aware orientation, `Rotate` for explicit right-angle
rotation, and `Flip` for horizontal, vertical, or both-axis flips.

Imgproxy orientation suborder is auto-orient, rotate, then flip. Other dialects
should preserve their own semantics in the adapter layer and emit the ordered
operation chain that matches those semantics.

## Canvas Operations

Use `ExtendCanvas` when a dialect requests canvas expansion, letterboxing,
padding, or aspect-ratio extension around the transformed image. Do not use it
as a substitute for resize, contain, or cover semantics unless the dialect
really requests a larger canvas around image content.

## Decode Planning

Operation choice matters for decode planning. Dialect authors should choose the
most semantically accurate operation instead of forcing every geometry request
into generic resize or crop operations.

Operation metadata can affect whether decoding can use sequential image access
or must use random access. The exact `metadata/1` contract belongs in the
operation module docs.

## Cache Material

Transform material should represent canonical operation semantics. It should be
stable for equivalent plans and independent of parser-specific spelling,
aliases, and compatibility quirks.

Parser-specific quirks must not leak into transform material. If a dialect has
behavior that cannot be represented cleanly by product-neutral operations, keep
that behavior isolated in parser/adapter code rather than encoding dialect
syntax into operation cache material.

## Mapping Examples

These examples show current Imgproxy URL concepts translated into operation
chains. They describe Imgproxy planner behavior only; future dialect docs should
describe their own URL syntax separately.

| Imgproxy URL concept | Operation chain |
| --- | --- |
| `w:300` | `Resize` |
| `rt:force/w:0/h:200` | `Resize` with force mode and auto width |
| `rt:auto/w:300/h:200` | `AdaptiveResize`, result `Crop` |
| `rt:fill/w:300/h:200/g:fp:0.25:0.75` | `Resize`, result `Crop` with focal-point gravity |
| `rt:fill/w:300/h:200/g:soea:12:-0.25` | `Resize`, result `Crop` with top-level gravity offsets |
| `c:100:100/g:so` | `Crop` inheriting top-level gravity when crop gravity is omitted |
| `c:100:100:fp:0.25:0.75` | `Crop` with crop-specific focal-point gravity |
| `ar/rot:90/fl:true:false/c:100:100` | `AutoOrient`, `Rotate`, `Flip`, `Crop` |
| `extend:true/w:300/h:200` | `Resize`, `ExtendCanvas` |

## Boundary Rules

Runtime dispatches through `ImagePlug.Transform`. Runtime should not depend on
parser-specific Imgproxy structs, and parser-specific request structs must not
leak into runtime execution.

Parser and planner modules may construct exported operation structs when they
translate syntax into `ImagePlug.Plan`. Boundary exports should stay narrow:
export behaviours and stable public/internal entry points, not implementation
helpers.
