# Imgproxy Metadata & Color-Profile Controls Design

> Revised after a parallel disjoint-reviewer cycle (architecture, image/imgproxy
> fidelity, cache/safety, testing/demo). Key corrections: use the ICC-aware
> conversion path; strip metadata via Vix `mutate` (the `image` v0.67 helper has
> an XMP field-name bug); explicit wiring checklist; test discipline fixes;
> concrete demo plan. The `scp` pipeline position (before effects) was challenged
> and **confirmed correct** against imgproxy source — see "Color-profile
> normalization".

## Scope

This slice implements imgproxy's output metadata and color-profile controls
([#30](https://github.com/hlindset/image_plug/issues/30)):

- **`strip_metadata` (`sm`)** — strip EXIF/IPTC/XMP from the output. Encode-time
  metadata policy on `ImagePipe.Plan.Output`.
- **`keep_copyright` (`kcr`)** — when stripping, retain copyright/artist. Encode-
  time metadata policy on `ImagePipe.Plan.Output`.
- **`strip_color_profile` (`scp`)** — convert the embedded ICC profile to sRGB
  and drop it. A **transform pipeline operation**, modeled like
  `auto_rotate`/`AutoOrient`, because the conversion is a pixel mutation whose
  position relative to color effects is significant.

All three default to **on**. Following the `auto_rotate` precedent, **all four
defaults — `auto_rotate`, `strip_metadata`, `keep_copyright`,
`strip_color_profile` — are owned by the imgproxy parser config**
(`ImagePipe.Parser.Imgproxy.validate_options!`), with per-request URL options
overriding. The imgproxy compatibility layer is the single control surface.

### Why `scp` is a transform op but `sm`/`kcr` are not

The codebase models **every pixel mutation as a transform operation** with a
fixed, parser-owned order. `scp`'s ICC→sRGB conversion is a pixel mutation, so it
follows that rule and gets a fixed pipeline position. `sm`/`kcr` touch only
header fields, never pixels, so they stay as encode-time output policy.

### Out of scope (deferred, tracked separately)

- **`color_profile` / `cp` / `icc`** — convert to *and embed* a chosen profile
  ([#119](https://github.com/hlindset/image_plug/issues/119)). The new
  `NormalizeColorProfile` op is the `cp`-ready seam.
- **Full import/export color management** — imgproxy color-manages *every* image
  into a working space before processing and re-embeds the source profile when
  `scp` is off (see below). This slice does not; it converts only when `scp` is
  on. Tracked in [#124](https://github.com/hlindset/image_plug/issues/124)
  (distinct from #119, which is output-profile embedding).
- **`dpi`, `strip_metadata_dpi`** ([#120](https://github.com/hlindset/image_plug/issues/120)),
  **`preserve_hdr`** ([#121](https://github.com/hlindset/image_plug/issues/121)),
  **`enforce_thumbnail`** ([#122](https://github.com/hlindset/image_plug/issues/122)),
  **`page`/`pages`/`disable_animation`** ([#123](https://github.com/hlindset/image_plug/issues/123)).

## Current State

### ImagePipe keeps all metadata today

`ImagePipe.Output.Encoder.stream_output/3` (`lib/image_pipe/output/encoder.ex`)
calls `Image.stream!/2` with only `suffix` and `quality` — no strip flag — so
libvips preserves EXIF (including GPS), IPTC, XMP, and the ICC profile into every
response. This is the privacy gap behind [#30](https://github.com/hlindset/image_plug/issues/30)
(`priority:P1` / `type:security`).

### imgproxy behavior (verified against source)

Defaults (`local/imgproxy-master/processing/config.go`): `StripMetadata: true`,
`KeepCopyright: true`, `StripColorProfile: true`.

**Color management** (`processing/processing.go`, `colorspace_to_processing.go`,
`colorspace_to_result.go`):

- `mainPipeline` runs `colorspaceToProcessing` **early — before crop/scale/
  `applyFilters`**. It imports the embedded ICC profile and converts pixels to a
  standard working space (sRGB, or 16-bit RGB for HDR-capable formats). So
  **effects run in a standard (sRGB-ish) working space, not the raw embedded-
  profile space.**
- `finalizePipeline` runs `colorspaceToResult` then `stripMetadata`.
  `colorspaceToResult` decides: keep the profile (re-export/embed) when
  `scp` is off and the format supports profiles, or drop it when `scp` is on
  (pixels are already in the standard space, so it just removes the profile).

**Metadata strip** (`processing/strip_metadata.go`): `stripMetadata` is a no-op
unless `StripMetadata`. With `KeepCopyright`, imgproxy backs up the full IPTC
(PS3) and XMP blobs, runs `Strip(keepCopyright)` (libvips strip that retains
EXIF copyright fields), then restores the IPTC and XMP blobs.

### Precedents this slice reuses

- **`auto_rotate` / `AutoOrient`** — parser config default; plan builder emits a
  semantic `Plan.Operation.AutoOrient`; `PlanExecutor` lowers to
  `Transform.Operation.AutoOrient`; `Plan.KeyData` covers it; exported from the
  `ImagePipe.Transform` boundary. `scp` mirrors this exactly.
- **Output threading** — `Plan.Output` → `Output.Policy.from_output_plan/3`
  (`output/policy.ex:30`) → `Policy.resolve/2` → `Output.Resolved`
  (`output/resolved.ex`) → `Encoder.stream_output/3`. `sm`/`kcr` thread through;
  they are independent of Accept negotiation.

### `image` library primitives (v0.67) — verified

- `Image.to_colorspace/2` (`image.ex:8292`) is an **interpretation-only**
  conversion — **not** ICC-profile-aware. The ICC-aware path is
  `Image.to_colorspace/3` (`image.ex:8351`), which delegates to
  `Vix.Vips.Operation.icc_transform/3` using the embedded profile as input.
  **This slice uses the `/3` (icc_transform) path.**
- **Verified empirically (see below); two relevant `image` v0.67 behaviors:**
  - The **`:xmp` atom selector is broken**: `@metadata_fields` (`image.ex:6671`)
    maps `xmp: "xmp-dataa"` (typo), so `remove_metadata(img, :xmp)` /
    `[:xmp]` is a silent no-op. `:exif`/`:iptc` work; the literal `"xmp-data"`
    string works. (Filed upstream.)
  - **`remove_metadata/1` default (no fields) and `minimize_metadata/1,2`
    over-strip**: they enumerate `header_field_names/1` and remove *all* of them,
    **including `icc-profile-data`**. So `minimize_metadata` does **not** preserve
    the ICC profile.
- **Consequence:** to strip exactly EXIF/XMP/IPTC while preserving the ICC
  profile (required for `sm`/`scp` independence), this slice removes the explicit
  string fields `"exif-data"`/`"xmp-data"`/`"iptc-data"` via Vix `mutate` — never
  the `:xmp` atom, never the default/`minimize` path. The `kcr` path additionally
  preserves the profile by backing up and restoring `icc-profile-data`.

### Verified behavior (probe, `image` 0.67.0)

| call | result |
| --- | --- |
| `remove_metadata(img, :xmp)` | nothing removed (XMP retained) |
| `remove_metadata(img)` / `minimize_metadata(img)` | all metadata **and ICC profile** removed |
| `remove_metadata(img, ["exif-data","xmp-data","iptc-data"])` | those three removed, **ICC kept** |
| raw `MutableImage.remove/2` per field | precise per-field removal |

## Design

### Color-profile normalization: new transform operation (`scp`)

Operation pair mirroring `AutoOrient`:

- **`ImagePipe.Plan.Operation.NormalizeColorProfile`** — semantic intent, no
  fields in this slice (sRGB implicit). This struct is the `cp`-ready seam
  ([#119](https://github.com/hlindset/image_plug/issues/119) adds a target).
- **`ImagePipe.Transform.Operation.NormalizeColorProfile`** — executable.
  `execute/2`:
  - if the image carries an embedded ICC profile: convert to sRGB via the
    **ICC-aware** path (`Image.to_colorspace/3` → `icc_transform`, sRGB output,
    embedded profile as input), then drop the `icc-profile-data` header so the
    output embeds no profile; store back into `Transform.State`;
  - else: no-op.
  - failures → `{:error, {__MODULE__, error}}`.
- **`Plan.KeyData`** clause: `data(%NormalizeColorProfile{}) ->
  [op: :normalize_color_profile]`.
- **`PlanExecutor`** clause lowering the semantic op to the executable op
  (mirrors the `AutoOrient` clause).

**Fixed pipeline position: after geometry (resize/crop), immediately before the
effect chain.** Verified faithful to imgproxy for the default `scp:1`: imgproxy
imports color to a standard working space *before* `applyFilters`, so effects
run on sRGB pixels and the output carries no profile. Converting on already-
downscaled pixels also keeps cost bounded.

**Documented limitation (vs imgproxy):** imgproxy color-manages *every* image
into a working space before processing regardless of `scp`, and re-embeds the
source profile when `scp` is off. This slice converts **only when `scp` is on**.
Consequence: with `scp:0` **and** a tone effect on a wide-gamut source,
ImagePipe applies the effect in the source profile's space rather than a working
space — a minor fidelity gap for a non-default combination. Full import/export
color management is out of scope (tracked in
[#124](https://github.com/hlindset/image_plug/issues/124)).

**Decode planning:** the conversion is a point-wise op and is **sequential-safe
(one-pass)**; it does not force random access or change decode/open planning.

**Emission:** the imgproxy plan builder emits `NormalizeColorProfile` when the
resolved `scp` is true, nothing when false. `scp` is a plain boolean.

### Metadata policy: `ImagePipe.Plan.Output` (`sm`/`kcr`)

Add two boolean fields (`strip_color_profile` is the transform op, not here):

```elixir
defstruct mode: :automatic, quality: :default, format_qualities: %{},
          strip_metadata: true, keep_copyright: true
```

Struct defaults are safe fallbacks for direct constructors; the imgproxy parser
always sets them from its config, so the parser owns the effective default.

**Canonicalization.** `keep_copyright` only matters when `strip_metadata` is
true. The plan builder normalizes `keep_copyright` to `false` whenever
`strip_metadata` is `false`, keeping cache keys/ETags deterministic.

### Output encode path: `sm`/`kcr` via Vix `mutate`

Thread `strip_metadata` + `keep_copyright` through `Policy` and `Resolved`
(both gain the two fields; populated in `Policy.resolved/2` from `Plan.Output`).
`Encoder.stream_output/3` applies them to the materialized Vix image before
streaming, **never** using the blunt libvips `strip` write flag (it would also
remove the ICC profile) **and not relying on `Image.remove_metadata`** (XMP bug):

```
finalize(image, resolved):
  cond do
    not resolved.strip_metadata ->
      image                                              # keep all metadata
    resolved.keep_copyright ->
      icc = header_value(image, "icc-profile-data")      # may be absent (scp dropped it upstream)
      image
      |> minimize_metadata!(keep: [:copyright, :artist]) # strips exif(except copyright/artist)+xmp+iptc+ICC
      |> restore(icc)                                     # re-attach the profile (minimize over-strips it)
    true ->
      mutate(image, remove ["exif-data", "xmp-data", "iptc-data"])  # ICC preserved
  end
  |> stream!(suffix: suffix, quality: quality)   # no libvips strip flag
```

- The non-`kcr` strip uses `Vix.Vips.Image.mutate/2` + `MutableImage.remove/2`
  with explicit field names, preserving `icc-profile-data`.
- The `kcr` path reuses `minimize_metadata` for EXIF copyright/artist retention,
  but **must back up and restore `icc-profile-data`** because `minimize_metadata`
  removes it. When `scp` already dropped the profile upstream, the backup is
  empty and the restore is a no-op — consistent.
- **Required code comments** at the strip site: (a) `image` v0.67's
  `@metadata_fields` maps `xmp: "xmp-dataa"` (typo) so the `:xmp` atom selector
  is a no-op — hence explicit string field names; (b) `minimize_metadata`/default
  `remove_metadata` over-strip the ICC profile, hence explicit field removal and
  the `kcr` backup/restore.
- `scp` is **not** handled here — by encode time the `NormalizeColorProfile` op
  (if emitted) has already converted and dropped the profile.
- The EXIF Orientation tag is stripped safely: `AutoOrient` runs first and bakes
  orientation into pixels, so removing the tag afterward cannot mis-orient.
- Errors fold into the existing `{:error, {:encode, exception, stacktrace}}`
  rescue. No new error category.

**`keep_copyright` fidelity (deliberate divergence):** imgproxy preserves the
full XMP + IPTC blobs plus EXIF copyright. This slice **intentionally** preserves
**EXIF copyright/artist only** and still strips XMP/IPTC — a privacy-conservative
choice (XMP/IPTC can carry GPS/personal data; strip more when uncertain). This is
a decided behavior, not a gap: full XMP/IPTC retention is not planned. Documented
in the support matrix.

### Cache key: `ImagePipe.Cache.Key`

- `sm`/`kcr` (post-normalization) → add to both `output_plan_data/2` clauses
  (`cache/key.ex:101`, `:114`). They change encoded bytes, so they belong in the
  key and (via `plan_material` in `request/http_cache.ex`) the ETag.
- `scp` → keyed via the `NormalizeColorProfile` op's `KeyData`; nothing extra in
  `output_plan_data`.

Greenfield: reshape key data in place — no key-data version bump.

### Wiring checklist (mirrors `AutoOrient`)

1. `Plan.Operation.NormalizeColorProfile` + `Transform.Operation.NormalizeColorProfile`.
2. Export `Operation.NormalizeColorProfile` from the `ImagePipe.Transform`
   boundary (`lib/image_pipe/transform.ex`).
3. `Plan.KeyData.data/1` clause + alias.
4. `PlanExecutor.executable_operations/3` clause.
5. imgproxy plan builder emits the op (parser-owned `scp` default).
6. `Plan.Output` gains `strip_metadata`/`keep_copyright`; `Policy` + `Resolved`
   thread them; `Encoder` applies them.
7. `output_plan_data/2` includes `sm`/`kcr` (post-normalization).

### Boundaries

`parser → plan`, `output → plan`, `cache → plan, output`, transform-execution
contract — all existing edges. Request/source/response code must not name the
concrete `Transform.Operation.NormalizeColorProfile`; dispatch via
`ImagePipe.Transform`. Covered by the existing architecture boundary test.

## Testing

Boundary-focused; decode the response body for pixel/metadata-visible changes.
No hand-built `Plan.Output`/transform-state/op structs (per repo test
guidelines) — exercise the parser→plan→execute→encode path end to end, following
the `auto_rotate` wire-conformance pattern.

- **Parser** (`test/parser/imgproxy*`): boolean + alias parsing for `sm`/`kcr`/
  `scp`; config defaults; URL-overrides-config; order-insensitivity; repeated
  last-value-wins.
- **Parse→plan boundary**: `sm:0/kcr:1` yields a `Plan.Output` with
  `keep_copyright` normalized to `false`; `scp:1` emits exactly one
  `NormalizeColorProfile` at the correct position, `scp:0` emits none. (Asserted
  via parse+plan of a URL, not by constructing structs by hand.)
- **Wire-level Plug** (real `ImagePipe.call/2`, read the response bytes):
  - default → EXIF/GPS **and XMP** absent; default `scp` → output sRGB, no
    embedded profile;
  - `sm:0` → EXIF retained;
  - `kcr:1` → EXIF copyright retained, other EXIF + XMP/IPTC stripped;
  - `scp:1` on a wide-gamut fixture → output sRGB, no profile; `scp:0` → profile
    retained, pixels unconverted;
  - **ordering** (`scp:1` + tone effect on wide-gamut): assert the output is
    sRGB with no profile and differs from the `scp:0` output by a bounded
    pixel-distance **tolerance** (mean channel delta over a threshold), not exact
    bytes — libvips resampling/rounding makes exact pixels brittle.
- **Cache**: equivalent requests reuse; `sm`/`kcr`/`scp` variations produce
  **distinct** keys/ETags (assert `Cache.Key` outputs differ), no cross-serving.

### Response-metadata assertion mechanism (validate in TDD before writing tests)

The plan assumes tests can read EXIF/XMP/ICC from response **bytes**. Confirm the
concrete API first (e.g. `Image.open` the bytes then read header fields / a
metadata accessor for `exif-data`/`xmp-data`/`icc-profile-data`). If the `image`
public API can't read these post-encode, decide between a small header probe and
escalating — do this proof-of-concept before committing to the assertions above.

### Fixtures

No suitable fixtures exist (`test/support` images are generated on the fly; cf.
`ExifOrientationOriginImage` in `imgproxy_wire_conformance_test.exs`). Mirror that
pattern with origin-image generators that embed metadata/profile:
- an EXIF+GPS+copyright JPEG generator, and
- a wide-gamut (Display-P3 / Adobe RGB) source with an embedded ICC profile.
Validate that generation can actually embed EXIF/ICC via the `image`/Vix API as
part of TDD.

## Demo (`demo/` Svelte app)

Concrete changes:
- **`DemoState`** (`processing-path.ts`): add `stripMetadata: boolean`,
  `keepCopyright: boolean`, `stripColorProfile: boolean` (defaults `true`).
- **URL state** (`demo-url-state.ts`): parse/emit `sm:`, `kcr:`, `scp:` with the
  boolean alias logic (`1`/`t`/`true` → true). On emit, **skip `kcr:` when
  `stripMetadata` is false** so the URL is always canonical (matches the planner
  normalization); normalize on parse too.
- **UI** (`App.svelte`): a "Metadata & Color" section with three checkboxes;
  the `keep_copyright` checkbox is **disabled when `strip_metadata` is off**.

## Documentation

- `docs/imgproxy_support_matrix.md`: mark `sm`, `kcr`, `scp` ✅ Supported and the
  matching `IMGPROXY_*` rows; note default-on behavior and the documented
  divergences (no full import/export color management; `keep_copyright` keeps
  EXIF copyright only).
- `docs/transform_operations.md`: add `NormalizeColorProfile` and its fixed
  position.
- `docs/imgproxy_path_api.md`: update if it enumerates the ordered op chain.

## Open Questions (pin via TDD, not blocking design)

1. **Profile removal in the *encoded output***: the probe confirms removing the
   `icc-profile-data` header drops it from the in-memory image; still confirm the
   *encoded bytes* (after `stream!`) carry no embedded profile on a wide-gamut
   fixture for each output format.

Resolved during design (probe, `image` 0.67.0):

- **Profile presence / removal mechanism** — `header_field_names/1` reports
  `icc-profile-data`; `MutableImage.remove/2` drops it precisely. The op no-ops
  when the field is absent.
- **Response-metadata read API** — tests `Image.open` the response bytes and
  assert on `Vix.Vips.Image.header_field_names/1` (presence/absence of
  `exif-data`/`xmp-data`/`iptc-data`/`icc-profile-data`).
- **`keep_copyright` scope** — decided: EXIF copyright/artist only, XMP/IPTC
  stripped (privacy-conservative); not a gap.
