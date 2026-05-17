# Imgproxy path API

## Mental model

An imgproxy URL describes desired output, not a step-by-step image pipeline.
ImagePlug normalizes aliases and conflicts, converts supported options into
`ImagePlug.Plan` operations, then runs those operations in ImagePlug's
imgproxy-compatible order.

The imgproxy URL API accepts imgproxy-compatible option names where ImagePlug
supports the same semantics. Parser syntax maps into canonical
`ImagePlug.Plan.Operation.*` intent. ImagePlug derives executable transform
work later through `ImagePlug.Transform.execute_plan/3`.

For a feature-by-feature comparison with imgproxy's processing URL surface, see
[imgproxy Support Matrix](imgproxy_support_matrix.md).

## Path shape

The general shape is:

    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]

ImagePlug verifies the signature segment before option parsing, planning,
source identity resolution, cache lookup, or origin fetch. Without `:imgproxy`
signature configuration, ImagePlug accepts only `_` and `unsafe` as unsigned
development placeholders. With signing configured, the signature must be a
raw/unpadded Base64URL HMAC-SHA256 digest of the raw path after the signature,
including the leading slash, or an exact configured trusted signature.
Trusted-only configuration accepts only exact trusted signatures. Unlike
upstream imgproxy, it doesn't make every signature segment valid when no
key/salt pair exists.
Before verification, ImagePlug applies imgproxy-compatible `fixPath`
normalization: it treats `%3A` in processing options as `:`, and repairs
normalized plain URL schemes such as `http:/x` and `local:/x` to `http://x`
and `local:///x`.

`plain` source paths are path segments after the source marker. A plain source
may end in `@extension` to request an explicit output format from the source
path. The `@extension` form bypasses `Accept` negotiation like `format`, `f`,
and `ext`.

## Pipeline groups

`-` separates imgproxy pipeline groups. Non-empty groups execute in URL group
order. ImagePlug ignores empty pipeline groups.

imgproxy canonical semantic operation order inside each pipeline group is:

1. orientation, in `auto_orient`, `rotate`, then `flip` order
2. explicit crop
3. resize intent, including `mode: :auto`
4. result crop for `fill`, `fill-down`, and `auto` target geometry
5. canvas extension
6. padding
7. background flattening

## Option ordering and conflict resolution

ImagePlug normalizes aliases before conflict resolution. If more than one URL
option maps to the same canonical request field, the last occurrence in the URL
wins.

Examples:

- `w:100/width:200` resolves width to `200`.
- `width:200/w:100` resolves width to `100`.
- `rt:fit/resizing_type:force` resolves resizing type to `force`.

Conflict resolution applies to canonical request fields, not raw option names.
For example, `w` and `width` conflict when both map to width. `rt` and
`resizing_type` conflict when both map to resizing type.

Pipeline separators scope transform fields to each pipeline group. Duplicate
transform fields stay in their pipeline group. Global fields such as output
format, quality, cachebuster, expiry, filename, and response disposition can
appear across groups and still resolve by canonical field.

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

`ImagePlug.Parser.Imgproxy` expands presets before plan construction, source
identity resolution, cache lookup, or origin fetch. Preset names aren't stored
in `ImagePlug.Plan`, runtime state, output negotiation, transform state, or
cache data. A request using `pr:thumb` and a request spelling out the same
expanded options share the same cache key for the same resolved origin identity
and vary inputs.

ImagePlug applies a configured preset named `default` to every normal
processing request before URL options. URL assignments in the same merged
pipeline group can override fields from `default`.

Presets may reference other presets. ImagePlug skips recursive re-entry,
matching imgproxy behavior: if `a` expands to `pr:a/w:100`, ImagePlug ignores
the nested `pr:a` and still applies `w:100`.

Preset values may contain `-` pipeline separators. ImagePlug applies the first
preset group to the current URL pipeline group. It queues later preset groups
for following URL groups, where URL options can override queued preset fields.
Remaining queued groups become trailing pipelines.

This slice doesn't support presets-only mode, info endpoint presets,
`IMGPROXY_PRESETS`, `IMGPROXY_PRESETS_SEPARATOR`, `IMGPROXY_PRESETS_PATH`,
preset file loading, or custom argument separators.

## Supported options and aliases

