# Imgproxy Native Processing Options Design

## Summary

ImagePlug's Native API should accept the imgproxy-style processing options in this slice as its own path-oriented grammar. The Native parser may accept imgproxy-compatible option names and aliases, but imgproxy compatibility ends at parser canonicalization. `PlanBuilder` emits only ImagePlug-owned plan concepts, and runtime, cache, response, and transform modules must not depend on parser structs or imgproxy terminology.

The central design is to evolve the existing Native IR rather than add a separate imgproxy parser. `ImagePlug.Parser.Native.ParsedRequest` remains the top-level parsed request envelope. It gains sibling request facets so non-transform concerns do not get pushed into `PipelineRequest`. `PlanBuilder` then projects those facets into product-neutral `ImagePlug.Plan` fields so runtime, cache, and response code never need Native parser structs.

## Goals

- Treat imgproxy-compatible syntax as the current Native API grammar.
- Keep Native URL options declarative: option order controls assignment precedence only, never transform execution order.
- Preserve product-neutral core concepts below parsing.
- Keep transform modules reusable and composable over `ImagePlug.Transform.State`.
- Allow wholesale changes to existing transform modules when that produces cleaner product-neutral primitives.
- Validate parser and planner errors before origin fetch or cache access.
- Add small building blocks that can support other image processing dialects later.

## Non-Goals

- Do not add a separate `ImagePlug.Parser.Imgproxy` module in this slice.
- Do not expose ordered command semantics in the Native API.
- Do not implement `raw`, `max_bytes`, `max_src_resolution`, or `max_src_file_size` in this slice.
- Do not implement pro-only `crop_aspect_ratio`.
- Do not add compatibility quirks to core transform modules.
- Do not preserve backwards compatibility with old unreleased internals when a cleaner product-neutral model is needed.

## Current State

Native parsing currently flows through:

```text
ImagePlug.Parser.Native
  -> ImagePlug.Parser.Native.ParsedRequest
  -> ImagePlug.Parser.Native.PipelineRequest
  -> ImagePlug.Parser.Native.PlanBuilder
  -> ImagePlug.Plan
```

`PipelineRequest` currently holds geometry-like fields: width, height, resizing type, enlarge, extend, gravity, and offsets. `PlanBuilder` translates supported fields into product-neutral `ImagePlug.Transform` operations.

Output format is already separate from pipeline operations through `ImagePlug.Plan.Output`, `ImagePlug.Output.Policy`, and output negotiation. Cache key generation is already centralized in `ImagePlug.Cache.Key`. Runtime sending is centralized in `ImagePlug.Runtime.ResponseSender`.

Those boundaries are directionally correct, but existing transform module shapes are not fixed contracts. This is a greenfield library, so implementation should change or replace existing transforms if the current structs make the product-neutral design awkward. `ImagePlug.Plan` currently carries only source, pipelines, and output. To support cachebuster, expires, filename, and attachment without parser-specific runtime data, the plan must become the product-neutral runtime carrier for these facets.

## Native IR Shape

Keep `ParsedRequest` as the top-level envelope:

```elixir
%ImagePlug.Parser.Native.ParsedRequest{
  signature: "_",
  source_kind: :plain,
  source_path: ["images", "cat.jpg"],
  pipelines: [%ImagePlug.Parser.Native.PipelineRequest{}],
  output: %ImagePlug.Parser.Native.OutputRequest{},
  policy: %ImagePlug.Parser.Native.RequestPolicy{},
  cache: %ImagePlug.Parser.Native.CacheRequest{},
  response: %ImagePlug.Parser.Native.ResponseRequest{}
}
```

The names above describe responsibility rather than final field details. `OutputRequest` should replace the current top-level `output_format` field so output concerns live in a dedicated sibling facet instead of being represented as a transitional special case or pushed into `PipelineRequest`.

`PlanBuilder` should produce a product-neutral plan shaped like:

```elixir
%ImagePlug.Plan{
  source: %ImagePlug.Plan.Source.Plain{},
  pipelines: [%ImagePlug.Plan.Pipeline{}],
  output: %ImagePlug.Plan.Output{},
  policy: %ImagePlug.Plan.Policy{},
  cache: %ImagePlug.Plan.Cache{},
  response: %ImagePlug.Plan.Response{}
}
```

The exact module names may be adjusted during implementation, but the ownership must not change: Native parser structs stop at planning, and runtime code consumes only product-neutral plan structs.

Although the public parser callback returns a product-neutral plan, the implementation should keep parsing and planning as separate internal phases: URL grammar to `ParsedRequest`, then `PlanBuilder` to `ImagePlug.Plan`.

### PipelineRequest

`PipelineRequest` describes executable image pipeline intent only:

- dimensions: width, height, min width, min height
- resize mode: fit, fill, fill-down, force, auto
- enlarge behavior
- extend/canvas behavior
- extend-to-aspect-ratio behavior
- gravity/focus for crop-like operations
- pre-resize crop request
- orientation transforms: auto-orient, rotate, flip
- scale modifiers: two-axis zoom and dpr

The request is still declarative. `PlanBuilder` owns the fixed operation order.

Pre-resize crop intent must have its own nested request shape and must not reuse the global/final gravity fields:

```elixir
%ImagePlug.Parser.Native.PipelineRequest{
  crop: nil | %ImagePlug.Parser.Native.CropRequest{
    width: ImagePlug.imgp_length() | :auto,
    height: ImagePlug.imgp_length() | :auto,
    gravity: ImagePlug.Parser.Native.PipelineRequest.gravity(),
    gravity_x_offset: float(),
    gravity_y_offset: float()
  },
  gravity: ImagePlug.Parser.Native.PipelineRequest.gravity(),
  gravity_x_offset: float(),
  gravity_y_offset: float()
}
```

`CropRequest` gravity and offsets describe the source-space pre-resize crop. The top-level pipeline gravity and offsets describe later cover/fill/result crop behavior. They are independent fields and must not overwrite each other.

### OutputRequest

`OutputRequest` describes encoding intent:

- explicit or automatic format
- quality
- per-format quality overrides

Output quality is not a transform. It should be consumed by output policy and encoding, not represented as a pipeline operation.

### RequestPolicy

`RequestPolicy` describes validity checks that must happen before origin identity resolution, origin fetch, or cache lookup:

- expiration timestamp

Expiration validation is owned by Native parsing/planning. Native parsing/planning must reject expired requests before returning a successful plan. `ImagePlug.Parser.Native.parse(conn, opts)` must reject expiration before returning `{:ok, %ImagePlug.Plan{}}`. If parsing and planning become separate public steps, expiration validation may happen in either step, but no caller may obtain a valid `ImagePlug.Plan` for an expired request.

Expiration validation depends on a clock. Change the parser behaviour to `parse(conn, opts)` and have `ImagePlug.call/2` pass validated init options to the configured parser. Native parsing/planning should read `:now` from those options and pass it through to `PlanBuilder`; when `:now` is absent, use `DateTime.utc_now()` or the equivalent wall-clock source. This makes Plug-level expiration tests deterministic without hiding the clock inside parser internals.

`expires` / `exp` accepts a base-10 Unix timestamp in seconds. Non-integer values are parser errors. `0` means no expiration. Negative values are invalid. `:now` must be a `DateTime`, an integer Unix timestamp in seconds, or a zero-arity function returning either of those. If `:now` is a function, call it once per parse/planning attempt and normalize that single result. Normalize both `expires` and `:now` to Unix seconds before comparison. A request is expired when `expires > 0 and expires < now_unix_seconds`; equality is still valid for the current second. Use a stable error such as `{:expired_request, expires}` for expired requests and `{:invalid_expires, value}` / `{:invalid_now, value}` for malformed values.

In this slice, a valid, non-expired timestamp is request validity policy only: it must not emit response headers and must not be stored in `ImagePlug.Cache.Entry` headers. Runtime validation before `SourceIdentity.resolve/2` is still required for product-neutral plan shape and as defense in depth, but expiration should not be deferred to `RequestRunner`.

### CacheRequest

`CacheRequest` describes deterministic cache key material that does not alter image processing:

- cachebuster string

Changing cachebuster must change cache keys, but it must not change planned transform operations.

`PlanBuilder` maps this to `ImagePlug.Plan.Cache`, and `ImagePlug.Cache.Key` reads that neutral plan field. Cache code must not inspect `ImagePlug.Parser.Native.CacheRequest`.

### ResponseRequest

`ResponseRequest` describes response delivery metadata:

- filename
- attachment disposition

These fields should influence response headers only.

`PlanBuilder` maps this to `ImagePlug.Plan.Response`, and response sending reads that neutral plan field. Response code must not inspect `ImagePlug.Parser.Native.ResponseRequest`.

`ImagePlug.Plan.Response` should carry normalized delivery fields, not parser syntax:

```elixir
%ImagePlug.Plan.Response{
  disposition: :default | :inline | :attachment,
  filename: nil | %ImagePlug.Plan.Response.Filename{}
}
```

When a filename is provided, Native parsing decodes it if requested by the URL grammar, then validates the decoded value before planning succeeds. Native accepts `filename:%filename:%encoded` / `fn:%filename:%encoded`; the second argument is optional and parsed with the Native boolean parser. When it is truthy, `%filename` is decoded with URL-safe raw, unpadded Base64. Padded Base64, malformed Base64, more than two filename arguments, and Base64-decoded bytes that are not valid UTF-8 are parser errors. When the encoded flag is omitted or false, the parser keeps the URL-decoded path argument as the filename stem. Empty filenames, CR/LF, NUL, other control characters, `/`, and `\\` are invalid. Valid non-ASCII UTF-8 filenames are allowed, but response rendering must be deterministic: emit a conservative ASCII `filename` fallback and an RFC 5987-style `filename*` value for the UTF-8 filename. Response rendering owns header escaping; it should consume the normalized `Plan.Response.Filename`, not raw parser arguments.

The product-neutral `Plan.Response` allows `filename: nil` for non-Native callers and future APIs. Native planning always populates `filename`, either from the explicit filename option or from a source-derived default stem. If no filename is provided, Native response planning derives the default stem from the source basename with the source path extension removed. If no source basename is available, use `image`. This is a Native/imgproxy compatibility rule, but it is projected into product-neutral `ImagePlug.Plan.Response` before runtime.

