# Output format capabilities probe and capability-aware resolution

Date: 2026-05-29
Issues: #97 (capabilities probe), #98 (capability-aware output resolution)

## Motivation

Production libvips builds vary in encoder support. AVIF write support requires
`libheif` plus an AV1 encoder (`libaom` or `librav1e`); WebP write support is
near-universal but not guaranteed; baseline JPEG/PNG are safe assumptions.

Today nothing in `ImagePipe.Output` checks whether the deployed libvips build can
write the format `Output.Policy.resolve/2` selected. A `format=avif` request (or
an `Accept`-negotiated AVIF) on a libvips without AVIF support fails per-request
in `ImagePipe.Output.Encoder.stream_output/3` with an opaque
`{:encode, exception, stacktrace}` error, *after* the source has already been
fetched and decoded.

This design adds:

1. **A boot-time capability probe** (#97) recording whether the libvips build can
   write AVIF and WebP, exposed through a cheap readable API.
2. **Capability-aware output resolution** (#98) that treats the two output modes
   differently, matching their different contracts:
   - **Explicit format** (`format=`/`f`/`ext`/extension suffix): if the build
     can't write the requested format, **reject early — before source fetch** —
     with a clear error. No fallback.
   - **Automatic format** (`Accept`-negotiated): (1) filter the candidate formats
     by capability so resolution never picks an unproducible format, and (2)
     change source-passthrough so a modern (AVIF/WebP) source the client didn't
     accept transcodes to raster-by-alpha instead of being served as-is. Only
     baseline JPEG/PNG sources pass through. The capability-filtered candidate
     list is the cache material — no separate capability field.

## Goals

- Probe `:avif` and `:webp` write support once at boot; expose a cheap readable API.
- Explicit unsupported-format requests fail deterministically, before side
  effects, with a clear reason (not an opaque post-decode encoder crash).
- Automatic resolution never selects an unproducible format and never serves a
  client a *modern* format (AVIF/WebP) it did not accept. Baseline JPEG/PNG
  selection by the raster fallback is not strictly `Accept`-negotiated (see the
  residual limitation in Part 2).
- Cache material correctly identifies the produced variant. For automatic mode
  this falls out of the capability-filtered candidate list — no separate
  capability field — and is naturally `Accept`-sensitive (only formats that are
  both accepted and producible appear).
- Reuse the existing raster-by-alpha fallback path; add no new resolution branch.

## Non-goals (explicit follow-ups)

- **Falling back an explicit format to a different format.** Explicit means the
  caller chose a specific format; we honor it or fail. A future "prefer WebP for
  an explicit modern-format request on an incapable build" mode can be added if
  a real need appears.
- **JPEG XL and other formats.** Out of scope; not in the current `Format`
  output model.
- **`:fallback_to_source` error policy (#100)** and the **`:on_error` renderers
  (#99).** Separate mechanisms. The explicit-unsupported rejection emits a
  distinct error reason that flows through the existing error path and will be
  shaped by #99's status mapping when that lands.

## Part 1 — `ImagePipe.Output.Capabilities` (#97)

New module inside the existing `Output` boundary. No boundary `deps` changes: it
works against libvips/`Image` and `:persistent_term` only.

```elixir
@type capability_map :: %{optional(Format.output_format()) => boolean()}

@spec probe() :: :ok
@spec supports?(Format.output_format()) :: boolean()
@spec supports?(Format.output_format(), keyword()) :: boolean()
```

- `probe/0` — encodes a 1×1 image in memory to each candidate format (`:avif`,
  `:webp`), caches each boolean in `:persistent_term` under a stable per-format
  key. Idempotent. Emits a single `Logger.warning` per missing capability.
  Returns `:ok`.
- `supports?(format)` — reads `:persistent_term`; if `probe/0` has not run, it
  performs a one-off probe for that format and caches it (so tests that bypass
  the supervisor still work).
- `supports?(format, opts)` — when `opts` carries
  `output_capabilities: %{avif: false}` (or similar), that explicit map
  overrides the `:persistent_term` lookup. Production callers omit it; tests use
  it to force a build profile without touching global state.
- `:jpeg` and `:png` are baseline assumptions: `supports?/1,2` returns `true`
  for them without probing. `:tiff`/`:jpeg2000`/`:jpeg_xl` are source-only in the
  current `Format` model and are not probed; `supports?/1` for a non-probed,
  non-baseline format returns `false`.

`:persistent_term` is appropriate because libvips capabilities cannot change
without a process restart. A module-level comment states that assumption.

Wiring: `probe/0` is called from `ImagePipe.Application.start/2` at supervisor
start. The `Application` boundary gains an explicit dep on `ImagePipe.Output`;
add the edge if the `Boundary` rules require it.

### #97 test strategy

- Probe returns booleans for `:avif`/`:webp` and is idempotent.
- `supports?/2` with an explicit `output_capabilities` map overrides the probe.
- Baseline formats report `true` without probing.
- Warning emitted once per missing capability (assert via `ExUnit.CaptureLog`
  with an injected capability map, not by mutating the real build).

## Part 2 — Capability-aware output resolution (#98)

### Explicit mode → reject early, no fallback

`Output.Policy` resolves explicit mode before source fetch
(`resolve_before_source_fetch/1` returns `{:selected, format, :explicit}`).
Add a capability check at that point:

- `Capabilities.supports?(format, opts)` true → unchanged (select the format).
- false → return a distinct error, e.g. `{:error, {:unsupported_output_format,
  format}}`, **before any source fetch or cache write**.

Because both the requested format (from parsing) and capability (from the boot
probe) are known pre-fetch, this is a request-safety rejection: no source bytes
fetched, nothing cached, no opaque encoder crash. The error reason is distinct
and flows through the existing error path; precise HTTP status mapping is left to
the existing machinery / #99.

**Cache material:** unchanged — explicit material stores the exact requested
format, as today. Failures are never cached, so no capability material is needed
on this path.

Automatic mode gets two changes.

**Change 1 — capability filter on the candidate list.**
`Negotiation.modern_candidates/2` already filters candidate modern formats by the
`auto_avif`/`auto_webp` config flags and by `Accept`. Add the capability filter
**in this same chokepoint**: candidates ∩ producible. This guarantees resolution
never selects an unproducible modern format, and it makes the cache material
capability-correct for free (see below).

**Change 2 — source-passthrough honors `Accept`.** When the filtered candidate
list is empty, `resolve_source_format/2` decides the fallback. Today it passes
through the source's own format whenever that format is an `output_format?`,
which means a natively-AVIF/WebP source is served *even to a client that didn't
accept it* (reaching this branch means no modern format was accepted). Change the
rule so only the baseline formats pass through; modern source formats join the
existing raster path:

- source ∈ `[:jpeg, :png]` → `{:selected, source_format, :source}` (baseline,
  broadly decodable — passthrough);
- source is any other known format (`:avif`, `:webp`, or a `source_only_format`
  like `:tiff`/`:heif`/`:jpeg2000`/`:jpeg_xl`) → `:needs_final_image_alpha` →
  the producer decodes alpha and `resolve_final_image_alpha/2` returns PNG (alpha)
  or JPEG (no alpha);
- otherwise → `{:error, :source_format_required}` (unchanged).

Resulting behavior:

| `Accept`              | AVIF support | Resolved                          |
| --------------------- | ------------ | --------------------------------- |
| `avif, webp`          | yes          | AVIF                              |
| `avif, webp`          | no           | WebP (still accepted)             |
| `avif` only           | yes          | AVIF                              |
| `avif` only           | no           | raster-by-alpha (PNG/JPEG)        |
| `jpeg` only, src AVIF | either       | raster-by-alpha (PNG/JPEG)        |
| `jpeg` only, src JPEG | either       | JPEG (baseline passthrough)       |

Two payoffs from Change 2:

1. **No undecodable output.** A modern source format is never served to a client
   that didn't accept it; it transcodes to raster instead.
2. **Capability stops mattering for the source path.** Source passthrough now
   yields only baseline JPEG/PNG (always writable), and modern sources route to
   raster (also baseline). So in automatic mode, capability affects the output
   *only* through the filtered candidate list — which removes the
   capability-writability check that an earlier draft put in
   `resolve_source_format/2`, and eliminates the cache "un-keyable corner"
   entirely.

In automatic mode an unproducible format is therefore **never** sent to the
encoder — automatic mode never errors on a missing encoder; only explicit mode
does.

**Residual (accepted) limitation:** raster-by-alpha picks PNG vs JPEG by alpha,
not by what the client listed, so a `Accept: image/jpeg`-only client whose result
has alpha still receives PNG. This matches the existing raster fallback (which
never checked `Accept` for baseline formats) and is a strict improvement over
serving AVIF. Full per-format strict negotiation (406 when nothing accepted is
producible) is the separate, unchosen option.

**Cache material:** no separate capability field. The automatic material already
records `modern_candidates`; once that list is capability-filtered, it *is* the
capability material, and it is `Accept`-sensitive by construction — only formats
that are both accepted and producible appear. This keys the produced variant
correctly across builds for every case:

- `Accept: avif,webp` on an AVIF-less build → `[webp]` (vs `[avif,webp]`) →
  distinct key.
- `Accept: avif` only on an AVIF-less build → `[]` (vs `[avif]`) → distinct key,
  and correctly *shares* an entry with any other request that resolves to the
  same raster/baseline bytes (e.g. `Accept: jpeg`).
- Empty candidate list + AVIF/WebP source → raster-by-alpha, which is
  capability-independent, so the key is identical across builds *and* produces
  identical bytes. The old un-keyable corner is gone.

A flat `%{avif: _, webp: _}` profile would be wrong here: it would stamp WebP's
capability onto an `Accept: avif`-only request where WebP was never a candidate,
modelling a dependence that doesn't exist.

Per the greenfield cache guidance, reshape the canonical key data in place
without a version bump.

### Where the capability filter lives

`Negotiation.modern_candidates/2` is the single chokepoint called by
`cache/key.ex`, `output/policy.ex`, and `request/http_cache.ex`. Apply the
capability filter there, so the filtered list flows identically to the cache
material, resolution, and conditional-GET evaluation — one place, three
consistent consumers. `modern_candidates/2` becomes a function of
`Accept`/config/capability; capability comes from `Capabilities.supports?/2`
(reading `:persistent_term`, or an injected `output_capabilities` map in tests),
keeping it deterministic given `opts`. The source-passthrough rule (Change 2)
lives in `Policy.resolve_source_format/2`; it is a pure negotiation rule (which
source formats may pass through), not a capability check.

### #98 test strategy

Wire-level / boundary tests driving `ImagePipe.call/2` with an injected
capability profile (`output_capabilities: %{avif: false}`):

- `format=avif` + AVIF unsupported → request rejected **before** source fetch
  (assert no source access) with the distinct error; nothing cached.
- `format=webp` + WebP unsupported → same rejection shape.
- `format=jpeg` (baseline) → always succeeds regardless of probe.
- `Accept: image/avif,image/webp` + AVIF unsupported → WebP, `Vary: Accept`.
- `Accept: image/avif` only + AVIF unsupported, source JPEG → JPEG baseline
  passthrough (not WebP — never serve an unaccepted format).
- `Accept: image/jpeg` only, source AVIF → raster-by-alpha **regardless of AVIF
  support** (the Change-2 negotiation rule; assert it holds on a capable build
  too, proving capability isn't what drives it).
- `Accept: image/jpeg` only, source JPEG → JPEG baseline passthrough.
- `Accept: image/avif,image/webp` + AVIF supported → AVIF (no change).
- Cache: same URL under the same capability profile reuses one entry; the same
  automatic URL under `avif:true` vs `avif:false` produces **different** cache
  entries (the filtered candidate list differs).

Unit tests:

- `Negotiation.modern_candidates/2` drops unproducible formats given an injected
  capability map, across `Accept`/`auto_*` combinations.
- `Policy.resolve_source_format/2`: JPEG/PNG source passes through; AVIF/WebP and
  source-only sources route to the alpha path; unknown format errors.
- `Policy` explicit-mode capability rejection returns the distinct error
  pre-fetch and leaves a supported explicit format untouched.

## Boundaries and architecture

- `ImagePipe.Output.Capabilities` lives in the `Output` boundary; depends only on
  libvips/`Image` and `:persistent_term`.
- `ImagePipe.Application` gains an explicit `Boundary` dep on `ImagePipe.Output`
  for the boot probe call (add the edge if rules require it).
- No request/source/response code references concrete transform/format internals
  beyond existing patterns.

## Demo

No new demo control is required. If a demo control exposes explicit format
selection, note that it will now surface a clear error on a build that can't
write the chosen format (manual check only).

## Follow-up issues to file

- Optional "prefer WebP for an explicit modern-format request on an incapable
  build" downgrade mode, if a real need appears.
