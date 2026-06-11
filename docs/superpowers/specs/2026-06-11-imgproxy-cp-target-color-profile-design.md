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

| URL string(s)              | Target atom    | imgproxy alignment |
|----------------------------|----------------|--------------------|
| `srgb`                     | `:srgb`        | surface-faithful (built-in name) — **but output bytes differ** (CC0 sRGB, not Pro's built-in) |
| `p3`, `display-p3`         | `:display_p3`  | ❌ ImagePipe extension (Pro: custom-dir filename) |
| `adobe-rgb`, `adobergb`    | `:adobe_rgb`   | ❌ ImagePipe extension (Pro: custom-dir filename) |

`cp` and `icc` are aliases for the same option, matching imgproxy. An **unknown identifier is a
parse error returned before any source fetch or cache access** (request-safety guideline: parser
validation fails before side effects).

**Percent-decoding (non-goal in v1).** imgproxy percent-decodes `cp` values because custom-dir
filenames may need escaping. Our v1 identifiers are ASCII-safe (`srgb`, `display-p3`, `adobe-rgb`),
so the parser matches the raw string against the allowlist and does **not** percent-decode. A
percent-encoded built-in (e.g. `cp:display%2Dp3`) therefore fails the allowlist where imgproxy would
decode-then-resolve — a minor, documented divergence; percent-decoding lands with the custom-dir
slice, not here.

**Namespace-collision hazard with imgproxy custom-dir filenames.** Because Pro reaches wide-gamut
only via `IMGPROXY_COLOR_PROFILES_DIR` filenames, the strings `p3`/`adobe-rgb` occupy the *same
namespace* imgproxy reserves for custom files. On a Pro deployment that happens to have a `p3.icc` in
its profiles dir, `cp:p3` resolves to *that* file (possibly Apple Display P3) — different bytes and
provenance than our CC0 P3, under the identical URL. So these extension identifiers are not merely
"unsupported on Pro" but "potentially **differently-resolved** on Pro." This is called out loudly in
the support matrix.

### Plan representation

The imgproxy plan builder sets:

```elixir
%ImagePipe.Plan.Output{color_profile: {:convert, :display_p3}}
```

`color_profile` is a **single field** (`:preserve_source | :strip | {:convert, atom}`). Because `cp`
and `scp` write the same slot, **`cp` overrides `scp`**: specifying a target means convert-and-embed
that target, and the embedded profile is therefore not stripped — **consistent with** the Pro doc
statement that "profiles embedded with this option are not stripped by `strip_color_profile`." The
single field *is* the precedence; no separate precedence logic is needed. Caveat: the doc proves only
that the cp-embedded *profile survives* `scp`; it does not specify any residual `scp` behavior when
both are set. For the RGB-target slice this is unobservable (the output carries exactly one ICC
profile either way), but the single-field model cannot represent any cp+scp interaction beyond
"embedded target survives" — noted as a bounded modeling limit, not asserted as full doc parity.

## Architecture & data flow

```
URL  ──parse──▶  Plan.Output.color_profile = {:convert, :display_p3}
                      │  (cp/icc overrides the scp slot in the plan builder — see Parser precedence)
                 (cache key / ETag seed already include this — free)
                      │
 decode ─▶ InputColorManagement preamble (#124): import profiled/wide-gamut/CMYK
           source → working space (sRGB 8-bit / B_W grey), unconditionally
                      │
 transform (geometry, etc.) on working-space pixels
                      │
 encoder finalize (lib/image_pipe/output/encoder.ex, color_result/2)
   NEW top-level color_result clause for {:convert, target}:
       path = ColorProfile.path!(target)                 # priv/icc/<hardcoded file>.icc
       image = ensure_color_input(image)                 # promote greyscale B_W/sGrey → sRGB
       Vix.Vips.Operation.icc_transform(image, path,
         input_profile: working_space_profile(image),    # "sRGB" — NOT embedded: true
         depth: icc_depth(image))                         # converts + embeds target profile
       strip_metadata_and_private(image, resolved)        # preserves the embedded target ICC
```

### Finalize integration (corrected after review — this is the load-bearing part)

`color_result/2` ([encoder.ex:72](lib/image_pipe/output/encoder.ex)) currently runs
`restore_backup → apply_color_result(keep?, imported) → maybe_drop_profile(keep?)`. The convert path
**cannot** be a clause of `apply_color_result/3` (that function only sees `(keep?, imported)`
booleans, not the target). It also must **not** flow through `maybe_drop_profile`: for
`{:convert, _}`, `keep?` is `false`, and `maybe_drop_profile(image, false)`
([encoder.ex:161](lib/image_pipe/output/encoder.ex)) **removes `icc-profile-data` — which would strip
the profile the convert just embedded.**

So convert is a **new top-level `color_result/2` clause** that fully bypasses the
`restore_backup`/`apply_color_result`/`maybe_drop_profile` chain:

```elixir
defp color_result(image, %Resolved{color_profile: {:convert, target}} = resolved) do
  with {:ok, image} <- convert_to_target(image, target, resolved.format) do
    {:ok, strip_metadata_and_private(image, resolved)}
  end
end

# existing clause (unchanged) handles :preserve_source / :strip
defp color_result(image, %Resolved{} = resolved) do ... end
```

`strip_metadata_and_private` already preserves the ICC when `color_profile != :strip`
([encoder.ex:178-179,194](lib/image_pipe/output/encoder.ex)), so the embedded target survives the
metadata strip **as long as `maybe_drop_profile` never runs** — which the dedicated clause
guarantees. EXIF/XMP/IPTC stripping (incl. the per-field GPS/copyright removal via
`minimize_metadata`) still runs, so a target profile does **not** suppress metadata stripping.

### `convert_to_target` mechanics (resolves N1/N2)

The image at finalize is in **working-space sRGB (color) or sGrey/B_W (greyscale)** from the #124
preamble — regardless of whether the source was tagged. Therefore:

- **Input profile is the known working space, not the embedded tag.** Use
  `icc_transform(image, target_path, input_profile: "sRGB", depth: ...)`. Do **not** use
  `embedded: true` — an untagged-sRGB source has no `icc-profile-data` and `embedded: true` would
  no-op (the exact short-circuit `to_standard` relies on, [encoder.ex:112-114](lib/image_pipe/output/encoder.ex)).
- **Greyscale promotion (N2).** A B_W/sGrey (1-band) image must be promoted to sRGB colour before/within
  the transform (a 1-band→3-band P3 transform is not safe to assume). `convert_to_target` first
  normalizes greyscale to sRGB colourspace, then transforms sRGB → target. (libvips `colourspace`,
  not a `Transform` module — stays inside the Output boundary.)
- **No gamut clipping for these targets.** Working space is sRGB and all v1 targets
  (sRGB ⊆ Display P3 ⊆ Adobe RGB by gamut) are ≥ sRGB, so the conversion is a *widening* — there is
  no clip. Rendering intent is libvips' default (relative colorimetric); fine for a no-clip widen.
- **`icc_transform` embeds the output profile** in the result. We pass our shipped `.icc` path so the
  embedded bytes are **deterministic** (stable ETag/cache across libvips builds), not a
  libvips-version-dependent built-in.
- **Format gate (vacuous today).** `Format.supports_color_profile?/1` is `true` for all four output
  formats, so the "format can't carry a profile" branch never fires for RGB targets. `convert_to_target`
  keeps the gate for symmetry; CMYK (#214) is where it becomes load-bearing.

### Parser precedence (resolves Q3)

[options.ex:315](lib/image_pipe/parser/imgproxy/options.ex) unconditionally sets the `strip_color_profile`
boolean slot, which the plan builder maps to `:strip`/`:preserve_source`. To make `cp` override `scp`
deterministically: add a `color_profile` (target atom or `nil`) field to the pipeline request, thread it
through options resolution, and in `plan_builder` map **target-present → `{:convert, target}`
regardless of the `scp` boolean** (`scp` only decides `:strip` vs `:preserve_source` when no target is
set). The single `color_profile` plan field is the precedence; the override happens at plan-build time.

### Profile assets

New module under `ImagePipe.Output.*` (e.g. `ImagePipe.Output.ColorProfile`) maps target atom →
shipped `priv/icc/*.icc` path. Implementation constraints from the security review:

- **Exhaustive `case` over the three known atoms, with hardcoded full filenames per clause** — e.g.
  `:adobe_rgb -> "ClayRGB-v2.icc"`. Do **not** derive the filename by interpolating the atom into a
  path template (`"#{name}.icc"`). A hardcoded clause leaves no string-building seam for user input to
  slot into if a future dir-resolution slice is added; a non-matching atom raises `FunctionClauseError`
  (internal-producer trust — the only producer is the parser, which emits only the three atoms).
- **Compile-time presence guard.** Mark each `.icc` an `@external_resource` and assert its presence at
  compile time so a missing asset fails the build loudly rather than surfacing as a per-request error
  on a broken release. (`icc_transform` needs a filesystem path, so the bytes can't be fully inlined;
  the compile-time guard is the "fail early" mechanism.) If a trusted asset is somehow missing at
  runtime, the failure should map to an internal/encode error (500), **not** a `{:decode, _}` (415)
  that misattributes blame to the user's source.

**Shipped profiles are CC0 substitutes**, not the vendor originals:

| Target        | Shipped profile (CC0 / redistributable) | Note |
|---------------|------------------------------------------|------|
| `:srgb`       | public-domain sRGB (e.g. ICC / Elle Stone CC0) | primaries = sRGB |
| `:adobe_rgb`  | ClayRGB (Elle Stone, CC0) | Adobe RGB 1998 primaries; **not** the Adobe-authored profile |
| `:display_p3` | CC0 Display-P3-primaries profile | P3 primaries; **not** Apple's Display P3 |

The embedded profile **bytes differ entirely** from the vendor originals / imgproxy Pro — this is
true even for the faithful-named `:srgb` identifier (we ship a CC0 sRGB, not imgproxy's "built-in
compact sRGB"). Primaries/white-point match the vendor targets, but the **`description` tag differs
and TRC/rendering-intent metadata may differ subtly**, which can shift transformed pixels — not just
the embedded name. So no `cp` identifier (including `srgb`) is byte-conformant with imgproxy Pro
output. Acceptance therefore pins **actual decoded pixels** against our own fixtures (not primaries
alone, and not a wire-diff). Exact provenance/filenames are pinned during implementation and recorded
in the support matrix.

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

1. **Surface** — `srgb` is surface-faithful (a Pro built-in name); **`p3`/`display-p3` and
   `adobe-rgb`/`adobergb` are ImagePipe-specific extension identifiers.** On real imgproxy Pro these
   strings are *not* built-ins — Pro resolves them against `IMGPROXY_COLOR_PROFILES_DIR`, so on a Pro
   deployment with a matching custom file the same URL would resolve to a *different* profile
   (same-namespace collision, see Identifier surface). `cmyk` (a Pro built-in) is **not yet
   supported** (→ #214).
2. **Behavioral/pixel** — shipped profiles are **CC0 substitutes**. Bytes differ entirely from
   imgproxy Pro **for every identifier, `srgb` included** (CC0 sRGB ≠ Pro built-in compact sRGB).
   Primaries/white-point match the vendor targets, but `description` and possibly minor
   TRC-dependent pixel values differ — so output is **not byte-conformant** with Pro for any `cp`
   value.
3. **Stage/order** — none new: convert+embed reuses the existing encoder-finalize seam; the
   `{:convert, _}` arm is a new top-level `color_result/2` clause beside `:preserve_source`/`:strip`
   (it bypasses the `restore_backup`/`maybe_drop_profile` chain so the embed survives). `cp` overrides
   `scp` via the single field (doc-consistent: Pro does not strip `cp`-embedded profiles).

## Tests

- **Parser/planner:** each accepted identifier (`srgb`, `p3`, `display-p3`, `adobe-rgb`, `adobergb`)
  → `{:convert, atom}`; `cp` and `icc` aliases equivalent; **unknown identifier → error before
  source fetch / cache access**.
- **Parser precedence:** `cp:p3` + `scp:1` and `cp:p3` + `scp:0` both → `{:convert, :display_p3}`
  (the `scp` boolean does not clobber the target).
- **Request-boundary pixel test:** a wide-gamut fixture + `cp:display_p3` → decode the response body,
  assert (a) an embedded ICC profile is present and (b) **decoded pixels** match expectation (not
  primaries alone — see behavioral divergence). Cover the **no-geometry form** (`cp` without
  resize/crop/canvas/padding) separately, per the request-boundary test guideline.
- **`cp` overrides `scp`:** request with both set → target profile embedded (not stripped).
- **EXIF/GPS still stripped under `{:convert, _}`:** a source with EXIF GPS + `cp:display_p3` and
  default `strip_metadata` → output carries the target ICC **and** has GPS/EXIF stripped (guards the
  convert clause from regressing the metadata-strip path that runs after it).
- **Greyscale source + RGB target (N2):** a B_W source + `cp:display_p3` → valid 3-band output with
  the target embedded (no band-mismatch failure).
- **Untagged-sRGB source + RGB target (N1):** an untagged source + `cp:adobe-rgb` → target embedded
  (proves the convert does not depend on `embedded: true`).
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

## Review log

Parallel disjoint-focus review run before planning (3 reviewers): **compatibility** (imgproxy Pro
doc parity), **security/request-safety**, **architecture/codebase-fit**. Compatibility and security
returned no blockers (security verified the pre-side-effect ordering against the real
`plug.ex`/`runner.ex` call flow). Architecture found two blockers in the original mechanics
description — both confirmed against the code and fixed here:

- **B1** — convert cannot be a clause of `apply_color_result/3` (no target in scope); it is a new
  top-level `color_result/2` clause.
- **B2** — `maybe_drop_profile(_, false)` would strip the freshly-embedded profile; the convert clause
  bypasses that chain.

Also incorporated: N1 (input-profile, not `embedded: true`), N2 (greyscale promotion), Q3 (parser
precedence so `cp` overrides the `scp` slot), security hardening (hardcoded per-clause filenames +
compile-time asset presence guard), and compat-doc honesty (no `cp` value is byte-conformant with
Pro; `srgb` is surface-faithful only; extension-name same-namespace collision; percent-decode a
documented non-goal). Cache-key/ETag "free", format-gate "vacuous", and Output-boundary placement were
all verified correct against the code and unchanged.
