# Imgproxy-Compatible Current Functionality Design

## Summary

ImagePlug should make imgproxy v4-pre URL syntax the basis for its public request grammar and processing model. This first slice covers ImagePlug's current executable functionality only: plain sources, width and height based resizing, crop gravity/focus for fill-style crops, and output format selection.

Because ImagePlug is greenfield and unreleased, the existing custom native option names are not preserved. The old `w:300`, `fit:cover`, `focus:center`, and `format:webp` grammar is replaced by imgproxy-compatible names, aliases, argument order, and value sets for every imgproxy option ImagePlug chooses to support.

The imgproxy v4-pre docs used for this design are in:

```text
/Users/hlindset/src/image_plug/local/imgproxy-docs-master/versioned_docs/version-4-pre/usage/processing.mdx
```

The imgproxy source files used to clarify parser edge cases are:

```text
/Users/hlindset/src/image_plug/local/imgproxy-master/options/processing_options.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/url.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/url_options.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/resize_type.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/gravity_options.go
```

## Goals

- Use imgproxy's URL structure as ImagePlug's default public URL structure.
- For each supported imgproxy processing option, support the whole documented grammar for that option from the start: long name, short aliases, argument shape, omitted optional arguments, and documented enum values.
- Keep the first implementation limited to ImagePlug's current image processing capabilities.
- Reject unsupported imgproxy options explicitly before origin fetch.
- Keep option order declarative. URL option order does not define transform execution order.
- Keep the internal model declarative: parser -> `ProcessingRequest` -> `PipelinePlanner` -> `TransformChain`.

## Non-Goals

- Do not implement all imgproxy options in the first slice.
- Do not retain compatibility with ImagePlug's previous custom native option names.
- Do not accept unsupported options as no-ops or placeholders.
- Do not implement URL signing, encrypted sources, remote plain URL fetching beyond existing origin resolution behavior, presets, quality controls, DPR, metadata controls, filters, watermarks, object detection, or security option overrides in this slice.
- Do not claim byte-for-byte or operation-for-operation parity with imgproxy internals.

## URL Structure

The public request path follows imgproxy's structure:

```text
/<signature>/<processing_options>/plain/<source_url_or_path>[@<extension>]
/<signature>/<processing_options>/<encoded_source_url>[.<extension>]
```

This first slice supports:

```text
/<signature>/<processing_options>/plain/<source_path>[@<extension>]
```

Rules:

- `<signature>` is required. `_` and `unsafe` are accepted while signing is disabled.
- Processing options are slash-separated path segments.
- The first `plain` segment terminates option parsing.
- Source paths after `plain` are joined with `/`, path-unescaped, and resolved through the existing configured origin behavior.
- A trailing `@<extension>` in the plain source sets the output format, matching imgproxy's plain source extension grammar.
- A literal `@` in a plain source must be escaped as `%40`; more than one `@` separator is an invalid URL.
- Base64 encoded source URLs and encrypted `enc` source URLs are reserved for later slices.

Example supported URLs:

```text
/_/plain/images/cat.jpg
/_/w:300/plain/images/cat.jpg
/_/resize:fill:300:200/gravity:ce/plain/images/cat.jpg@webp
/_/rs:fit:800:0/f:png/plain/images/cat.jpg
/_/rt:force/w:300/h:200/plain/images/cat.jpg
```

## Supported Options

### Resize

Supported grammar:

```text
resize:%resizing_type:%width:%height:%enlarge:%extend
rs:%resizing_type:%width:%height:%enlarge:%extend
```

All documented arguments are parsed with imgproxy's omitted-argument behavior, including empty argument positions such as `rs:fit:300` and `rs::300:200`.

The imgproxy source also allows the `extend` argument in `resize` and `size` to carry extend gravity arguments. ImagePlug should parse that source-backed grammar too:

```text
resize:%resizing_type:%width:%height:%enlarge:%extend:%gravity:%x_offset:%y_offset
rs:%resizing_type:%width:%height:%enlarge:%extend:%gravity:%x_offset:%y_offset
```

Supported value grammar:

