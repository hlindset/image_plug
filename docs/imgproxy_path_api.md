# Imgproxy Path API

## Mental Model

An Imgproxy URL describes desired output, not a step-by-step image pipeline.
ImagePlug normalizes aliases, resolves conflicts, builds a product-neutral plan, and executes transforms in Imgproxy canonical order.

The Imgproxy URL API accepts imgproxy-compatible option names where ImagePlug supports the same semantics. ImagePlug processing remains declarative and product-neutral internally: parser syntax maps into canonical `ImagePlug.Plan.Operation.*` intent, and executable transform work is derived later by `ImagePlug.Transform.execute_plan/4`.

URL option order is not execution order. The parser and planner own the fixed Imgproxy transform order.

For a feature-by-feature comparison with imgproxy's processing URL surface, see
[Imgproxy Support Matrix](imgproxy_support_matrix.md).

## URL Shape

The general shape is:

    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]

The signature segment is verified before option parsing, planning, source
identity resolution, cache lookup, or origin fetch. With no `:imgproxy`
signature configuration, ImagePlug accepts only `_` and `unsafe` as
disabled-signing placeholders. With signing configured, the signature must be a
raw/unpadded Base64URL HMAC-SHA256 digest of the raw path after the signature,
including the leading slash, or an exact configured trusted signature.
Trusted-only configuration accepts only exact trusted signatures; unlike
upstream imgproxy, it does not make every signature segment valid when no
key/salt pair is configured.
Before verification, ImagePlug applies imgproxy-compatible `fixPath`
normalization: `%3A` in processing options is treated as `:`, and normalized
plain URL schemes such as `http:/x` and `local:/x` are repaired to `http://x`
and `local:///x`.

`plain` source paths are path segments after the source marker. A plain source
may end in `@extension` to request an explicit output format from the source
path. The `@extension` form bypasses `Accept` negotiation like `format`, `f`,
and `ext`.

## Pipeline Groups

`-` separates Imgproxy pipeline groups. Non-empty groups execute in URL group order. Inside each group, URL option order still does not define transform order. Empty pipeline groups are ignored.

Imgproxy canonical semantic operation order inside each pipeline group is:

1. orientation (`auto_orient`, `rotate`, `flip`)
2. explicit crop
3. resize intent, including `mode: :auto`
4. result crop for fill/fill-down/auto target geometry
5. canvas extension

Orientation suborder is auto-orient, rotate, then flip.

This fixed order is an Imgproxy API contract. It is not a universal requirement for every future compatibility dialect; dialect-specific ordered quirks belong in parser or adapter code when they cannot translate cleanly into the Imgproxy declarative model.

## Option Ordering And Conflict Resolution

Aliases are normalized before conflict resolution. If multiple URL options map to the same canonical request field, the last occurrence in the URL wins.

Examples:

- `w:100/width:200` resolves width to `200`.
- `width:200/w:100` resolves width to `100`.
- `rt:fit/resizing_type:force` resolves resizing type to `force`.

Conflict resolution applies to canonical request fields, not raw option names. For example, `w` and `width` conflict when both map to width; `rt` and `resizing_type` conflict when both map to resizing type.

Pipeline separators scope transform fields to each pipeline group. Duplicate transform fields are scoped to their pipeline group. Global fields such as output format, quality, cachebuster, expiration, filename, and response disposition can appear across groups and still resolve by canonical field.

Generic quality and format-specific quality are separate canonical fields.

## Presets

Normal processing URLs support configured imgproxy presets:

    ImagePlug.init(
      parser: ImagePlug.Parser.Imgproxy,
      root_url: "https://origin.example",
      imgproxy: [
        presets: %{
          "default" => "rt:fill/el:1",
          "thumb" => "rs:fit:120:120",
          "sharp-thumb" => "pr:thumb/q:82",
          "responsive" => "w:900/-/w:450"
        }
      ]
    )

`preset` and `pr` accept one or more preset names in a single option segment:

    /_/preset:thumb/plain/images/cat.jpg
    /_/pr:thumb:sharp-thumb/plain/images/cat.jpg

Preset expansion happens inside `ImagePlug.Parser.Imgproxy` before plan construction, source identity resolution, cache lookup, or origin fetch. Preset names are not stored in `ImagePlug.Plan`, runtime state, output negotiation, transform state, or cache data. A request using `pr:thumb` and a request spelling out the same expanded options share the same cache key for the same resolved origin identity and vary inputs.

A configured preset named `default` is applied to every normal processing request before URL options. URL assignments in the same merged pipeline group can override fields from `default`.

Presets may reference other presets. Recursive re-entry is skipped, matching imgproxy behavior: if `a` expands to `pr:a/w:100`, the nested `pr:a` is ignored and `w:100` still applies.

