# Imgproxy path API

## Mental model

An imgproxy URL describes desired output, not a step-by-step image pipeline.
ImagePlug normalizes aliases and conflicts, converts supported options into
`ImagePlug.Plan` operations, then runs those operations in a fixed order.

For a feature-by-feature comparison with imgproxy's processing URL surface, see
[Imgproxy Support Matrix](imgproxy_support_matrix.md).

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

`plain` source paths are the path segments after `/plain/`. A plain source may
end in `@extension` to request an explicit output format from the source path.
The `@extension` form bypasses `Accept` negotiation like `format`, `f`, and
`ext`.

## Pipeline groups

`-` separates imgproxy pipeline groups. Non-empty groups execute in path group
order. ImagePlug ignores empty pipeline groups.

Within each pipeline group, ImagePlug uses this fixed operation order:

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
| Width | `width`, `w` | non-negative pixel integer. `0` means `auto` |
| Height | `height`, `h` | non-negative pixel integer. `0` means `auto` |
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
| Gravity | `gravity`, `g` | anchor, anchor with offsets `<anchor>:<x_offset>:<y_offset>`, or focal point `fp:<x>:<y>` |
| Auto rotate | `auto_rotate`, `ar` | omitted for true, or boolean |
| Rotate | `rotate`, `rot` | integer degrees |
| Flip | `flip`, `fl` | omitted for both axes, one boolean for horizontal, or horizontal and vertical booleans |
| Quality | `quality`, `q` | integer quality. `0` means configured default |
| Format quality | `format_quality`, `fq` | `<format>:<quality>` |
| Format | `format`, `f`, `ext` | `webp`, `avif`, `jpeg`/`jpg`, `png` |
| cachebuster | `cachebuster`, `cb` | string value |
| Expires | `expires`, `exp` | Unix timestamp integer |
| Filename | `filename`, `fn` | filename stem, optional encoded flag |
| Attachment disposition | `return_attachment`, `att` | boolean |
| Preset | `preset`, `pr` | one or more configured preset names |
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`/`jpg`, `png` |

## Resize and dimensions

Supported resizing types are `fit`, `fill`, `fill-down`, `force`, and `auto`.

`0` width or height values map to `auto`. For `force`, an `auto` side preserves
the source dimension. For `fit` and proportional resize rules, ImagePlug
resolves an `auto` side from source aspect ratio. Min dimensions, zoom, DPR,
and `enlarge` apply when ImagePlug computes target dimensions.

The `dpr` option multiplies requested output dimensions. When `enlarge` is
false, ImagePlug may use a smaller multiplier than requested so raster output
doesn't grow beyond the source image. Gravity pixel offsets and padding use
that same resize multiplier, so surrounding geometry stays aligned with the
resized image.

ImagePlug keeps `auto` as `mode: :auto` in final cache key data. After a cache
miss, it compares the current image dimensions with the requested target box.
Matching current and target orientation selects `cover`. Differing or unknown
orientation selects `fit`.

`rt:force/w:0/h:200` preserves source width and forces height to `200`.
`rt:force/w:300/h:0` forces width to `300` and preserves source height.

`fit`/`fill` with both width and height set to `0` produces no geometry
transform unless min dimensions or another meaningful size constraint is
present. Zoom and DPR don't force raster enlargement for `0`-derived `auto`
sides when `enlarge` is false.

## Crop and gravity

Crop accepts dimensions, optional crop gravity, and optional offsets. If an
explicit crop omits gravity, it inherits top-level `g`/`gravity`.

### Gravity values

Gravity supports anchors and focal points. Focal point gravity uses `fp:x:y`,
where `x` and `y` range from `0.0` to `1.0`.

Anchor gravity values are `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`,
`soea`, and `sowe`.

### Gravity scope

| Source | Applies to |
| --- | --- |
| Top-level `g`/`gravity` | Result crops produced by `fill`, `fill-down`, and `auto` resize planning |
| Explicit crop without gravity | Inherits top-level `g`/`gravity` |
| Explicit crop with gravity | Uses its own gravity instead of top-level `g`/`gravity` |

### Gravity offsets

Gravity offsets are optional `x_offset` and `y_offset` values attached to the
gravity option that provided them:

| Offset source | Applies to |
| --- | --- |
| Top-level `g`/`gravity` | Result crops produced by resize planning |
| Explicit crop gravity | That explicit crop |

ImagePlug parses offset units like imgproxy:

| Offset value | Unit |
| --- | --- |
| `abs(value) >= 1` | pixels |
| `abs(value) < 1` | relative scale |

Execution scales pixel offsets by the resize multiplier described in
[Resize and dimensions](#resize-and-dimensions).

## Orientation

Orientation options are `auto_rotate`/`ar`, `rotate`/`rot`, and `flip`/`fl`.

- `ar` with no argument applies embedded orientation metadata, such as EXIF
  orientation. `ar:false` disables it.
- `rot` accepts integer degrees in multiples of 90 and stores them as `0`,
  `90`, `180`, or `270`.
- `fl` with no arguments flips both axes.
- `fl:true:false` flips horizontally.
- `fl:false:true` flips vertically.
- `fl:false:false` emits no flip operation.

## Canvas extension

Canvas options are `extend`/`ex`, the extend arguments inside `resize`/`size`,
and `extend_aspect_ratio`/`extend_ar`/`exar`.

- `extend:true` requests canvas extension for the requested resize box.
- `extend:false` disables canvas extension even when `resize`/`size` extend
  arguments are present.
- `exar:<width>:<height>` extends canvas to the requested aspect ratio.
- Extend gravity uses anchor values only, with optional numeric offsets.

The `resize`/`size` extend arguments accept anchor gravity alone, or anchor
gravity plus `x_offset` and `y_offset`.

## Composition

### Padding

`padding:%top:%right:%bottom:%left` and `pd:%top:%right:%bottom:%left` add
transparent edge padding after resize and canvas extension. Missing values use
the same order as CSS padding shorthand:

- one value applies to all sides
- two values apply vertical, then horizontal sides
- three values apply top, horizontal, then bottom
- four values apply top, right, bottom, and left.

When a request repeats padding, later values update only the sides they name.
For example, `pd:10:20:30:40/padding::5` keeps top at `10` and bottom at `30`,
then sets right and left to `5`. `padding:` and all-zero padding are valid
no-ops.

Padding uses the same resize multiplier as gravity offsets. For requests that
combine no-enlarge resize with canvas extension, ImagePlug follows imgproxy's
canvas-preserving DPR behavior instead of using only the requested `dpr`.

### Background

`background:%R:%G:%B`, `bg:%R:%G:%B`, `background:%hex`, and `bg:%hex`
flatten the current image over an sRGB color after padding. Decimal channels
are `0..255`. Hex accepts 3 digit RGB and 6 digit RRGGBB forms.

`background_alpha:%alpha` and `bga:%alpha` set background alpha. Alpha accepts
values from `0` to `1`, including decimals such as `0.5`. The alpha value
applies to the current background color or the next background color in the
same request. Without an explicit background color, `background_alpha` uses
imgproxy's default black background.

`background:` clears an earlier background value and alpha in the same resolved
request.

Composition order is canvas extension, padding, then `background`.

## Output format and quality

When a request omits an explicit output format, ImagePlug negotiates the output
from `Accept` and sets `Vary: Accept`. To force a format, use `format`, `f`,
`ext`, or put `@extension` at the end of the plain-source path. Forced formats
bypass `Accept` negotiation and don't set `Vary: Accept`.

ImagePlug supports `webp`, `avif`, `jpeg`/`jpg`, and `png` as explicit output
extensions. If a request includes both an option format and source `@extension`,
source `@extension` wins.

Quality has two separate controls: `quality`/`q` sets generic output quality,
while `format_quality`/`fq` sets quality for one explicit format. In either
case, `0` resets quality to the configured default.

## Cache and expiry

`cachebuster`/`cb` changes cache key data without adding transform operations.
`expires`/`exp` is a Unix timestamp request validity policy.

Final cache lookup doesn't fetch, decode, or read source metadata. The key uses
canonical plan/output fields, resolved origin identity and freshness data,
configured vary inputs, output config, and the transform key data version.
Source-aware execution choices, such as `mode: :auto` selecting `fit` or
`cover`, don't enter the normal final cache key.

ImagePlug caches only successful encoded responses. Rejected imgproxy requests
return before origin fetch and cache lookup.

## Response filename and disposition

`filename`/`fn` sets the delivery filename stem. `return_attachment`/`att`
controls inline versus attachment `Content-Disposition`.

## Unsupported and rejected options

Unsupported and invalid imgproxy requests fail before origin fetch or cache
lookup.

These cases return HTTP 400:

- unknown option
- unsupported imgproxy option
- supported option with invalid value
- unsupported option combination
- unknown preset
- unsupported option inside a used preset

## Examples

| Goal | Imgproxy path |
| --- | --- |
| Fit within a width | `/_/w:300/plain/images/cat.jpg` |
| Fill a box from a focal point | `/_/rt:fill/w:300/h:200/g:fp:0.25:0.75/plain/images/cat.jpg` |
| Force one side and preserve the other | `/_/rt:force/w:0/h:200/plain/images/cat.jpg` |
| Explicit crop with focal gravity | `/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg` |
| Auto-orient then crop | `/_/ar/c:100:100/plain/images/cat.jpg` |
| Explicit output format | `/_/f:webp/plain/images/cat.jpg` |
| Source extension output format | `/_/plain/images/cat.jpg@png` |