The normalized filename is a basename stem, not a complete delivery filename. Response rendering appends the extension for the resolved output format. On cache hits, derive that extension from the cached entry content type; on cache misses, derive it from `ImagePlug.Output.Resolved.format`. If a supplied filename includes an extension-like suffix, treat it as part of the stem and still append the resolved output extension. This keeps delivery filenames aligned with negotiated output bytes and avoids making response metadata part of the cache key.

ASCII filename fallback must be deterministic. Replace every non-ASCII or unsafe fallback character with `_`. The implementation may collapse repeated `_`, but must do so consistently. If the fallback stem becomes empty, use `download`. The RFC 5987 `filename*` parameter should preserve the valid UTF-8 filename stem plus resolved extension.

Examples:

```text
fn:cat + resolved webp -> cat.webp
fn:cat.jpg + resolved webp -> cat.jpg.webp
fn:report + resolved jpeg -> report.jpg
fn:katt-æøå + resolved webp -> filename="katt-___.webp"; filename*=UTF-8''katt-%C3%A6%C3%B8%C3%A5.webp
fn:東京 + resolved png -> filename="download.png"; filename*=UTF-8''%E6%9D%B1%E4%BA%AC.png
/plain/images/cat.jpg + resolved webp -> cat.webp
/plain/images/cat@webp + resolved webp -> cat.webp
/plain/ with no source basename + resolved png -> image.png
```

Supported content type to filename extension mapping is:

```text
image/jpeg -> jpg
image/png -> png
image/webp -> webp
image/avif -> avif
```

Cached entries with other content types are invalid for this response path and should be treated as cache entry errors rather than producing a non-deterministic filename.

Content disposition mapping:

- Omitted `return_attachment`: use `disposition: :default`, resolved by response configuration. The initial ImagePlug default should resolve to inline.
- Disposition `:inline`: emit `Content-Disposition: inline` with filename parameters.
- Disposition `:attachment`: emit `Content-Disposition: attachment` with filename parameters.
- `return_attachment:true` sets disposition to `:attachment`.
- `return_attachment:false` sets disposition to `:inline`.
- `return_attachment:false` is an explicit inline disposition, not the same as omitting `return_attachment`.
- Later global assignments win across the whole URL, so a later `return_attachment` assignment may change the disposition created by an earlier one, while filename and disposition remain separate fields.

Native always emits `Content-Disposition` for successful image responses. This is intentional product behavior for Native/imgproxy compatibility, not an accidental side effect of filename parsing.

## Option Classification

### Geometry And Transform Planning

The following options map to product-neutral pipeline request fields:

```text
resize, rs
size, s
resizing_type, rt
width, w
height, h
min-width, mw
min-height, mh
zoom, z
dpr
enlarge, el
extend, ex
extend_aspect_ratio, extend_ar, exar
gravity, g
crop, c
auto_rotate, ar
rotate, rot
flip, fl
```

Product-neutral concepts:

- `resize`, `size`, `resizing_type`, `width`, `height`, and `enlarge` become resize intent.
- `min-width` and `min-height` become minimum output constraints.
- `zoom` becomes two independent scale modifiers, `zoom_x` and `zoom_y`; the one-argument grammar sets both axes. `dpr` becomes a layout-preserving scale modifier that may later be clamped to an effective dpr during dimension resolution.
- `extend` becomes canvas extension or letterbox intent.
- `extend_aspect_ratio` becomes aspect-ratio canvas extension intent.
- `gravity` becomes focus/anchor intent.
- `crop` becomes pre-resize crop intent.
- `auto_rotate`, `rotate`, and `flip` become orientation intent.

### Output Encoding

The following options map to `OutputRequest`:

```text
quality, q
format_quality, fq
format, f, ext
plain source @extension
```

The source `@extension` continues to override explicit format options after option parsing, matching current Native behavior.

Source `@extension` is syntactically part of source parsing but semantically an output request override. It belongs in `OutputRequest` and `ImagePlug.Plan.Output`, not `ImagePlug.Plan.Source`.

### Request And Delivery Metadata

The following options map to non-pipeline request facets:

```text
cachebuster, cb
expires, exp
filename, fn
return_attachment, att
```

`cachebuster` changes cache identity only. `expires` validates before side effects. `filename` and `return_attachment` affect `Content-Disposition` only.

### Dropped From This Slice

The following options are not part of this implementation slice:

```text
raw
max_bytes, mb
max_src_resolution, msr
max_src_file_size, msfs
crop_aspect_ratio, crop_ar, car
```

Unknown or dropped options should remain parser errors. The parser should not accept these as dormant fields because accepting unsupported safety or passthrough options would imply a contract that does not exist yet.

## Option Scope

Native currently supports multiple pipeline groups separated by `-`. This design keeps that split:

- Pipeline options are scoped to the group where they appear.
- Global options may appear in any group, but normalize into one request-level field with later assignments winning across the full URL from left to right.
- Global options are `format`, source `@extension`, `quality`, `format_quality`, `cachebuster`, `expires`, `filename`, and `return_attachment`.
- Source `@extension` is parsed after option groups and overrides any earlier `format` option.
- `format_quality` entries are merged by normalized output format, with later entries replacing earlier entries for the same format.

This preserves the existing per-pipeline behavior for image operations while making non-pipeline facets unambiguously request-wide.

Parser implementation should maintain separate accumulators while walking option segments left to right:

- a current pipeline accumulator for group-scoped pipeline fields
- a request-level accumulator for global facets

