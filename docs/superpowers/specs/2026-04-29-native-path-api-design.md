# Native Path API Design

## Summary

ImagePlug should move away from the current TwicPics-shaped query API as its default public surface. The native API should use path-oriented, declarative URLs that describe the desired output image while leaving processing order under ImagePlug's control.

The default URL shape is:

```text
/<signature>/<options>/<source_kind>/<source_identifier>
```

Initial examples:

```text
/_/fit:cover/w:300/h:300/focus:center/format:auto/plain/images/cat.jpg
/_/fit:contain/w:800/format:webp/plain/images/cat.jpg
```

The first implementation may accept `_` or `unsafe` as the signature segment while signing is disabled. The segment is still part of the grammar so issue #26, signed image URLs, can be implemented without changing the native URL shape.

## Goals

- Make ImagePlug's native API product-neutral instead of defaulting to a subset of an existing product's API.
- Use stable path URLs suitable for direct use in `img` tags, CSS URLs, caches, and future signing.
- Treat URL options as declarative output requirements, not an ordered transform script.
- Preserve room for future encrypted source identifiers, signed URLs, optimized decoding, filters, metadata controls, background controls, and smart focus.
- Keep compatibility shims optional and best-effort rather than letting third-party API quirks shape the core model.

## Non-Goals

- Do not provide full TwicPics, imgproxy, or Cloudinary compatibility as part of the native API.
- Do not expose arbitrary ordered transform chains in the default native API.
- Do not implement signing, encrypted origins, smart gravity, filters, metadata controls, or input optimization in this API redesign. The grammar should leave room for those features.
- Do not preserve backwards compatibility with the current TwicPics-shaped query API. This repository is unreleased greenfield code.

## Current State

The current public parser is `ImagePlug.ParamParser.Twicpics`. It reads URLs such as:

```text
/process/images/cat.jpg?twic=v1/resize=300/output=webp
```

That parser emits an ordered `TransformChain`, and `ImagePlug.TransformChain` executes the transforms in URL order. This makes the API a command sequence. For example, `focus/crop/resize/output` means those operations happen in that order.

Most lower-level transform modules are already product-neutral:

- `ImagePlug.Transform.Scale`
- `ImagePlug.Transform.Cover`
- `ImagePlug.Transform.Contain`
- `ImagePlug.Transform.Crop`
- `ImagePlug.Transform.Focus`
- `ImagePlug.Transform.Output`

The redesign should keep product-neutral transform execution machinery, but the native public API should not make ordering the default contract.

## URL Grammar

The native path grammar is:

```text
/<signature>/<option_segment>.../<source_kind>/<source_identifier>
```

Rules:

- `<signature>` is required. `_` and `unsafe` are accepted while signing is disabled.
- `<option_segment>` is zero or more `name:value` path segments.
- `<source_kind>` identifies how to interpret the remaining source identifier. The initial source kind is `plain`.
- `<source_identifier>` for `plain` is the origin path relative to configured `root_url`.
- Option segment order does not define processing order.
- Unknown options return a client parser error before origin fetch.
- Duplicate mutually exclusive options return a parser error unless a specific option defines last-wins behavior.

Initial examples:

```text
/_/plain/images/cat.jpg
/_/w:300/plain/images/cat.jpg
/_/fit:cover/w:300/h:300/focus:center/format:auto/plain/images/cat.jpg
/unsafe/fit:contain/w:800/format:webp/plain/images/cat.jpg
```

Future source kinds can extend the same shape:

```text
/<signature>/<options>/enc/<encrypted_origin_identifier>
```

This directly leaves room for issue #31, encrypted origin paths or source URLs.

## Initial Native Options

The first native API should stay small:

```text
w:<positive-number>
h:<positive-number>
fit:cover | fit:contain | fit:fill | fit:inside
focus:center | focus:top | focus:bottom | focus:left | focus:right | focus:<x>:<y>
format:auto | format:webp | format:avif | format:jpeg | format:png
```

Semantics:

- `w` and `h` define requested output bounds or dimensions.
- `fit:cover` fills the requested box and crops overflow around `focus`.
- `fit:contain` scales the image inside the requested box without letterboxing.
- `fit:inside` scales the image inside the requested box and embeds it in the requested box when both dimensions are known.
- `fit:fill` resizes to the requested width and height without preserving aspect ratio.
- `focus` controls the crop anchor for `fit:cover` and future crop-like operations.
- `format:auto` uses existing Accept-header negotiation.
- Explicit `format` values bypass Accept negotiation.

The first implementation should not expose arbitrary `crop` in the native API. `fit:cover` covers the common crop-to-box case without reintroducing ordering ambiguity. A future declarative crop option can be added once its interaction with `fit`, `focus`, and dimensions is specified.

`format:blurhash` should not be part of the first native image format set. Blurhash is useful, but it is not an image media format. It should be considered separately as either a special output mode or a sibling endpoint.

## Processing Model

Native API parsing should produce a product-neutral declarative request rather than an ordered transform chain. The proposed flow is:

```text
Native path parser
  -> ProcessingRequest
  -> PipelinePlanner
  -> TransformChain
  -> image output
```

`ProcessingRequest` is the native semantic contract. `PipelinePlanner` owns the fixed processing order and converts the declarative request into existing transform execution modules.

Initial pipeline phases:

1. Validate native path and options before origin fetch.
2. Build and fetch the origin URL.
3. Decode the image and enforce input limits.
4. Apply future autorotation before geometric operations, aligning with issue #27.
5. Apply geometric planning and execution: fit, dimensions, focus-driven cover crop.
6. Apply future filters after geometric operations, aligning with issue #32 unless a later design changes filter semantics.
7. Apply output format negotiation or explicit format selection.
8. Encode and stream the response.

The fixed pipeline supports issue #28, optimized input decoding for large downscales, because ImagePlug can reason about the requested final geometry without preserving arbitrary user-specified operation order.

## Compatibility Policy

Third-party compatibility should be optional and best-effort.

- The native API is not TwicPics-compatible, imgproxy-compatible, or Cloudinary-compatible.
- Compatibility parsers may be added later when there is a concrete migration target.
- A compatibility parser may translate supported third-party syntax into `ProcessingRequest` when semantics match cleanly.
- If a third-party API feature depends on exact ordered command execution, the compatibility parser may either reject it or use an adapter-only explicit transform chain.
- Ordered chains should not become the default native API contract.

Because this codebase is unreleased, the current TwicPics parser can be removed from the default route and documentation during implementation. Keeping it temporarily as an internal reference is acceptable only if it reduces implementation risk.

## Relationship To Open Issues

- #26, signed image URLs: reserve the leading signature segment now.
- #31, encrypted origin paths or source URLs: reserve source kind segments such as `plain` and future `enc`.
- #28, optimized input decoding for large downscales: prefer declarative fixed-pipeline semantics.
- #32, basic image filters: define that filters are future pipeline options, initially after geometry.
- #27, EXIF orientation: define orientation as a future pre-geometry pipeline phase.
- #29, background and padding controls: leave option namespace room for `bg`, `background`, and `pad`.
- #30, metadata and color profile controls: leave option namespace room for output and metadata policies.
- #34, smart gravity and object-aware crop anchors: leave focus namespace room for `focus:auto` or a later `gravity` option.
- #8, output quality and encoder controls: leave option namespace room for `q` or `quality`.

## Testing Strategy

The implementation plan should cover:

- Parser tests for valid native path URLs.
- Parser tests proving option order does not affect the parsed request.
- Parser tests for unknown options, invalid values, missing source kind, missing source identifier, and invalid duplicate options.
- Planner tests mapping native requests to existing transform modules.
- Plug-level tests proving invalid native requests fail before origin fetch.
- Plug-level tests for a representative successful path URL.
- Documentation examples matching the native path API.

## Documentation Strategy

The README should describe ImagePlug as a path-oriented image optimization plug. The native API section should lead with examples like:

```text
/_/fit:cover/w:300/h:300/focus:center/format:auto/plain/images/cat.jpg
```

The README should explain that option order in the URL is not processing order. It should also state that ImagePlug uses a fixed processing pipeline so it can optimize decoding, resizing, cropping, and output encoding over time.

The current TwicPics framing should be removed from default docs. If the TwicPics parser remains in the codebase temporarily, it should be documented as internal or compatibility-oriented, not as the primary API.
