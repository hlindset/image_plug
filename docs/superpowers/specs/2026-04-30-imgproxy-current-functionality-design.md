# Imgproxy-Compatible Current Functionality Design

## Summary

ImagePlug should make imgproxy v4-pre URL syntax the basis for its public request grammar and processing model. This first slice covers ImagePlug's current executable functionality: plain sources, width and height based resizing, crop gravity/focus for fill-style crops, explicit output format selection, and Accept-based automatic output format selection when no explicit format is requested.

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
- Keep ImagePlug's no-explicit-format behavior automatic by default, using `Accept` to choose modern browser formats while retaining source-format fallback.
- Reject unsupported imgproxy options explicitly before origin fetch.
- Keep option order declarative. URL option order does not define transform execution order.
- Keep the internal model declarative: parser -> `ProcessingRequest` -> `PipelinePlanner` -> `TransformChain`.

## Non-Goals

- Do not implement all imgproxy options in the first slice.
- Do not retain compatibility with ImagePlug's previous custom native option names.
- Do not accept unsupported options as no-ops or placeholders.
- Do not implement URL signing, encrypted sources, remote plain URL fetching beyond existing origin resolution behavior, presets, best-format selection, quality controls, DPR, metadata controls, filters, watermarks, object detection, or security option overrides in this slice.
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
- While signing is disabled, ImagePlug intentionally accepts only `_` and `unsafe` as signature segments. Any other signature segment is rejected instead of ignored. This is stricter than imgproxy's disabled-signature mode, which allows any value.
- Processing options are slash-separated path segments.
- The first `plain` segment terminates option parsing.
- Source paths after `plain` are joined with `/`, path-unescaped, and resolved through the existing configured origin behavior.
- A raw `@<extension>` in the joined plain source sets the output format, matching imgproxy's plain source extension grammar.
- The parser detects the raw `@` separator before percent decoding. `%40` is decoded into a literal `@` inside the source path and is not treated as a separator.
- More than one raw `@` separator is an invalid URL.
- An empty extension after a raw `@`, such as `plain/images/cat.jpg@`, does not set an output format.
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

The imgproxy source also allows the `extend` argument in `resize` and `size` to carry extend gravity arguments. ImagePlug should parse that grammar accepted by imgproxy source too:

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
- `fill-down` is parsed and represented distinctly, but always returns an explicit unsupported semantic error in this slice. Later slices may support metadata-dependent planning after origin decode.
- `auto` is parsed and represented distinctly, but always returns an explicit unsupported semantic error in this slice. Later slices may support metadata-dependent planning after origin decode.
- `enlarge` and `extend` are parsed because they are part of the supported `resize` grammar. If a request uses a value that current transforms cannot honor, planning fails explicitly before origin fetch. In this slice, `extend:true` and non-default extend gravity values are unsupported semantic combinations.

### Size

Supported grammar:

```text
size:%width:%height:%enlarge:%extend
s:%width:%height:%enlarge:%extend
```