When `-` is encountered, only the current pipeline accumulator is finalized and reset. The request-level accumulator keeps its values. Finalizing a pipeline group must never copy request-global fields into the finalized `PipelineRequest`. Global facets must not be derived later from already-merged per-pipeline keyword lists, because that makes ordering across groups harder to reason about and risks leaking global fields into `PipelineRequest`.

Pipeline groups that contain only global options must not become executable no-op pipelines. After global fields are extracted, empty pipeline groups are dropped before `ImagePlug.Plan` construction and before cache key material is built. Explicit no-transform requests still produce the canonical single empty pipeline only when the whole request has no pipeline operations at all. URL grouping syntax alone must not change product-neutral plan shape or cache key material.

Empty separator groups are also dropped during canonicalization. This makes leading, trailing, or repeated separators harmless grouping syntax rather than cache-key material.

Required examples:

```text
/f:webp/-/w:100/plain/source.jpg        -> output format webp; second pipeline width 100
/w:100/-/f:webp/plain/source.jpg        -> first pipeline width 100; output format webp
/q:80/-/q:70/plain/source.jpg           -> output quality 70
/fq:webp:80/-/fq:webp:70/plain/source.jpg -> webp format quality 70
/att:true/-/att:false/plain/source.jpg  -> response disposition inline
/fn:a/-/fn:b/plain/source.jpg           -> response filename stem b
/f:webp/plain/source.jpg                -> one canonical empty pipeline; output format webp
/f:webp/-/q:80/plain/source.jpg         -> one canonical empty pipeline; output format webp; quality 80
/-/w:100/plain/source.jpg               -> one pipeline with width 100
```

Parser tests should cover global options before and after `-`, including later-wins behavior across group boundaries.

## Canonicalization Requirements

`PlanBuilder` must produce the same product-neutral plan for semantically equivalent Native URLs, regardless of option alias and option ordering, and regardless of source output-extension spelling where the resolved source identity is the same. Later-assignment-wins intentionally changes the selected field value.

Examples:

```text
/w:100/h:200/plain/a.jpg
/width:100/height:200/plain/a.jpg
```

These produce the same plan.

```text
/w:100/h:200/plain/a.jpg
/h:200/w:100/plain/a.jpg
```

These produce the same plan because option order is not execution order.

```text
/w:100/w:200/plain/a.jpg
```

This produces width `200` because later assignments to the same canonical field win.

Canonicalization should directly feed cache key tests. Equivalent aliases and equivalent orderings must serialize to the same cache key material.

## Fixed Runtime Order

URL order must not define execution order. Native parsing may use later-assignment-wins for fields that normalize to the same canonical field, but `PlanBuilder` owns operation order.

The product-neutral request flow for this slice is:

1. Parse Native URL into Native IR.
2. Build a product-neutral `ImagePlug.Plan`.
3. During Native parsing/planning, validate all parser-owned client errors, including expiration.
4. In `ImagePlug.call/2`, validate all product-neutral plan shape, pipeline operation shape, output, cache, response, and non-time-dependent policy fields that can produce client errors.
5. Resolve origin identity.
6. Build deterministic cache key material from origin identity, canonical plan fields, configured vary inputs, cachebuster, and output intent/key material.
7. Look up cached encoded image body when caching is configured and the planned operations are cacheable.
8. On cache hit, send the cached encoded body with request delivery metadata from `ImagePlug.Plan.Response`.
9. On cache miss or uncached requests, fetch the origin.
10. Decode and validate origin limits.
11. Apply pre-resize crop when requested, using source-space crop dimensions and crop-specific gravity offsets that are not scaled by `zoom` or `dpr`.
12. Apply auto-orientation when enabled.
13. Apply explicit rotation and flip.
14. Apply resize, min constraints, and enlarge semantics, using dimensions resolved from `zoom_x`, `zoom_y`, and the effective dpr for this source image.
15. Apply cover/fill crop using gravity/focus when needed, using offsets resolved with the effective dpr.
16. Apply extend or extend-aspect-ratio canvas behavior when requested, using canvas dimensions resolved from `zoom_x`, `zoom_y`, and the effective dpr, and extend offsets normalized only by the explicit offset rules below.
17. Resolve final output format and effective encoding quality.
18. Encode and send the response with request delivery metadata from `ImagePlug.Plan.Response`.

Output intent and key material must be available before origin fetch so cache lookup can happen before origin work. Final output format selection may still need origin source format for automatic source-format fallback; that is an output policy detail, not URL-order-dependent transform planning.

`ImagePlug.call/2` must validate the product-neutral plan before resolving source identity. Keeping validation only inside `RequestRunner.run/4` is not sufficient for client-visible plan errors because `SourceIdentity.resolve/2` currently runs before `RequestRunner`. Invalid client requests must fail before source identity resolution, cache lookup, origin fetch, or decode. Expiration remains parser/planner-owned as described in `RequestPolicy`; this product-neutral validation is for plan shape and non-time-dependent policy invariants.

`zoom` and `dpr` are request modifiers that normalize planned operation parameters before runtime execution. They are not standalone runtime transforms and should not appear as later operations that can change the meaning of an already-executed crop. `zoom` is two-axis: `zoom:%zoom_x_y` sets both axes, while `zoom:%zoom_x:%zoom_y` sets width and height scaling independently. The pre-resize crop rectangle, including crop-specific gravity offsets, is oriented source coordinate-space intent and is not scaled by `zoom` or `dpr`.