| Concept | Options | Accepted values |
| --- | --- | --- |
| Resize tuple | `resize`, `rs` | `:<resizing_type>:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Size tuple | `size`, `s` | `:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Resizing type | `resizing_type`, `rt` | `fit`, `fill`, `fill-down`, `force`, `auto` |
| Width | `width`, `w` | non-negative pixel integer; `0` means `auto` |
| Height | `height`, `h` | non-negative pixel integer; `0` means `auto` |
| Min width | `min-width`, `min_width`, `mw` | non-negative pixel integer |
| Min height | `min-height`, `min_height`, `mh` | non-negative pixel integer |
| Enlarge | `enlarge`, `el` | boolean: `1`, `t`, `true`, `0`, `f`, `false` |
| Zoom | `zoom`, `z` | positive number, or positive `x:y` numbers |
| Device pixel ratio (DPR) | `dpr` | positive number |
| Extend canvas | `extend`, `ex` | boolean, optionally followed by extend gravity and offsets |
| Extend aspect ratio | `extend_aspect_ratio`, `extend_ar`, `exar` | positive `<width>:<height>` ratio numbers |
| Padding | `padding`, `pd` | optional top/right/bottom/left non-negative pixel integers |
| Background | `background`, `bg` | `R:G:B`, 3 digit hex, 6 digit hex, or empty to clear |
| Crop | `crop`, `c` | `<width>:<height>`, optional gravity, optional offsets |
| Gravity | `gravity`, `g` | anchor, anchor with offsets `<anchor>:<x_offset>:<y_offset>`, focal point `fp:<x>:<y>`, or unsupported smart gravity `sm` |
| Auto rotate | `auto_rotate`, `ar` | omitted for true, or boolean |
| Rotate | `rotate`, `rot` | integer degrees |
| Flip | `flip`, `fl` | omitted for both axes, one boolean for horizontal, or horizontal and vertical booleans |
| Quality | `quality`, `q` | integer quality; `0` means configured default |
| Format quality | `format_quality`, `fq` | `<format>:<quality>` |
| Format | `format`, `f`, `ext` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; `jpg` normalizes to JPEG |
| cachebuster | `cachebuster`, `cb` | string value |
| Expires | `expires`, `exp` | Unix timestamp integer |
| Filename | `filename`, `fn` | filename stem, optional encoded flag |
| Attachment disposition | `return_attachment`, `att` | boolean |
| Preset | `preset`, `pr` | one or more configured preset names |
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; planning rejects `best` |

## Resize and dimensions

Supported resizing types are `fit`, `fill`, `fill-down`, `force`, and `auto`.

Zero dimensions map to `auto`. For `force`, an `auto` side preserves the
source dimension. For `fit` and proportional resize rules, ImagePlug resolves
an `auto` side from source aspect ratio. During transform execution, ImagePlug
applies min dimensions, zoom, DPR, and `enlarge` when it computes target
dimensions.

`auto` is cache-keyed as semantic resize intent with `mode: :auto`. ImagePlug
keeps it unresolved in final cache key data. After a cache miss, current
dimensions at that point in the Plan derive the selected `fit` or `cover`
branch. Matching current and target orientation derives `cover`, differing
orientation derives `fit`, and unknown target orientation derives `fit`.

`rt:force/w:0/h:200` preserves source width and forces height to `200`.
`rt:force/w:300/h:0` forces width to `300` and preserves source height.

`fit`/`fill` with both sides zero produces no geometry transform unless min
dimensions or another meaningful size constraint is present. Zoom and DPR don't
force raster enlargement for zero-dimension `auto` sides when `enlarge` is
false.

## Crop and gravity

Crop accepts dimensions, optional crop gravity, and optional offsets. If an
explicit crop omits gravity, it inherits top-level `g`/`gravity`.

### Gravity values

Gravity supports anchors and focal points. Focal point gravity uses `fp:x:y`,
where `x` and `y` range from `0.0` to `1.0`.

Anchor gravity values are `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`,
`soea`, and `sowe`.

This imgproxy slice intentionally rejects `g:sm` as `{:unsupported_gravity,
:sm}`. It rejects `c:<width>:<height>:sm` the same way.

### Gravity scope

| Source | Applies to |
| --- | --- |
| Top-level `g`/`gravity` | Result crops produced by `fill`, `fill-down`, and `auto` resize planning |
| Explicit crop without gravity | Inherits top-level `g`/`gravity` |
| Explicit crop with gravity | Uses its own gravity instead of top-level `g`/`gravity` |

Crop focal-point gravity uses crop gravity fields. It doesn't require a
separate focus operation.

### Offsets

Offsets use imgproxy-style parsing:

- `abs(offset) >= 1` selects pixel offsets.
- `abs(offset) < 1` means relative scale.

Top-level gravity offsets apply to result crops. Crop-specific offsets apply to
explicit crops.

Crop execution resolves absolute top-level gravity offsets using the effective
DPR. The planner preserves pixel offsets in the result `Crop`. Execution applies
the DPR scale.

Crop offset signs and unit interpretation match current imgproxy-compatible
parsing and execution behavior.

## Orientation

Orientation options are `auto_rotate`/`ar`, `rotate`/`rot`, and `flip`/`fl`.

- `ar` with no argument enables auto-orient; `ar:false` disables it.
- `rot` accepts integer degrees and normalizes right-angle rotations.
- `fl` with no arguments flips both axes; `fl:true:false` flips horizontally; `fl:false:true` flips vertically; `fl:false:false` emits no flip operation.

## Canvas extension