- `resizing_type`: `fit`, `fill`, `fill-down`, `force`, `auto`
- `width`: non-negative integer, default `0`
- `height`: non-negative integer, default `0`
- `enlarge`: boolean grammar `1`, `t`, `true`, `0`, `f`, `false`, default false
- `extend`: boolean grammar `1`, `t`, `true`, `0`, `f`, `false`, default false, with optional extend gravity grammar when present

Execution scope:

- `fit` maps to current aspect-preserving contain behavior without letterboxing.
- `fill` maps to current cover/crop-to-box behavior.
- `force` maps to current stretch behavior.
- `fill-down` is parsed and represented distinctly. In this first slice it may plan to current `fill` behavior only when dimensions make the existing behavior equivalent; otherwise the planner returns an explicit unsupported semantic error before origin fetch.
- `auto` is parsed and represented distinctly. In this first slice it may plan only when a deterministic current equivalent is available; otherwise the planner returns an explicit unsupported semantic error before origin fetch.
- `enlarge` and `extend` are parsed because they are part of the supported `resize` grammar. If a request uses a value that current transforms cannot honor, planning fails explicitly before origin fetch.

### Size

Supported grammar:

```text
size:%width:%height:%enlarge:%extend
s:%width:%height:%enlarge:%extend
```

Source-backed extended grammar:

```text
size:%width:%height:%enlarge:%extend:%gravity:%x_offset:%y_offset
s:%width:%height:%enlarge:%extend:%gravity:%x_offset:%y_offset
```

This is an imgproxy meta-option for width, height, enlarge, and extend. It uses the same value grammar as `resize`, without changing the current `resizing_type`.

### Resizing Type

Supported grammar:

```text
resizing_type:%resizing_type
rt:%resizing_type
```

Supported values:

```text
fit
fill
fill-down
force
auto
```

The default resizing type is `fit`, matching imgproxy.

### Width And Height

Supported grammar:

```text
width:%width
w:%width
height:%height
h:%height
```

Widths and heights follow imgproxy's non-negative integer grammar. `0` means "calculate from the other dimension" for aspect-preserving resize types. If both dimensions are `0`, no geometry transform is planned unless another supported option requires one.

### Gravity

Supported grammar:

```text
gravity:%type:%x_offset:%y_offset
g:%type:%x_offset:%y_offset
gravity:fp:%x:%y
g:fp:%x:%y
gravity:sm
g:sm
```

Supported gravity values:

```text
no
so
ea
we
noea
nowe
soea
sowe
ce
fp
sm
```

Execution scope:

- Cardinal and corner gravities map to existing anchor focus values for crop-like operations.
- `fp` maps to the existing coordinate focus model using relative coordinates.
- Offsets are parsed as part of the option grammar. If non-zero offsets cannot be represented by the current focus model, planning fails explicitly before origin fetch.
- Smart gravity `sm` is parsed and represented because it is part of imgproxy's open-source crop gravity grammar. It returns an explicit planner error in this slice because ImagePlug does not currently have smart focus execution.
- Pro object-oriented gravities `obj` and `objw` are not in the open-source parser's crop gravity grammar and are not part of this slice.

### Format And Extension

Supported grammar:

```text
format:%extension
f:%extension
ext:%extension
```

Plain source extension grammar is also supported:

```text
/plain/<source_path>@<extension>
```

Supported output extensions:

```text
webp
avif
jpeg
jpg
png
```

`jpg` normalizes to ImagePlug's internal JPEG output format. `format:auto` is not an imgproxy format value and is not part of this grammar. Accept-header based output negotiation remains ImagePlug's default only when no explicit format or extension is provided.

If both a format option and a trailing plain-source extension are present, the source extension is applied after processing options and wins, matching imgproxy's parser.

## Duplicate And Meta-Option Behavior

Imgproxy applies processing options in URL order. This design follows that behavior:

- `resize:fill:300:200` and `rt:fill/w:300/h:200` are equivalent.
- Repeating the same semantic field is allowed.
- Later processing options overwrite earlier semantic values.
- The plain-source `@<extension>` format is applied after processing options and therefore overrides `format`, `f`, or `ext`.
- Cache keys use the final normalized `ProcessingRequest`, not the raw path order.