Grammar accepted by imgproxy source:

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
- `fp` maps to the existing coordinate focus model using relative coordinates. `gravity:fp:%x:%y` requires decimal numbers in the inclusive range `0.0..1.0`, matching imgproxy focal point semantics. Integers `0` and `1` are accepted as valid decimal values. Percent strings are not accepted.
- Offsets for non-`fp` gravity values are parsed as decimal numbers. If non-zero offsets cannot be represented by the current focus model, planning fails explicitly before origin fetch.
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
best
```

`jpg` normalizes to ImagePlug's internal JPEG output format. `best` is parsed and represented distinctly because imgproxy documents it as a Pro value for both the `format` option and URL extension.

In this first slice, `best` returns an explicit planner error. Implementing it later means encoding multiple candidate outputs and choosing the smallest result, which is materially different from Accept-based automatic output selection.

`format:auto` is not an imgproxy format value and is not part of this grammar. Accept-header based output selection is configured behavior when no explicit output format is requested, not a URL processing option.

If both a format option and a trailing plain-source extension are present, the source extension is applied after processing options and wins, matching imgproxy's parser.

## Default Output Format

Imgproxy's URL grammar treats an omitted format as "no explicit output format." In imgproxy's default configuration, this usually keeps the source format for preferred source formats. Imgproxy can also be configured with `IMGPROXY_AUTO_WEBP`, `IMGPROXY_AUTO_AVIF`, and `IMGPROXY_AUTO_JXL` so omitted format uses the request `Accept` header.

ImagePlug should use the same URL semantics but a more modern default configuration:

- No explicit `format` option and no source `@extension` means automatic output format selection.
- `auto_avif` defaults to `true`.
- `auto_webp` defaults to `true`.
- `auto_jxl` defaults to `false` until ImagePlug supports JPEG XL encoding confidently.
- Selection order is AVIF, then WebP, then source format fallback.
- Automatic selection only chooses a format accepted by the request `Accept` header.
- `Accept` q-values are used to determine acceptability. A format with `q=0` is unacceptable. Among acceptable formats, ImagePlug uses server preference order: AVIF, then WebP, then source format fallback. Relative q-values do not reorder AVIF and WebP in this slice.
- If neither AVIF nor WebP is acceptable, ImagePlug falls back to the source format when it can encode it and the source format is acceptable or the `Accept` header is absent.
- If the source format cannot be encoded, ImagePlug falls back to JPEG for non-alpha images and PNG for alpha images when the fallback is acceptable or the `Accept` header is absent, matching the spirit of imgproxy's preferred-format fallback without introducing the full preferred-format configuration in this slice.
- `Vary: Accept` is set whenever automatic output format selection can affect the response.
- Cache keys include the selected automatic output format, not the raw `Accept` header, when automatic output format selection can affect the response. This avoids cache fragmentation from equivalent `Accept` headers.

Operators can disable `auto_avif` and `auto_webp` to get stricter imgproxy-default-style behavior and simpler cache behavior.

## Normalized Assignment Semantics

Processing options are parsed left to right into a single normalized `ProcessingRequest`. Each supported option assigns one or more semantic fields. Later assignments overwrite earlier assignments for the same field.

Normalized geometry and output state includes:

- `resizing_type`
- `width`
- `height`
- `enlarge`
- `extend`
- `extend_gravity`
- `extend_x_offset`
- `extend_y_offset`
- `gravity`
- `gravity_x_offset`
- `gravity_y_offset`
- `format`

Assignment rules:

- `resize` assigns `resizing_type`, `width`, `height`, `enlarge`, `extend`, and optional extend-gravity fields.
- `size` assigns `width`, `height`, `enlarge`, `extend`, and optional extend-gravity fields.
- `resizing_type` assigns only `resizing_type`.
- `width` assigns only `width`.
- `height` assigns only `height`.
- `gravity` assigns crop gravity/focus fields, not extend gravity fields.
- `format`, `f`, and `ext` assign explicit output format.
- Plain-source `@extension` is applied after all processing options and therefore overwrites explicit output format.

Examples:

| URL options | Final normalized fields |
| --- | --- |
| `resize:fill:300:200/w:500` | `resizing_type=fill,width=500,height=200` |
| `w:500/resize:fill:300:200` | `resizing_type=fill,width=300,height=200` |
| `size:300:200/rt:force` | `resizing_type=force,width=300,height=200` |
| `resize:fit:300:200/rt:force` | `resizing_type=force,width=300,height=200` |
| `f:webp/plain/a.jpg@png` | `format=png` |

## Duplicate And Meta-Option Behavior

Imgproxy applies processing options in URL order. This design follows that behavior. URL order affects only normalized field assignment, not transform execution order.

- `resize:fill:300:200` and `rt:fill/w:300/h:200` are equivalent after normalized assignment.
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
6. Select explicit output format or automatically select an output format when no explicit format is requested.
7. Encode and return the response.

Unsupported semantic combinations return client errors before origin traffic. Examples include non-zero gravity offsets, `resize` requests requiring `extend` behavior that current transforms cannot implement, `gravity:sm`, `format:best`, or `auto`/`fill-down` resizing types.

## Compatibility Parser Boundary

Imgproxy compatibility is a parser and request-model concern, not a transform-module concern. The implementation should preserve a boundary that allows later TwicPics, imgix, Cloudinary-like, or direct Elixir APIs to reuse the same processing engine.

Responsibilities:

- Product-specific parsers understand vendor URL grammar, aliases, defaults, and duplicate assignment rules.
- `ProcessingRequest` represents normalized image intent rather than a vendor command list.
- `PipelinePlanner` expands normalized intent into ImagePlug's fixed internal pipeline.
- Transform modules stay small, reusable processing primitives and should not be named or shaped around vendor parameters unless that operation is truly vendor-independent.

One public parameter may compile into several internal transforms. For example:

```text
rs:fill:300:200/g:ce
  -> set crop gravity/focus
  -> resize to cover the target box
  -> crop to final dimensions

rs:fit:300:200
  -> resize proportionally inside bounds

rt:force/w:300/h:200
  -> resize width and height independently