Canvas options are `extend`/`ex`, resize-tail extend arguments, and
`extend_aspect_ratio`/`extend_ar`/`exar`.

- `extend:true` requests canvas extension for the requested resize box.
- `extend:false` disables canvas extension even when resize-tail values are
  present.
- `exar:<width>:<height>` extends canvas to the requested aspect ratio.
- Extend gravity uses anchor values only, with optional numeric offsets.

The optional extend gravity argument on `resize` and `size` accepts either
anchor gravity alone, or anchor gravity plus `x_offset` and `y_offset`.

## Composition

### Padding

`padding:%top:%right:%bottom:%left` and `pd:%top:%right:%bottom:%left` add
transparent edge padding after resize and canvas extension. Missing values
follow imgproxy shorthand semantics:

- one value applies to all sides;
- two values apply vertical then horizontal sides;
- three values apply top, horizontal, then bottom;
- four values apply top, right, bottom, and left.

Sparse repeated padding follows imgproxy's accumulated field behavior. For
example, `pd:10:20:30:40/padding::5` keeps top at `10` and bottom at `30`,
then sets right and left to `5`. `padding:` and all-zero padding are valid
no-ops.

Padding uses the effective DPR scale at execution. When a no-enlarge resize
clamps image scaling, padding follows imgproxy's compensated effective DPR
rather than the requested `dpr`. For imgproxy `extend` and
`extend_aspect_ratio` composition, padding uses imgproxy's canvas-preserving
effective DPR branch, which skips the no-enlarge DPR compensation before the
final no-enlarge clamp.

### Background

`background:%R:%G:%B`, `bg:%R:%G:%B`, `background:%hex`, and `bg:%hex`
flatten the current image over an opaque sRGB color after padding. Decimal
channels are `0..255`. Hex accepts 3 digit RGB and 6 digit RRGGBB forms.
`background:` clears an earlier background value in the same resolved request.

ImagePlug applies canvas extension before padding, and applies `background`
after both.

## Output format and quality

Omitting an explicit output format enables automatic output negotiation.

Requests can set explicit output formats with `format`, `f`, `ext`, or
plain-source `@extension`. Explicit formats and `@extension` bypass `Accept`
negotiation and don't set `Vary: Accept`.

When both an option format and source `@extension` are present, source
`@extension` overrides any explicit format option.

Supported explicit output extensions are `webp`, `avif`, `jpeg`, `jpg`, `png`,
and `best`. `jpg` normalizes to JPEG. Planning rejects `best` in this imgproxy
slice.

`quality`/`q` set generic output quality. `format_quality`/`fq` set quality for
one explicit format and should stay separate from generic quality. `0` resets
quality to the configured default.

## Cache and expiry

`cachebuster`/`cb` changes cache key data without adding transform operations.
`expires`/`exp` is a Unix timestamp request validity policy.

Final cache lookup doesn't fetch the source. The key uses Plan operation key
data, resolved origin identity/freshness data, output/config/vary key data, and
the cache key's transform key data version. It doesn't fetch, decode, or read
source metadata. Source-aware execution choices such as `mode: :auto` selecting
`fit` or `cover` don't enter the normal final cache key.

ImagePlug caches only successful encoded responses. Rejected imgproxy requests
return before origin fetch and cache lookup.

## Response filename and disposition

`filename`/`fn` sets the delivery filename stem. `return_attachment`/`att`
controls inline versus attachment `Content-Disposition`.

## Unsupported and rejected options

ImagePlug rejects unsupported imgproxy options. It doesn't ignore options
outside this supported imgproxy slice.

| Case | Behavior |
| --- | --- |
| Unknown option | HTTP 400 before origin fetch/cache lookup |
| Known imgproxy option outside this imgproxy slice | HTTP 400 before origin fetch/cache lookup |
| Supported option with invalid value | HTTP 400 before origin fetch/cache lookup |
| Valid syntax with unsupported combined semantics | HTTP 400 before origin fetch/cache lookup |
| Unknown preset | HTTP 400 before origin fetch/cache lookup |
| Recursive preset reference | ImagePlug skips recursive re-entry and keeps remaining reachable options |
| Unsupported option inside a used preset | HTTP 400 before origin fetch/cache lookup |
| Duplicate canonical field | Last value wins |

Unsupported examples include `raw`, `max_bytes`, `max_src_resolution`,
`max_src_file_size`, `crop_aspect_ratio`, `g:sm`, and
`c:<width>:<height>:sm`.

ImagePlug supports crop combined with auto-orient and plans it in imgproxy
canonical order. It supports top-level gravity offsets for result crops.
`force` resize with one zero dimension preserves the source dimension for the
`auto` side. Explicit crop gravity variants, including focal-point crop gravity,
also work. Explicit crop without its own gravity inherits top-level gravity.

SVG/vector-specific imgproxy parity remains out of scope for this imgproxy
documentation pass.

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