Pre-resize crop must account for pending orientation operations. The semantic crop intent is evaluated against the oriented/flipped source coordinate space, but implementation may physically crop before auto-orientation, explicit rotate, or flip for efficiency. If it does, a core product-neutral geometry helper must map the crop request back into physical source coordinates by applying the inverse of the pending orientation operations. That mapping includes remapping gravity, remapping offsets, and swapping crop width/height for 90/270-degree rotations.

This logic belongs in the core library, not in the Native parser and not in an imgproxy adapter. The Native parser should only translate URL grammar into semantic crop and orientation intent. `PipelinePlanner` or the runtime dimension-resolution step should call a reusable helper such as `ImagePlug.Transform.Geometry.CropCoordinateMapper` once source metadata is known, because EXIF orientation and source dimensions are runtime facts. The executable crop transform should receive already-mapped physical crop coordinates when it runs before orientation, or it should receive semantic coordinates only if it is explicitly ordered after orientation. It must never silently crop physical source coordinates using an oriented semantic gravity.

The implementation plan can stage this order incrementally, but must keep the contract that the planner, not URL option order, determines transform execution order.

## Product-Neutral Transform Requirements

Executable transforms should be named and parameterized by ImagePlug concepts, not vendor concepts:

- Use `ImagePlug.Transform.Crop` for crop-before-resize behavior.
- Add product-neutral orientation transforms such as `ImagePlug.Transform.Rotate`, `ImagePlug.Transform.Flip`, and optionally `ImagePlug.Transform.AutoOrient` if implementation needs an executable operation.
- Represent canvas extension as neutral contain/embed/extend behavior, not imgproxy-specific extend behavior.
- Keep `quality`, `cachebuster`, `expires`, `filename`, and `return_attachment` out of transform modules.

Transform structs should keep explicit parameter structs or typed fields, expose the existing `ImagePlug.Transform` behaviour, and return tagged runtime errors through existing transform execution flow.

Existing transform modules may be changed wholesale. The implementation should prefer a small set of correct, composable, product-neutral transforms over preserving the current transform APIs.

## Imgproxy Reference Material

When imgproxy semantics are unclear, implementation should consult the local non-pro imgproxy reference material:

- Source: `/Users/hlindset/src/image_plug/local/imgproxy-master`
- Docs: `/Users/hlindset/src/image_plug/local/imgproxy-docs-master/versioned_docs/version-4-pre`

Use those references to understand non-pro behavior, validation, and pipeline ordering. The result should still be translated into ImagePlug concepts; do not copy imgproxy product names into core transforms or runtime policies unless the name is part of the Native URL grammar.

## Runtime Boundaries

### Parser And Planner Validation

Invalid option names, invalid values, expired timestamps, malformed filenames, and unsupported semantics must fail before origin fetch or cache access. This preserves request safety boundaries.

Client-request validation must happen before `SourceIdentity.resolve/2` unless the error inherently depends on origin bytes or decoded pixels.

| Error type | Detected by | Before source identity? |
| --- | --- | --- |
| Unknown option | Native parser | yes |
| Invalid option arity or scalar value | Native parser | yes |
| Expired timestamp | Native parser/planner policy validation with injectable `:now` from parser opts | yes |
| Malformed filename after URL/Base64 decoding | Native parser or planner response validation | yes |
| Invalid output format or quality | Native parser or planner output validation | yes |
| Invalid crop dimensions or offsets | Native parser or planner pipeline validation | yes |
| Invalid dpr or zoom | Native parser or planner pipeline validation | yes |
| Impossible or unsupported resize/canvas semantics | Planner or product-neutral plan validator | yes |
| Invalid product-neutral plan shape | `ImagePlug.Plan.validate_shape/1` before source identity resolution | yes |
| Origin URL cannot be resolved against configured origin policy | `SourceIdentity.resolve/2` | no |
| Origin fetch failure | runtime origin fetch | no |
| Origin body too large | runtime origin fetch | no |
| Decoded image too large | runtime decode validation | no |
| Transform execution failure caused by origin dimensions or image library behavior | runtime transform execution | no |

### Error And Canonical Serialization Conventions

Parser, planner, and product-neutral plan validation should return stable tagged client errors. Expiration errors use `{:expired_request, expires}`, `{:invalid_expires, value}`, and `{:invalid_now, value}`. Other parser/planner errors should follow the same tagged style and should not depend on exception messages.

Preferred general shapes:

```elixir
{:unknown_option, option}
{:invalid_option, option, reason}
{:unsupported_option, option}
{:invalid_plan, reason}
```

All product-neutral plan structs that participate in cache keys must have canonical serialization. Conditional operations, including adaptive resize and effective-dpr clamping, serialize their rule parameters into cache key material, not the runtime branch outcome. Cache key material should include normalized `zoom_x`, `zoom_y`, and requested dpr inputs, plus the fact that effective dpr is resolved by the ImagePlug/imgproxy-compatible dimension rule. It must not depend on the source-dimension-specific effective dpr value because cache lookup happens before origin fetch. Global-only and empty pipeline groups are removed before serialization so grouping syntax alone cannot change the key.