```

The goal is to keep internal transforms close to image-processing operations while parsers and planners handle vendor vocabulary. Avoid both extremes: do not make one transform per imgproxy parameter, and do not split primitives so finely that every planned pipeline becomes hard to reason about.

## Future Chained Pipelines

Imgproxy Pro supports chained pipelines by using a `-` path segment to start another fixed processing pipeline. This is different from arbitrary transform ordering: each stage still has a fixed internal order, but the output of one stage becomes the input to the next stage.

This first slice should not implement chained pipelines, but it should avoid making them hard to add later:

- The parser should reserve a path segment exactly equal to `-` as an unsupported pipeline separator rather than treating it as an unknown option name. Values containing `-`, such as `fill-down`, remain valid option values.
- The internal model should be able to evolve from a single `ProcessingRequest` into a `ProcessingJob` containing one or more normalized pipeline stages.
- Each pipeline stage should contain the same normalized intent fields used by the first slice: geometry, gravity, output-affecting controls, filters, and later overlays.
- The planner should be able to plan each stage independently, then concatenate executable transform primitives with a clear stage boundary where needed.
- Cache keys should be based on the normalized ordered list of stages once chained pipelines exist.

This keeps future support straightforward for URLs such as:

```text
rs:fit:500:500/-/trim:10
```

The first stage would resize using ImagePlug's fixed pipeline. The second stage would run another fixed pipeline over the resized image and apply trim once that transform exists. That model also covers later repeated operations such as multiple watermarks without making the first-slice transform layer vendor-specific.

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
- `extend_gravity`
- `extend_x_offset`
- `extend_y_offset`
- `gravity`
- `gravity_x_offset`
- `gravity_y_offset`
- `format`

The exact field names may differ if implementation finds a clearer local representation, but the public semantics must remain imgproxy-shaped.

The parser module can keep the existing `ImagePlug.ParamParser.Native` name if that is the default parser, but its grammar should be imgproxy-compatible. A clearer `ImagePlug.ParamParser.Imgproxy` name is acceptable if the default config and README use it consistently.

## Error Handling

Errors are client request errors and should happen before origin fetch.

Parser errors:

- Missing signature.
- Signature segment other than `_` or `unsafe` while signing is disabled.
- Missing source kind or source identifier.
- Unknown processing option.
- Invalid option arity.
- Invalid enum value.
- Invalid integer, boolean, extension, or gravity coordinate.
- Multiple `@` format separators in a plain source URL.
- Chained pipeline separator `-` in this slice.

Planner semantic errors:

- Parsed but currently unsupported semantic combination.
- `best` output format in this slice.
- `gravity:sm` in this slice.
- `resizing_type:auto` and `resizing_type:fill-down` in this slice, regardless of which option assigned them.
- `extend:true` or non-default extend gravity in this slice, regardless of which option assigned them.
- Non-zero crop gravity offsets in this slice.

The error body can stay plain text for now.

## Testing Strategy

The implementation should be test-first and cover:

- Parser tests for each supported long option and alias.
- Parser tests for full enum coverage on `resizing_type`.
- Parser tests for omitted optional `resize` and `size` arguments.
- Parser tests for plain source extension with raw `@extension`, escaped `%40`, empty `@`, multiple raw `@` separators, and unknown extensions.
- Parser tests proving `format:best` and `@best` parse into normalized output format intent.
- Parser tests reserving a path segment exactly equal to `-` as an unsupported chained-pipeline separator while preserving values such as `fill-down`.
- Parser tests for equivalent meta-option and atomic-option combinations.
- Parser tests for last-wins duplicate option assignment.
- Parser tests proving `@extension` overrides an explicit format option.
- Parser tests for unsupported imgproxy options returning errors.
- Planner tests for current executable semantics: `fit`, `fill`, `force`, width-only, height-only, explicit output format, and gravity-driven crops.
- Planner tests proving unsupported semantic combinations fail before origin fetch: `format:best`, `@best`, `gravity:sm`, `resizing_type:auto`, `resizing_type:fill-down`, `extend:true`, and non-zero gravity offsets.
- Output tests proving omitted output format chooses AVIF/WebP from `Accept` by default, treats `q=0` as unacceptable, uses server preference order among acceptable formats, and falls back to the source format.
- Cache tests proving the selected automatic output format is included only when automatic output format selection can affect output.
- Plug-level tests for representative imgproxy-compatible URLs.
- README examples that match the implemented grammar.

## Documentation Strategy

The README should describe ImagePlug's public URL surface as imgproxy-compatible to the supported depth, not as a custom native API. It should show both long and short imgproxy forms:

```text
/_/resize:fill:300:200/gravity:ce/plain/images/cat.jpg@webp
/_/rs:fill:300:200/g:ce/plain/images/cat.jpg@webp
```

It should state that ImagePlug supports a subset of imgproxy options, but supported options follow imgproxy's full documented grammar for that option. Unsupported options fail explicitly.

It should also state that ImagePlug intentionally defaults `auto_avif` and `auto_webp` to enabled for omitted output formats. This differs from imgproxy's default configuration but uses imgproxy-compatible URL semantics and can be disabled by configuration.

## Open Decisions For Later Slices

- Whether to support base64 encoded source URLs before signed URLs.
- Whether `preset` should be implemented as a parser-level feature or as a config expansion step before semantic validation.
- Whether `quality`, `dpr`, and metadata controls should enter the request model before matching transform execution exists.
- Whether exact imgproxy `auto` and `fill-down` behavior should be implemented in transforms or remain explicit planner errors until needed.
- Create a follow-up issue to add pro object-oriented gravity support for `obj` and `objw` once ImagePlug has an object detection strategy.
- Create a follow-up issue to add Pro best-format support for `format:best` and `@best`, including preferred formats, complexity thresholds, best-by-default, best-format skip behavior, quality tuning, and cache key behavior.
- Create a follow-up issue to add Pro chained pipelines by introducing a multi-stage `ProcessingJob` model and `-` URL separator support.
