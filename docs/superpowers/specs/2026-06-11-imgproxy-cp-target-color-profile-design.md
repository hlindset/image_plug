# Design — `cp`/`icc` built-in target color-profile conversion + embed (#119)

**Status:** approved design, pre-implementation
**Issue:** [#119](https://github.com/hlindset/image_pipe/issues/119) — deferred from #30, builds on #124 (input color management)
**Follow-ups filed:** [#214](https://github.com/hlindset/image_pipe/issues/214) (CMYK target)

## Summary

Add imgproxy `color_profile` / `cp` / `icc` support: convert the processed image into a
caller-chosen **target** ICC profile and **embed** that profile in the output. This fills the
`{:convert, target}` arm of `ImagePipe.Plan.Output.color_profile`, which #124 deliberately left
open. The conversion + embed runs at the existing encoder-finalize seam alongside `:preserve_source`
and `:strip`.

v1 ships a **fixed allowlist of built-in RGB targets only**. No filesystem resolution, no
`IMGPROXY_COLOR_PROFILES_DIR`, no path input — so the security/path-traversal subsystem the issue
worried about does not exist in this slice, and the `color` dependency is not used (atom-membership
validation needs no ICC parsing).

## Compatibility reality (important)

`cp`/`icc` is an **imgproxy Pro** feature. It is **absent from OSS imgproxy** (verified against the
local `v4.1.1` checkout: no `cp`, `icc`, or `color_profiles_dir` anywhere). Consequences:

- There is **no OSS source or binary to pixel-conform against**. Acceptance = imgproxy-Pro
  **documentation** parity + our own pixel-correctness fixtures, not a wire-diff against a local
  imgproxy. The compatibility reviewer checks against the Pro docs, not source.
- From the Pro docs, the **only built-in profile names are `srgb` and `cmyk`**; all wide-gamut
  targets are reached **only** as custom filenames in `IMGPROXY_COLOR_PROFILES_DIR`. We have chosen
  not to implement dir-resolution in v1, so our wide-gamut identifiers are **ImagePipe-specific
  extensions** (see Divergences).
- The Pro docs state profiles embedded via `cp` are **"not stripped by the strip_color_profile
  option."** This pins the `cp`-overrides-`scp` semantics below — it is doc-grounded, not just an
  artifact of our single-field model.

## Scope

**In:**

- imgproxy parser support for `cp:<name>` / `icc:<name>` (aliases), mapping name → target atom.
- Three built-in RGB targets: `srgb`, `display_p3`, `adobe_rgb`.
- Conversion + embed at encoder finalize via the `{:convert, target}` arm.
- Shipped redistributable (CC0-substitute) `.icc` assets for each target.
- Cache-key / ETag identity (free — target is a plain atom already in the canonical Output seed).
- Docs (support matrix) + fiddle demo control.

**Out (with follow-ups):**

- **CMYK** target → [#214](https://github.com/hlindset/image_pipe/issues/214). Different in kind:
  4-band, JPEG-only encodability, license-encumbered profile sourcing.
- **Custom-dir / path resolution** (`IMGPROXY_COLOR_PROFILES_DIR`) → not filed; revisit if/when a
  caller needs arbitrary profiles. This is the imgproxy-faithful way to reach wide-gamut and would
  reintroduce the input-validation + config + path-traversal surface.
- The `color` dependency for profile validation — unnecessary under built-ins-only.

## Identifier surface & semantics

### Accepted URL identifiers (imgproxy parser)

| URL string(s)              | Target atom    | imgproxy-faithful? |
|----------------------------|----------------|--------------------|
| `srgb`                     | `:srgb`        | ✅ built-in        |
| `p3`, `display-p3`         | `:display_p3`  | ❌ ImagePipe extension |
| `adobe-rgb`, `adobergb`    | `:adobe_rgb`   | ❌ ImagePipe extension |

`cp` and `icc` are aliases for the same option, matching imgproxy. An **unknown identifier is a
parse error returned before any source fetch or cache access** (request-safety guideline: parser
validation fails before side effects).

### Plan representation

The imgproxy plan builder sets:

```elixir
%ImagePipe.Plan.Output{color_profile: {:convert, :display_p3}}
```

`color_profile` is a **single field** (`:preserve_source | :strip | {:convert, atom}`). Because `cp`
and `scp` write the same slot, **`cp` overrides `scp`**: specifying a target means convert-and-embed
that target, and the embedded profile is therefore not stripped — exactly matching the Pro doc
statement. No separate precedence logic is needed; the single field *is* the precedence.

## Architecture & data flow

```
URL  ──parse──▶  Plan.Output.color_profile = {:convert, :display_p3}
                      │
                 (cache key / ETag seed already include this — free)
                      │
 decode ─▶ InputColorManagement preamble (#124): import profiled/wide-gamut/CMYK
           source → working space (sRGB 8-bit / B_W grey), unconditionally
                      │
 transform (geometry, etc.) on working-space pixels
                      │
 encoder finalize (lib/image_pipe/output/encoder.ex, apply_color_result/3)
   add clause:  {:convert, target} →
       path = ImagePipe.<ProfileAssets>.path!(target)        # priv/icc/<file>.icc
       Vix.Vips.Operation.icc_transform(image, path, ...)    # converts + embeds output profile
                      │
 stripMetadata (stage 17) runs after — drops EXIF/XMP/IPTC but the ICC embedded by
   icc_transform is the color payload, preserved (matches "not stripped by scp")
```

Key points:

- The image reaching finalize is **already in working-space sRGB/B_W** (the #124 input preamble runs
  unconditionally). So the convert is working-space → target. For 8-bit sources this matches
  imgproxy, which also imports to sRGB in `colorspaceToProcessing` before any result conversion;
  the gamut starting point is imgproxy's own, not a new divergence we introduce.
- `Vix.Vips.Operation.icc_transform(image, output_profile, ...)` performs the colorspace transform
  **and embeds** `output_profile` in the result. We pass our shipped `.icc` path so embedded bytes
  are **deterministic** (stable ETag/cache across libvips builds) rather than relying on a
  libvips-version-dependent built-in.
- `Format.supports_color_profile?/1` is `true` for all four output formats (`:avif :webp :jpeg
  :png`), so the "format can't carry a profile" branch is **vacuous today**. We keep the gate for
  symmetry with `:preserve_source`; it simply never fires for RGB targets. (CMYK is where this gate
  becomes load-bearing — hence #214.)

### Profile assets

New module (name TBD during implementation, e.g. `ImagePipe.Output.ColorProfile` or a small
`ProfileAssets` helper under `ImagePipe.Output.*`) maps target atom → `priv/icc/<file>.icc`. The
resolution is an exhaustive `case` over the three known atoms; a non-matching atom is a programmer
error and is allowed to raise (internal-producer trust — the only producer is the parser, which only
emits the three known atoms).

**Shipped profiles are CC0 substitutes**, not the vendor originals:

| Target        | Shipped profile (CC0 / redistributable) | Note |
|---------------|------------------------------------------|------|
| `:srgb`       | public-domain sRGB (e.g. ICC / Elle Stone CC0) | primaries = sRGB |
| `:adobe_rgb`  | ClayRGB (Elle Stone, CC0) | Adobe RGB 1998 primaries; **not** the Adobe-authored profile |
| `:display_p3` | CC0 Display-P3-primaries profile | P3 primaries; **not** Apple's Display P3 |

The embedded profile **`description` tag will differ** from the vendor originals (and from imgproxy
Pro's exact bytes). Colors/primaries match; the human-readable name does not. This is a documented
divergence (below). Exact provenance/filenames are pinned during implementation and recorded in the
support matrix.

## Cache key & ETag

No new work. `lib/image_pipe/cache/key.ex` already includes `color_profile: output.color_profile` in
both `:automatic` and `:explicit` output modes, and the ETag derives from the same canonical Output
seed. A plain-atom target (`{:convert, :display_p3}`) therefore:

- distinguishes `cp:p3` from `cp:adobe_rgb` from `scp:1`/`scp:0` in the key automatically;
- needs no resolved-bytes hashing (the atom *is* the identity — cleaner than a filename or blob).

This satisfies the issue's "cache key includes the resolved profile identity" criterion for free.

## Validation boundaries

- **Parser (boundary input):** reject unknown identifiers before side effects. Tested.
- **Inside the codebase (trusted):** `apply_color_result` and the asset resolver do **not**
  re-validate the atom — an exhaustive `case` over the three known atoms, letting an impossible
  fourth value raise. No runtime duck-typing, no ICC structural validation (the `color` dep is not
  used). Per the architecture/validation guidelines: trust the in-repo producer (the parser),
  validate only at the boundary it controls.

## Divergences from imgproxy (for the conformance doc)

Record all three in `docs/imgproxy_support_matrix.md`, tagged by axis:

1. **Surface** — `srgb` is imgproxy-faithful; **`p3`/`display-p3` and `adobe-rgb`/`adobergb` are
   ImagePipe-specific extension identifiers**. On real imgproxy Pro these strings are *not* built-ins
   — Pro would look for a same-named file in `IMGPROXY_COLOR_PROFILES_DIR`. `cmyk` (a Pro built-in)
   is **not yet supported** (→ #214).
2. **Behavioral/pixel** — shipped profiles are **CC0 substitutes** with matching primaries but a
   **different `description` tag** than the vendor originals / imgproxy Pro bytes.
3. **Stage/order** — none new: convert+embed reuses the existing stage-16 encoder-finalize seam; the
   `{:convert, _}` arm sits beside `:preserve_source`/`:strip`. `cp` overrides `scp` via the single
   field (doc-grounded: Pro does not strip `cp`-embedded profiles).

## Tests

- **Parser/planner:** each accepted identifier (`srgb`, `p3`, `display-p3`, `adobe-rgb`, `adobergb`)
  → `{:convert, atom}`; `cp` and `icc` aliases equivalent; **unknown identifier → error before
  source fetch / cache access**.
- **Request-boundary pixel test:** a wide-gamut fixture + `cp:display_p3` → decode the response body,
  assert (a) an embedded ICC profile is present and (b) pixels match expectation. Cover the
  **no-geometry form** (`cp` without resize/crop/canvas/padding) separately, per the
  request-boundary test guideline.
- **`cp` overrides `scp`:** request with both set → target profile embedded (not stripped).
- **Cache:** two semantically-equal `cp` requests reuse the cache; `cp:p3` vs `cp:adobe_rgb` produce
  distinct keys.
- Keep wire-level tests representative; leave identifier grammar edge cases to parser-level tests.

## Docs + demo

- `docs/imgproxy_support_matrix.md`: flip the `color_profile` / `cp`,`icc` row to **Supported**;
  add the built-in target table; record the three divergences above; note `cmyk` → #214. Update the
  `IMGPROXY_COLOR_PROFILES_DIR` line (still ⭕ / out of scope, dir-resolution not implemented).
- `fiddle/assets/`: add a `cp` target control (none / srgb / display-p3 / adobe-rgb) wired into URL
  state so the demo exercises the new behavior end-to-end.

## Risks

- **Profile sourcing/licensing** — must land genuinely CC0/redistributable `.icc` files; provenance
  recorded in the matrix. Mitigated by using well-known CC0 sets (Elle Stone) for the matrix path.
- **Extension-name confusion** — `cp:p3` working here but not on imgproxy Pro is a sharp edge;
  mitigated by loud documentation in the support matrix as an explicit ImagePipe extension.