### Output Encoding

`OutputRequest` should flow into `ImagePlug.Plan.Output`. That plan struct should carry:

- mode: `:automatic` or `{:explicit, format}`
- quality: `:default` or `{:quality, 1..100}`
- format qualities: a map or keyword list keyed by normalized product-neutral formats

`quality:0` from Native means `:default`, not an explicit override that suppresses `format_quality`. Non-zero quality must be in `1..100`. Per-format qualities use the same range and override the default quality only when the resolved output format matches. If both non-default `quality` and a matching `format_quality` are present, the explicit global quality wins for the request because it is the direct output-quality field; `format_quality` supplies format-specific defaults.

`quality` and `format_quality` are distinct canonical fields. Later-wins applies within each field, not between them. At output resolution time, explicit `quality` overrides any matching `format_quality` regardless of URL order.

Examples:

```text
/q:0/plain/source.jpg                  -> global quality default
/q:80/plain/source.jpg                 -> global quality 80
/fq:webp:70/plain/source.jpg           -> webp quality 70 when resolved format is webp
/q:80/fq:webp:70/plain/source.jpg      -> effective quality 80 for webp
/fq:webp:70/q:80/plain/source.jpg      -> effective quality 80 for webp
/fq:webp:70/fq:webp:60/plain/source.jpg -> webp format quality 60
/q:0/fq:webp:70/plain/source.jpg       -> effective quality 70 for webp
/fq:webp:70/q:0/plain/source.jpg       -> effective quality 70 for webp
/q:80/fq:webp:0/plain/source.jpg       -> effective quality 80 for webp
/fq:webp:0/plain/source.jpg            -> effective quality default for webp
```

`format_quality:<format>:0` normalizes that format-specific value to `:default`, consistent with `quality:0`.

Encoding quality should be applied when writing the final image body. Cache key material should include normalized output intent and the effective quality rule needed to reproduce bytes:

- Include explicit format or automatic output mode.
- Include normalized automatic-output `Accept` candidates and auto-format configuration.
- Include explicit global quality when present.
- Include the full normalized `format_quality` map when global quality is default, because the resolved output format may be selected after cache lookup.

This may produce separate cache entries for different per-format quality maps even when a specific resolved response would use the same effective quality. That is acceptable because it keeps cache lookup pre-origin and deterministic.

Both direct streaming and cache storage must encode through the same product-neutral resolved output carrier:

```elixir
%ImagePlug.Output.Resolved{
  format: :avif | :webp | :jpeg | :png,
  quality: :default | {:quality, 1..100},
  representation_headers: [{String.t(), String.t()}]
}
```

`ImagePlug.Output.Policy` should resolve this value after final format selection. `ResponseSender`, `ResponseCache.store`, and any in-memory encoder should consume the same resolved output value so cached bodies and uncached streamed bodies use identical format and quality rules.

### Cache Keys

Cache key material should include:

- resolved origin identity
- canonical planned pipeline request fields
- output intent and quality key material as defined above
- cachebuster
- configured vary inputs
- normalized `Accept` inputs for automatic output

For explicit output format, `Accept` must not affect output-negotiation cache key material. Configured `key_headers` still apply as explicit caller-controlled vary inputs; if a caller configures `key_headers: ["accept"]`, the raw selected `Accept` header value remains part of the configured-vary portion of the key even though output negotiation ignores it. For automatic output mode, `Accept` is normalized into the ordered list of supported candidate formats after applying explicit exclusions (`q=0`), server auto-format configuration, and ImagePlug's server preference order. Unsupported formats and raw q-values are not kept in output-negotiation key material after candidate normalization. Equivalent headers that produce the same supported candidate list must produce the same output-negotiation key material.

Cache keys should not include original URL option order. Cache keys should also not include `ImagePlug.Plan.Response` delivery metadata such as filename or attachment mode, because those fields do not affect encoded image bytes.

### Response Headers

`ResponseRequest` should be consumed by `ResponseSender` or a response policy helper. It should add a deterministic `Content-Disposition` header for every successful Native image response, using either the explicit filename stem or the source-derived default stem.

`RequestRunner` delivery tuples or response-sending APIs must carry `ImagePlug.Plan.Response` through to `ResponseSender`. Do not reach back to the parser or connection path to recover filename behavior.

Cached entries should store encoded image bytes and cacheable representation headers such as `vary` and cache-control headers derived from cache configuration or origin policy. They should not store per-request delivery headers such as `Content-Disposition`, and they should not store expiration-derived headers from `ImagePlug.Plan.Policy`. `ResponseSender` must apply `ImagePlug.Plan.Response` on both cache hits and cache misses, so two requests that differ only by filename or attachment mode can share the same encoded image cache entry while receiving different delivery headers.

Use this explicit delivery contract so response metadata cannot be dropped:

```elixir
{:cache_entry, %ImagePlug.Cache.Entry{}, %ImagePlug.Plan.Response{}}
{:image, %ImagePlug.Transform.State{}, %ImagePlug.Output.Resolved{}, %ImagePlug.Plan.Response{}}
```

Tests must prove cache hits and cache misses both apply `Plan.Response`.

## Testing Strategy

The implementation plan should use test-first development around these boundaries:

- Parser tests for each newly accepted option and alias.
- Parser tests for later-assignment-wins behavior.
- Property or example tests showing URL option order does not change planned operation order.
- Plan builder tests for crop, orientation, min dimensions, zoom/dpr, extend, and output request separation.
- Runtime tests proving expired requests return before origin fetch and before cache lookup.
- Cache key tests proving cachebuster changes cache keys without changing transforms.
- Output policy or encoder tests proving quality and format quality are resolved at encoding boundaries.
- Response sender tests proving filename and attachment map to `Content-Disposition`.
- Parser scope tests for `/f:webp/-/f:jpeg/plain/source.png`, `/w:100/-/h:200/plain/source.png`, and `/w:100/-/q:80/plain/source.png`.
- Cache key tests proving requests differing only by filename share cache keys, requests differing by cachebuster do not, and alias-equivalent geometry requests share cache keys.
- Response delivery tests proving cache misses and cache hits both apply default source-derived filename, explicit `filename`, `return_attachment:true`, and `return_attachment:false`, including invalid filename rejection for empty strings, path separators, CR/LF, NUL, malformed Base64, Base64-decoded invalid UTF-8, and valid non-ASCII UTF-8 stems. These tests should assert that Native always emits `Content-Disposition` for successful image responses.
- Output quality tests for `q:0`, `q:80`, `fq:webp:70`, `q:80/fq:webp:70`, `fq:webp:70/q:80`, and repeated `fq` assignments.
- Dimension-resolution tests for min-width/min-height with `rs:fit:100:0/mw:300`, `rs:fit:100:0/z:2/mw:300`, and `rs:fit:100:0/dpr:2/mw:300` against a 1000x1000 source and at least one smaller source where effective dpr clamps below requested dpr.
- Pure crop/orientation coordinate mapping tests for auto-orient, rotate 90/270, flip, and rotate+flip combinations without depending on image encoding.

## Documentation Strategy

The README should continue to describe Native URLs as path-oriented and declarative. The option list should be updated to include the supported imgproxy-compatible options from this slice, with a short note that ImagePlug uses imgproxy-compatible names as Native grammar while keeping internals product-neutral.

The docs should explicitly say:

- URL option order is not processing order.
- Later assignments to the same canonical field win.
- Dropped options in this slice are not accepted.
- Output, cache, request validity, and response metadata options are not transforms.

## Implementation Decisions

The implementation plan should follow these decisions:

- Introduce `OutputRequest` as the Native IR field for output intent and remove the current `ParsedRequest.output_format` shape as part of this work. This project is greenfield, so the implementation should prefer the clean model over compatibility bridges.
- Model `auto_rotate` as orientation policy that runs before explicit `rotate` and `flip`. If the image library exposes autorotation as a decode/open option, implementation may use that internally, but the Native IR should still describe it as product-neutral orientation intent.
- Model `zoom` and `dpr` separately. `zoom` has independent width and height factors: the one-value form sets both axes, and the two-value form sets `zoom_x` and `zoom_y`. `zoom_x` scales requested output width and extend canvas width; `zoom_y` scales requested output height and extend canvas height. `zoom` does not scale offset-like fields. `dpr` scales requested output dimensions and absolute offset-like fields through an effective dpr value, matching the intent that HiDPI requests preserve layout geometry without forcing enlargement beyond imgproxy-compatible limits.
- Model `min-width` and `min-height` as minimum scaled-image constraints applied during the same planner normalization that computes resize scale. They do not replace requested `width` or `height`; they lower the shrink factor when needed so the scaled intermediate image is not smaller than the requested minimum. When both `width` and `min-width` are set, the final/result crop is still according to `width`; likewise, when both `height` and `min-height` are set, the final/result crop is still according to `height`.
- `dpr` participates in the same encoded-output scale calculation used for requested dimensions, but the requested dpr is not always the effective dpr. For non-vector images with `enlarge:false`, imgproxy clamps the effective dpr before min constraints so requested HiDPI output does not force source enlargement. If a min constraint becomes the limiting scale, the scaled intermediate can exceed the requested encoded target and can be multiplied by the effective dpr before result crop. `zoom` does not directly multiply min width or min height; it affects the base resize scale before minimum constraints are checked. Consult the local non-pro imgproxy reference when implementing exact interactions with `fit`, `fill`, `fill-down`, `force`, crop, and extend.
- Examples for a square 1000x1000 source with `enlarge:false`, no explicit crop, and no extend: `rs:fit:100:0/mw:300` may scale an intermediate image to at least 300px wide, then result-crop back to the requested 100px target width; `rs:fit:100:0/z:2/mw:300` still uses `mw:300` as the minimum scaled-image width, not `600`, while the requested target width becomes 200px from zoom; `rs:fit:100:0/dpr:2/mw:300` may scale an intermediate image to 600px wide because the min-limited scale is multiplied by the effective dpr, then result-crop back to the requested 200px encoded target width. A smaller source may clamp effective dpr below the requested dpr before min constraints; do not multiply min constraints by raw dpr in isolation.
- Apply `zoom_x` to requested width and extend canvas width. Apply `zoom_y` to requested height and extend canvas height. Do not apply either zoom axis directly to min width, min height, source-space pre-resize crop dimensions, gravity offsets, extend offsets, focal point coordinates, response metadata, cache metadata, or output quality.
- Apply effective dpr to requested width, requested height, extend canvas dimensions, final cover/fill absolute gravity offsets, and absolute extend offsets. Effective dpr participates in min-width/min-height scale calculation as described above, but min constraints should remain explicit constraints in source scale calculation rather than fields pre-multiplied by raw dpr. Do not apply dpr to source-space pre-resize crop dimensions, crop-specific gravity offsets, relative offsets with absolute value below `1`, focal point coordinates, response metadata, cache metadata, or output quality.
- Keep unit normalization explicit. Imgproxy-style numeric crop dimensions normalize `0` to `:auto`, reject negatives, use relative scale for values greater than `0` and below `1`, and use absolute pixel-like values for values greater than or equal to `1`. Imgproxy-style offsets are relative when `abs(offset) < 1` and absolute pixel-like values when `abs(offset) >= 1`; negative absolute offsets are valid for non-focal anchor offsets. Product-neutral transforms should receive explicit units such as `{:pixels, value}` or `{:scale, value}` rather than naked imgproxy numbers.
- Run one dimension-normalization pass for `zoom`, requested dpr, effective dpr, and unit conversion before executable transforms are constructed. The request plan can carry the product-neutral dimension rule before origin fetch; after source dimensions are known, a product-neutral dimension-resolution helper computes concrete parameters from that rule. Runtime transforms must not read request-level `zoom` or `dpr`; they should receive concrete operation parameters or the helper result.
- Normalize all pixel dimensions that reach transform structs to positive integers. Use documented rounding rules compatible with imgproxy: positive dimension scaling uses nearest-integer rounding for the scaled value, while gravity/focus/extend positioning uses ties-to-even rounding for relative offsets, absolute offsets after effective dpr scaling, and center-position calculations. Offsets may remain floats in plan structs until a crop, cover, or extend operation resolves them against concrete image dimensions; if an image library call requires integers, round positioning values ties-to-even at that operation boundary.
- Implement `extend` and `extend_aspect_ratio` through a neutral canvas operation, such as `ImagePlug.Transform.ExtendCanvas`, rather than encoding imgproxy-specific concepts in existing transforms. Existing `Contain` letterboxing may share implementation helpers, but the request and transform names should stay product-neutral.
- Implement `fill-down` and `auto` as planner resize semantics, not parser-only accepted values.
- Model `auto` resize with a neutral conditional operation, such as `ImagePlug.Transform.AdaptiveResize`, whose parameters describe the rule directly: use cover/fill behavior when source and target orientation match, and contain/fit behavior otherwise. The parser should not expose an imgproxy-specific transform name, and runtime selection must depend only on image dimensions and requested dimensions, not URL order.
- Model orientation with a product-neutral plan field, such as `%ImagePlug.Plan.Orientation{auto_orient: boolean(), rotate: 0 | 90 | 180 | 270, flip: :none | :horizontal | :vertical | :both}`. Native parser fields may be named for URL grammar, but the plan field should describe ImagePlug orientation intent.
- Accept any integer multiple of 90 for `rotate` / `rot`, including negative values and values greater than 270. Normalize to the product-neutral `0 | 90 | 180 | 270` representation before planning transform operations.
- Model flip grammar as imgproxy-compatible booleans: `flip:%horizontal:%vertical` / `fl:%horizontal:%vertical`, with each argument optional and parsed with the Native boolean parser. Normalize to `:none`, `:horizontal`, `:vertical`, or `:both`.
- Implement crop/orientation mapping as a named pure geometry component in the core transform/geometry library, such as `ImagePlug.Transform.Geometry.CropCoordinateMapper` or `ImagePlug.Transform.Geometry.OrientationMapper`. Native must not own this mapping; it should only produce product-neutral crop/orientation intent. The mapper should accept source dimensions, EXIF orientation intent, explicit rotate/flip intent, crop dimensions, gravity, and offsets, then return physical crop coordinates suitable for crop-before-orientation execution. It should have pure unit tests for EXIF orientation/auto-orient, rotate 0/90/180/270, horizontal flip, vertical flip, combined rotate+flip, auto crop dimensions, compass gravity, positive and negative absolute offsets, relative offsets, and focal-point gravity if supported in crop.
- Update architecture boundary tests so any new concrete transform modules are covered by the same rule that runtime code must not depend on concrete transform modules directly.

These choices are implementation details. They must not change the high-level boundary: parser syntax is imgproxy-compatible Native grammar, but planned operations and runtime policies are product-neutral.

## Implementation Milestones

The implementation plan should split this design into reviewable slices:

1. Introduce plan facets: `ImagePlug.Plan.Policy`, `ImagePlug.Plan.Cache`, `ImagePlug.Plan.Response`, and the Native `OutputRequest`.
2. Refactor Native parser accumulators and global-vs-pipeline option scope.
3. Implement output format, quality, and format-quality canonicalization.
4. Implement cache key changes, including cachebuster and automatic-output `Accept` normalization.
5. Implement response filename and disposition rendering on cache hits and misses.
6. Implement expiration pre-side-effect validation with injectable `:now`.
7. Implement geometry, orientation, crop, zoom, dpr, extend, fill-down, and auto resize additions.
8. Add runtime ordering and architecture boundary tests.

The geometry/orientation/crop work is the riskiest slice and should not block the cleaner IR, cache, output, and response refactors from landing first.