Preset values may contain `-` pipeline separators. The first preset group is applied to the current URL pipeline group. Later preset groups are queued for following URL groups; URL options in those later groups can override queued preset fields. Remaining queued groups become trailing pipelines.

This slice does not support presets-only mode, info endpoint presets, `IMGPROXY_PRESETS`, `IMGPROXY_PRESETS_SEPARATOR`, `IMGPROXY_PRESETS_PATH`, preset file loading, or custom argument separators.

## Supported Options And Aliases

| Concept | Options | Accepted values |
| --- | --- | --- |
| Resize tuple | `resize`, `rs` | `:<resizing_type>:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Size tuple | `size`, `s` | `:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Resizing type | `resizing_type`, `rt` | `fit`, `fill`, `fill-down`, `force`, `auto` |
| Width | `width`, `w` | non-negative pixel integer; `0` means auto |
| Height | `height`, `h` | non-negative pixel integer; `0` means auto |
| Minimum width | `min-width`, `min_width`, `mw` | non-negative pixel integer |
| Minimum height | `min-height`, `min_height`, `mh` | non-negative pixel integer |
| Enlarge | `enlarge`, `el` | boolean: `1`, `t`, `true`, `0`, `f`, `false` |
| Zoom | `zoom`, `z` | positive number, or positive `x:y` numbers |
| DPR | `dpr` | positive number |
| Extend canvas | `extend`, `ex` | boolean, optionally followed by extend gravity and offsets |
| Extend aspect ratio | `extend_aspect_ratio`, `extend_ar`, `exar` | positive `<width>:<height>` ratio numbers |
| Crop | `crop`, `c` | `<width>:<height>`, optional gravity, optional offsets |
| Gravity | `gravity`, `g` | anchor, anchor with offsets `<anchor>:<x_offset>:<y_offset>`, focal point `fp:<x>:<y>`, or unsupported smart gravity `sm` |
| Auto rotate | `auto_rotate`, `ar` | omitted for true, or boolean |
| Rotate | `rotate`, `rot` | integer degrees |
| Flip | `flip`, `fl` | omitted for both axes, one boolean for horizontal, or horizontal and vertical booleans |
| Quality | `quality`, `q` | integer quality; `0` means configured default |
| Format quality | `format_quality`, `fq` | `<format>:<quality>` |
| Format | `format`, `f`, `ext` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; `jpg` normalizes to JPEG |
| Cachebuster | `cachebuster`, `cb` | string value |
| Expires | `expires`, `exp` | Unix timestamp integer |
| Filename | `filename`, `fn` | filename stem, optional encoded flag |
| Attachment disposition | `return_attachment`, `att` | boolean |
| Preset | `preset`, `pr` | one or more configured preset names |
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; `best` is rejected by planning |