This preserves imgproxy compatibility while keeping ImagePlug's execution pipeline fixed and declarative. URL order affects only option assignment, not transform execution order.

## Processing Model

Parsing produces a declarative request that uses imgproxy concepts rather than ImagePlug's old custom names:

```text
Imgproxy path parser
  -> ProcessingRequest
  -> PipelinePlanner
  -> TransformChain
  -> image output
```

The planner owns the fixed execution order:

1. Validate parser output and supported semantic combinations.
2. Resolve and fetch the origin.
3. Decode the image and enforce input limits.
4. Apply supported geometry operations.
5. Apply gravity/focus where crop-like operations need it.
6. Select explicit output format or negotiate automatically when no explicit format is requested.
7. Encode and return the response.

Unsupported semantic combinations return client errors before origin traffic. Examples include non-zero gravity offsets, `resize` requests requiring `extend` behavior that current transforms cannot implement, or `auto`/`fill-down` cases where the current planner cannot provide the documented behavior.

## Internal Model Changes

`ImagePlug.ProcessingRequest` should move from old custom fields toward imgproxy concepts:

- `signature`
- `source_kind`
- `source_path`
- `source_extension`
- `width`
- `height`
- `resizing_type`
- `enlarge`
- `extend`
- `gravity`
- `format`

The exact field names may differ if implementation finds a clearer local representation, but the public semantics must remain imgproxy-shaped.

The parser module can keep the existing `ImagePlug.ParamParser.Native` name if that is the default parser, but its grammar should be imgproxy-compatible. A clearer `ImagePlug.ParamParser.Imgproxy` name is acceptable if the default config and README use it consistently.

## Error Handling

Errors are client request errors and should happen before origin fetch:

- Missing signature.
- Unsupported signature while signing is disabled.
- Missing source kind or source identifier.
- Unknown processing option.
- Invalid option arity.
- Invalid enum value.
- Invalid integer, boolean, extension, or gravity coordinate.
- Parsed but currently unsupported semantic combination.
- Multiple `@` format separators in a plain source URL.

The error body can stay plain text for now.

## Testing Strategy

The implementation should be test-first and cover:

- Parser tests for each supported long option and alias.
- Parser tests for full enum coverage on `resizing_type`.
- Parser tests for omitted optional `resize` and `size` arguments.
- Parser tests for `plain` source extension with `@extension`.
- Parser tests for equivalent meta-option and atomic-option combinations.
- Parser tests for last-wins duplicate option assignment.
- Parser tests proving `@extension` overrides an explicit format option.
- Parser tests for unsupported imgproxy options returning errors.
- Planner tests for current executable semantics: `fit`, `fill`, `force`, width-only, height-only, explicit output format, and gravity-driven crops.
- Planner tests proving unsupported semantic combinations fail before origin fetch.
- Plug-level tests for representative imgproxy-compatible URLs.
- README examples that match the implemented grammar.

## Documentation Strategy

The README should describe ImagePlug's public URL surface as imgproxy-compatible to the supported depth, not as a custom native API. It should show both long and short imgproxy forms:

```text
/_/resize:fill:300:200/gravity:ce/plain/images/cat.jpg@webp
/_/rs:fill:300:200/g:ce/plain/images/cat.jpg@webp
```

It should state that ImagePlug supports a subset of imgproxy options, but supported options follow imgproxy's full documented grammar for that option. Unsupported options fail explicitly.

## Open Decisions For Later Slices

- Whether to support base64 encoded source URLs before signed URLs.
- Whether `preset` should be implemented as a parser-level feature or as a config expansion step before semantic validation.
- Whether `quality`, `dpr`, and metadata controls should enter the request model before matching transform execution exists.
- Whether exact imgproxy `auto` and `fill-down` behavior should be implemented in transforms or remain explicit planner errors until needed.
- Create a follow-up issue to add pro object-oriented gravity support for `obj` and `objw` once ImagePlug has an object detection strategy.