Anchor gravity values are `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, and `sowe`.
Resize and size tuple extend-gravity tails accept anchor gravity alone or anchor gravity with `x_offset` and `y_offset`.

## Resize And Dimensions

Supported resizing types are `fit`, `fill`, `fill-down`, `force`, and `auto`.

Zero dimensions map to `auto`. For `force`, an auto side preserves the source dimension. For `fit` and proportional resize rules, an auto side is resolved from source aspect ratio. Min dimensions, zoom, DPR, and `enlarge` are applied when target dimensions are computed during transform execution.

`auto` is cache-keyed as semantic resize intent with `mode: :auto`. It stays unresolved in final cache key data; after a cache miss, current dimensions at that point in the Plan derive the selected fit or cover branch. Matching current and target orientation derives cover, differing orientation derives fit, and unknown target orientation derives fit.

`rt:force/w:0/h:200` preserves source width and forces height to `200`.
`rt:force/w:300/h:0` forces width to `300` and preserves source height.

Fit/fill with both sides zero produces no geometry transform unless min dimensions or another meaningful size constraint is present. Zoom and DPR do not force raster enlargement for zero-dimension auto sides when `enlarge` is false.

## Crop And Gravity

Crop accepts dimensions and optional crop gravity. If an explicit crop omits gravity, it inherits top-level `g`/`gravity`.

Top-level `g`/`gravity` applies to result crops produced by fill, fill-down, and auto resize planning. Crop-specific gravity overrides top-level gravity for that crop.

Gravity supports anchors and focal points. Focal point gravity uses `fp:x:y`, where `x` and `y` are normalized coordinates from `0.0` to `1.0`.

Crop focal-point gravity uses crop gravity fields; it does not require a
separate focus operation.

Offsets use imgproxy-style parsing:

- `abs(offset) >= 1` means pixels.
- `abs(offset) < 1` means relative scale.

Top-level gravity offsets apply to result crops. Crop-specific offsets apply to explicit crop.
Absolute top-level gravity offsets are resolved by crop execution using the effective DPR. The planner should preserve pixel offsets in the result `Crop`; execution applies the DPR scale.

Crop offset signs and unit interpretation match current imgproxy-compatible parsing and execution behavior.

`g:sm` is intentionally unsupported in this Imgproxy slice and is rejected as `{:unsupported_gravity, :sm}`. `c:<width>:<height>:sm` is rejected the same way.

## Orientation

Orientation options are `auto_rotate`/`ar`, `rotate`/`rot`, and `flip`/`fl`.

- `ar` with no argument enables auto-orient; `ar:false` disables it.
- `rot` accepts integer degrees and normalizes right-angle rotations.
- `fl` with no arguments flips both axes; `fl:true:false` flips horizontally; `fl:false:true` flips vertically; `fl:false:false` emits no flip operation.

## Canvas Extension

Canvas options are `extend`/`ex`, resize-tail extend arguments, and `extend_aspect_ratio`/`extend_ar`/`exar`.

- `extend:true` requests canvas extension for the requested resize box.
- `extend:false` disables canvas extension even when resize-tail values are present.
- `exar:<width>:<height>` extends canvas to the requested aspect ratio.
- Extend gravity uses anchor values only, with optional numeric offsets.

## Output Format And Quality

Omitting an explicit output format enables automatic output negotiation.
`format:auto` is not accepted.

Explicit output formats can be requested with `format`, `f`, `ext`, or plain-source `@extension`. Explicit formats and `@extension` bypass `Accept` negotiation and do not set `Vary: Accept`.

When both an option format and source `@extension` are present, source `@extension` overrides any explicit format option.

Supported explicit output extensions are `webp`, `avif`, `jpeg`, `jpg`, `png`, and `best`. `jpg` normalizes to JPEG. `best` parses but is rejected by planning in this Imgproxy slice.

`quality`/`q` set generic output quality. `format_quality`/`fq` set quality for one explicit format and should be documented separately from generic quality. `0` resets quality to the configured default.

## Cache And Expiration

`cachebuster`/`cb` changes cache key data without adding transform operations. `expires`/`exp` is a Unix timestamp request validity policy.

Final cache lookup is source-fetch-free: it is built from Plan operation key data, resolved origin identity/freshness data, output/config/vary key data, and the cache key's transform key data version. It does not fetch, decode, or read source metadata. Source-aware execution choices such as `mode: :auto` selecting fit or cover do not enter the normal final cache key.

Only successful encoded responses are cached. Rejected Imgproxy requests return before origin fetch and cache lookup.

## Response Filename And Disposition

`filename`/`fn` sets the delivery filename stem; `return_attachment`/`att` controls inline versus attachment `Content-Disposition`.

## Unsupported And Rejected Options

Unsupported imgproxy options are not silently ignored. Options outside this supported Imgproxy slice are rejected.

| Case | Behavior |
| --- | --- |
| Unknown option | HTTP 400 before origin fetch/cache lookup |
| Known imgproxy option outside this Imgproxy slice | HTTP 400 before origin fetch/cache lookup |
| Supported option with invalid value | HTTP 400 before origin fetch/cache lookup |
| Valid syntax with unsupported combined semantics | HTTP 400 before origin fetch/cache lookup |
| Unknown preset | HTTP 400 before origin fetch/cache lookup |
| Recursive preset reference | Recursive re-entry is skipped and remaining reachable options continue |
| Unsupported option inside a used preset | HTTP 400 before origin fetch/cache lookup |
| Duplicate canonical field | Last value wins |

Unsupported examples include `raw`, `max_bytes`, `max_src_resolution`, `max_src_file_size`, `crop_aspect_ratio`, `format:auto`, `g:sm`, and `c:<width>:<height>:sm`.

Crop combined with auto-orient is supported and planned in Imgproxy canonical order. Top-level gravity offsets are supported for result crops. `force` resize with one zero dimension is supported by preserving the source dimension for the auto side. Explicit crop gravity variants, including focal-point crop gravity, are supported. Explicit crop without its own gravity inherits top-level gravity.

SVG/vector-specific imgproxy parity is out of scope for this Imgproxy documentation pass.

## Examples

| Goal | Imgproxy URL |
| --- | --- |
| Fit within a width | `/_/w:300/plain/images/cat.jpg` |
| Fill a box from a focal point | `/_/rt:fill/w:300/h:200/g:fp:0.25:0.75/plain/images/cat.jpg` |
| Force one side and preserve the other | `/_/rt:force/w:0/h:200/plain/images/cat.jpg` |
| Explicit crop with focal gravity | `/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg` |
| Auto-orient then crop | `/_/ar/c:100:100/plain/images/cat.jpg` |
| Explicit output format | `/_/f:webp/plain/images/cat.jpg` |
| Source extension output format | `/_/plain/images/cat.jpg@png` |
