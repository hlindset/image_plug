# Full input color management (issue #124)

**Status:** Design — reviewed (two full + one targeted parallel review round applied)
**Issue:** [#124](https://github.com/hlindset/image_pipe/issues/124)
**Related:** #30 (closed, origin), #119 (output `cp`/`icc` embedding), #121 (`preserve_hdr`), #149 (trim, closed)
**Date:** 2026-06-11

## Problem

imgproxy color-manages **every** image, regardless of `strip_color_profile`
(`scp`). `colorspaceToProcessing`
(`local/imgproxy-master/processing/processing.go` +
`colorspace_to_processing.go`) imports the embedded ICC profile into a standard
working space (sRGB, or 16-bit RGB for HDR-capable formats) **before** trim,
crop, scale, and effects. `colorspaceToResult` at finalize then re-embeds the
source profile (`scp` off) or drops it (`scp` on).

ImagePipe today implements a narrower `NormalizeColorProfile` transform op that
converts to sRGB **only when `scp` is on**, positioned **after** geometry. This
matches imgproxy for the default `scp:1` (effects run on sRGB pixels, no output
profile). It diverges in two ways:

1. **Gating.** With `scp:0` + a tone effect on a wide-gamut source, ImagePipe
   runs the effect in the source profile space and keeps the profile, instead of
   importing to a working space and re-embedding the source profile on output.
2. **Position.** ImagePipe converts after crop+resize, so resize math runs in the
   source profile space, not the working space. It is also after **trim**, whose
   border detection therefore runs in the source-profile space and yields a
   different trim box than imgproxy (which converts inside `vips_trim`).

This design generalizes input color management to match imgproxy and removes both
divergences (matrix stages 4 and 16, plus the trim detection-colorspace note).

## Goals / non-goals

**Goals**
- Import every profiled / wide-gamut / CMYK source to a working space **before**
  any processing step (trim included), with the same import gating imgproxy uses.
- Re-embed the source profile on output when `scp:0`; drop it when `scp:1`.
- Match imgproxy's observable pixels and embedded-profile behavior on the
  differential conformance fixtures.
- Keep the **output** profile decision a single declarative `Plan.Output` policy.

**Non-goals (explicit seams, not implemented here)**
- Output profile conversion/embedding (`cp`/`icc`) — **#119**, modeled as the
  `{:convert, target}` policy value below.
- 16-bit / HDR working-space preservation — **#121**, modeled as the
  `supports_hdr?` flag below (hardwired `false`).

## What is and isn't parser-controlled (product-neutrality)

Input working-space conditioning is **unconditional core behavior**, not a parser
toggle. This is the same posture as EXIF auto-orient and shrink-on-load: the core
always conditions a decoded image into a known working space, because every
downstream transform is *defined* on working-space pixels and every realistic
compatibility target color-manages. For untagged/already-sRGB inputs the
conditioning is a no-op (see import gating), so the common path is unaffected.

The **only** parser-controlled knob is the *output* profile policy — a single
declarative field on `Plan.Output`. We do **not** claim input conditioning is
"the parser's choice"; it is core, and if a future target ever needed to skip it,
that would be a new gating field added then (YAGNI now).

## Ordering vs EXIF auto-orient

imgproxy applies EXIF autorotate in `rotateAndFlip` (pipeline step 7,
`processing.go` + `rotate_and_flip.go`), i.e. **after** `colorspaceToProcessing`
(step 4), crop, and scale. ImagePipe's color preamble runs first and its EXIF
orientation is a **deferred flush** (`pending_orientation` / `OrientationFlush`)
applied late — so color import also precedes orientation here. This matches
imgproxy, and is pixel-correct regardless because a per-pixel color transform
(`icc_import` / `colourspace`) **commutes** with the geometric rotate/flip of the
orientation flush (color is orientation-independent; imgproxy itself color-manages
pre-rotate for the same reason). No divergence; stated so the ordering isn't left
implicit.

## Architecture

### A. Input conditioning is a fixed pipeline preamble, not an operation

Input color management is **not** a `Plan.Operation`. It joins the existing
data-determined preamble family (decode access mode, shrink-on-load planning,
EXIF auto-orient `pending_orientation`). Rationale, generalized into the project
rule below:

- It is **not a user-requested transform** — nobody asks to "import my ICC
  profile"; it is invisible input conditioning.
- Its behavior is **sourced entirely from runtime image inspection** (the
  embedded profile bytes + interpretation + band format), which **no operation
  struct can see**.

**Module & seeding.** A new `ImagePipe.Transform.InputColorManagement` (in
`Transform.*`) owns the working-space chooser (`working_space/2`) and the import
executor. `PlanExecutor.execute/3` seeds it **once, before `execute_pipelines`**,
in the same block as `seed_orientation` (not "per pipeline" — `execute_pipeline`
runs per pipeline). It records carry state on `State` (§3) and applies the import
eagerly to `State.image`. An idempotency guard (the recorded `color_imported?`
flag) makes any re-entry a no-op — belt-and-suspenders, since seeding in
`execute/3` already runs it once.

**Materialization.** The preamble runs **outside** `Chain`, so no
`requires_materialization?/1` callback applies; like `OrientationFlush`, it owns
its own materialization decision. `icc_import` + `colourspace` are per-pixel point
ops (sequential-safe); the 16-bit-alpha band split/rejoin path (§2) reorders
bands and **must** be checked against a genuinely streamed open in the new harness
(§Testing) — if it ever needs random access, the preamble self-materializes.

### B. Output handling is one declarative field on `Plan.Output`

Replace the `strip_color_profile :: boolean()` field with:

```elixir
color_profile :: :preserve_source | :strip | {:convert, target}
```

- `:strip` — convert to standard space, drop the profile (imgproxy `scp:1`).
- `:preserve_source` — re-embed the source profile on output (imgproxy `scp:0`).
- `{:convert, target}` — **#119 seam**, not implemented here. `target` **must** be
  a product-neutral profile reference (a built-in atom or a resolved profile
  handle); imgproxy `cp`/`icc` dialect parsing stays isolated in the parser. No
  dialect string enters the neutral plan, the cache key, or the ETag.

The imgproxy `plan_builder` maps `scp:1 → :strip`, `scp:0 → :preserve_source`,
and stops emitting any color op in the pipeline list.

## Components & data flow

imgproxy's real order (`processing.go`) is `trim → scaleOnLoad →
colorspaceToProcessing → crop → scale → rotateAndFlip → effects → …`, and **`trim`
itself calls `colorspaceToProcessing` internally** (`trim.go`) then `CopyMemory` +
disables scaleOnLoad; the standalone `colorspaceToProcessing` is then a no-op via
the imported guard. Because our import is idempotent, conditioning once before all
operations is pixel-equivalent:

```
decode (sequential)  ──►  shrink-on-load load option (DecodePlanner; fixed at decode-open)
  └─ PREAMBLE: input color management (eager, in execute/3)         ← new, core
       guess working space → (if importable) record source ICC + set imported flag
       on State → icc_import (→ PCS float) → colourspace (→ working space)
  └─ trim            (sees working-space pixels)
  └─ orientation flush / crop / resize / effects / canvas / padding / background
delivery materialization (Processor.materialize_for_delivery, post-flush + post-Clamp):
  └─ stamp source-ICC backup + imported marker onto the realized image (from State carry)
encoder finalize (Output boundary): colorspace-to-result state machine ← generalized
       read backup+marker → restore → export-to-source+embed | transform-to-standard
       → drop-if-!keep → THEN strip other metadata
```

The shrink-on-load load option is computed by `DecodePlanner` and applied at
`Image.new_from_*` **open time**, before the image exists; the preamble runs on
the already-shrunk image and cannot perturb the load factor. Color conversion
preserves the per-axis pixel grid, so `source_dimensions` / `decode_shrink` and
the residual-resize sizing in `State` stay valid.

### 1. Working-space chooser (port of `guessTargetColorspace`)

Pure function of decoded interpretation + a `supports_hdr?` flag, **hardwired
`false`** today (the #121 seam; #121 derives it from `format.SupportsHDR() &&
preserve_hdr`). Lives in `Transform.InputColorManagement`.

| Source interpretation | working space, `supports_hdr?: false` (today) | (when #121 flips `true`) |
|---|---|---|
| sRGB / RGB (8-bit) | sRGB (as-is) | as-is |
| B_W (8-bit grey) | **B_W** (as-is) | as-is |
| RGB16 (3×uint16) | sRGB | RGB16 (kept) |
| Grey16 | **B_W** | Grey16 (kept) |
| CMYK | sRGB | sRGB |
| other | sRGB | RGB16 |

8-bit greyscale stays **B_W** (not sRGB). Greyscale standardization at finalize
targets **sGrey**, color targets **sRGB** (mirrors
`vips_icc_transform_standard`).

### 2. Preamble execution (mirrors `colorspaceToProcessing` + `vips_icc_import_go`)

1. **Rad2Float** equivalent for Radiance/coded HDR sources — best-effort, no-op
   for the common formats.
2. **Linear-light source** (`interpretation == scRGB`, header-level — imgproxy's
   `IsLinear()`) → **drop** profile, do **not** record backup, do **not** set the
   imported flag. Then **still** run the working-space `colourspace` conversion
   (for scRGB with `supports_hdr?:false` the chooser gives sRGB). Re-embedding
   after a one-way linear conversion would yield wrong colors.
3. **Import gating** (mirrors imgproxy's `ImportColourProfile` early-returns). Run
   the import only when **all** hold; otherwise skip import (no backup, imported
   flag unset) but still run the working-space `colourspace`:
   - the image **has an embedded ICC profile**, **and**
   - **not** (`interpretation == sRGB` **and** the embedded profile is canonical
     sRGB-IEC61966-2.1) — imgproxy's skip is the *conjunction* of both
     (`vips_icc_is_srgb_iec61966`), **and**
   - coding is `NONE` and band format is `UCHAR`/`USHORT`.
4. **Import path** (when gated in): **record** the source ICC bytes + set the
   imported flag on `State` (§3), **`icc_import`** the embedded profile → the
   image is now in **PCS float (XYZ or LAB**, sniffed from the profile header —
   port `vips_icc_get_pcs`: bytes 20–23 == `"XYZ "` → XYZ else LAB, guarded by
   `data_len >= 128`). Then **`colourspace`** to the chosen working space.
   - **16-bit + alpha:** detect by **guessed interpretation** RGB16/Grey16 with
     `bands > colorbands` (not raw "16-bit"). Mirror `vips_icc_import_go`: split
     the alpha band, import the color bands, rescale alpha 65535→255
     (`linear` 1/255), rejoin. Live today (RGB16/Grey16 in scope under
     `supports_hdr?:false`).
5. **No embedded profile + already standard** → whole preamble is a no-op (common
   untagged-sRGB path).

The vix wrappers `Vix.Vips.Operation.icc_import` / `icc_export` / `icc_transform`
are confirmed present at runtime. They are the bare `vips_icc_*`, **not**
imgproxy's `_go` variants — so the PCS sniff, the sRGB-IEC61966 guard, and the
16-bit-alpha rescale above are ours to port. `icc_import` exposes `embedded:`,
`pcs:`, `intent:` (default `pcs: :VIPS_PCS_LAB`; we set it explicitly per the
sniff); it has **no `depth` option** (depth applies only to `icc_export` /
`icc_transform`). `Image.to_colorspace/2,3` is insufficient (interpretation-only,
or known-profile-only output) — confirmed.

### 3. Source-profile carry (on State, stamped at the boundary)

The encoder needs the source ICC bytes + the "imported" flag, but transform
`State` does not reach the encoder (`Encoder.stream_output/3` takes
`(VixImage, Resolved, opts)`; the `Output` boundary must not depend on
`Transform`). The robust carry, which also sidesteps any "do custom header fields
survive `autorotate`/`rotate`/`flip`?" question through the deferred orientation
flush:

- The preamble records **`State.source_color_profile :: binary() | nil`** (raw ICC
  bytes) and **`State.color_imported? :: boolean()`** (set only when an actual
  `icc_import` ran). These live in the transform domain and survive every op
  regardless of libvips metadata behavior.
- **Stamp site = the post-flush, post-Clamp seam inside
  `Processor.materialize_for_delivery/2`.** This is NOT "end of transform
  execution": `PlanExecutor.execute/3` returns *before* the delivery-backstop
  orientation flush (which lives in `Processor.materialize_for_delivery/2`, called
  from both the processor and producer paths), and on the production path
  `Clamp.clamp` runs between transform output and that flush. Stamping in
  `PlanExecutor` would stamp a lazy pre-rotate node and reintroduce the
  "does the custom field survive `autorotate`/`rotate`/`flip`?" hazard. So stamp
  inside `materialize_for_delivery` (the one shared point guaranteed post-flush +
  post-Clamp on both paths), reading the carry off the `State` it already threads,
  writing two private fields onto the now-realized image: `imagepipe-icc-backup`
  (`VipsBlob`) and `imagepipe-icc-imported` (`gint`). This is Request-boundary code
  (it already manipulates the image via Clamp/materialize), so it is boundary-legal
  — and it must never live in `Output`. (Field names distinct from imgproxy's literal
  `imgproxy-icc-imported` to avoid collision if an imgproxy-processed source is
  re-ingested.)

"Imported" is the recorded flag, **never** "backup present" — matching imgproxy's
`ColourProfileImported()` (the `imgproxy-icc-imported` marker set only on the
import success path). The encoder reads the two private fields, uses them, and
removes them (§4).

### 4. Encoder finalize: colorspace-to-result (port of `colorspaceToResult`)

The policy is threaded **into `Resolved`** (via `Output.Policy`), because the
encoder reads `Resolved`, not `Plan.Output`. `Output.Policy` and `Output.Resolved`
replace their `strip_color_profile` boolean with the `color_profile` policy.

```
keep_profile = (color_profile == :preserve_source) and format_supports_color_profile?(format)
imported     = imagepipe-icc-imported field present on image
```

`format_supports_color_profile?/1` (mirrors `Format.SupportsColourProfile()`) lives
in **`Output.*` / `Format`** — on the far side of the transform→output boundary
from the §1 chooser; the two **cannot** share a module (verified: `transform` deps
exclude `output`; `output` deps include `format`).

**The existing `finalize/2` short-circuit must change.** Today
`%Resolved{strip_metadata: false, strip_color_profile: false} -> {:ok, image}`
(no-op). Under the new model `:preserve_source` + `imported` must **re-embed** even
with no metadata strip, so that early-return clause is no longer "do nothing" and
folds into the state machine below.

**Exact finalize sequencing** (load-bearing — `minimize_metadata`
enumerate-removes *every* header field, including our private ones; verified):

1. **Realize once** via `VixImage.copy_memory/1` in the producer call stack
   (existing behavior), mapping failure to `{:decode, _}` → 415. All subsequent
   color work runs on the in-RAM image so it cannot trip the uncatchable
   linked-`MutableImage` crash path.
2. **Read** `imagepipe-icc-backup` + `imagepipe-icc-imported` from the realized
   image.
3. **Restore** the backed-up source profile to `icc-profile-data` unconditionally
   (harmless when absent), mirroring `RestoreColourProfile`-before-switch. Needed
   because `icc_export` has **no blob target** — it exports to the image's
   *embedded* profile, so the source blob must be on `icc-profile-data` first.
4. **Switch** on `(keep_profile, imported)`:

   | keep_profile | imported | action |
   |---|---|---|
   | true  | true  | `icc_export` (PCS → restored source profile); **PCS re-sniffed from the restored profile** (same blob as import → matches), **depth from interpretation** (`image_depth` rule: 8 for in-scope formats today) |
   | true  | false | keep as-is (already standard, nothing to export) |
   | false | true  | already standard → no transform |
   | false | false | `icc_transform` → standard (`sRGB`/`sGrey` per interpretation) |

   The export and transform-to-standard ops carry their own embedded/sRGB no-op
   short-circuits, mirroring upstream (note: export's sRGB skip is *not* gated on
   `interpretation == sRGB`, unlike the import/transform gates). **Common untagged
   path:** `:strip` (keep_profile false) + an untagged/already-sRGB input +
   `strip_metadata: false` must stay pixel-identical to today — the `!keep &&
   !imported` `icc_transform` is a no-op here (already sRGB), so only an absent-ICC
   header removal happens, exactly matching the old scp-only finalize clause. Verify
   the short-circuit fires for untagged inputs so the common path doesn't gain a
   spurious transform.
5. If `!keep_profile`: remove `icc-profile-data`.
6. **Then** the encoder strips other metadata (the existing EXIF/XMP/IPTC /
   `keep_copyright` path) and removes the two private fields itself. Ordering
   guarantees the strip never destroys backup/marker before steps 2–5 use them.

Every new `icc_export` / `icc_transform` / `mutate` in finalize runs **after** the
step-1 realization and must **return** `{:decode, _}` on failure rather than the
current `{:ok, _} = VixImage.mutate(...)` hard match — the hard match is acceptable
only on paths doing no color work; the re-embed path must be wrapped.

### 5. Trim ordering

Because the preamble conditions input before all operations and is idempotent,
trim's border detection inherits working-space pixels — pixel-equivalent to
imgproxy calling `colorspaceToProcessing` inside `vips_trim`. Removes the trim
detection-colorspace divergence.

Two notes on the interaction with ImagePipe's `Trim` op (`trim.ex`), which does
its **own** sRGB convert for detection:
- For **sRGB-working-space** sources (the common case post-preamble), `Trim`'s
  internal `to_srgb` is a guaranteed no-op (interpretation already sRGB).
- For **greyscale** sources the preamble leaves working space as **B_W**, and
  `Trim` then converts B_W→sRGB **for detection** — which still matches imgproxy
  (`vips_trim` detects in sRGB regardless). So "trim sees working-space pixels" is
  precise about *gamut/profile* (the source ICC is imported before trim); trim's
  detection-space sRGB standardization is unchanged and parity-correct.

### 6. Retiring `NormalizeColorProfile` — change checklist

Both structs are deleted (greenfield, no back-compat). This is a principled
re-split (input conditioning → preamble; output handling → policy + finalize), a
**deliberate deviation** from #124's "extend or compose … rather than replacing"
wording — the op's conflation of "convert to sRGB" + "strip" + scp-gating is
exactly what the re-split removes. Sites (all verified present):

- `lib/image_pipe/plan/operation/normalize_color_profile.ex` — delete.
- `lib/image_pipe/transform/operation/normalize_color_profile.ex` — delete.
- `lib/image_pipe/plan.ex` — remove `Operation.NormalizeColorProfile` boundary export.
- `lib/image_pipe/transform.ex` — remove `Operation.NormalizeColorProfile` boundary export.
- `lib/image_pipe/plan/operation.ex` — alias, `@type` union member,
  `normalize_color_profile/0` constructor, `semantic?/1` clause.
- `lib/image_pipe/plan/key_data.ex` — the `data(%NormalizeColorProfile{})` clause + alias.
- `lib/image_pipe/transform/plan_executor.ex` — both aliases + the
  `executable_operations` clause; add preamble seeding in `execute/3` instead.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — drop `color_profile_operations`
  from the pipeline order; set `Plan.Output.color_profile` in **both** `output_plan`
  clauses (format-nil and explicit-format).
- `lib/image_pipe/output/encoder.ex` — the `finalize/2` no-op short-circuit (§4)
  and the colorspace-to-result rewrite.
- `test/image_pipe/architecture_boundary_test.exs` — remove `:NormalizeColorProfile`
  from `@concrete_plan_names`, `@concrete_transform_names`, and the Plan/Transform
  `assert_boundary_exports*` lists (the one sanctioned source-scanning test).

## Project rule (lands in CLAUDE.md / AGENTS.md Transform guidelines with this change)

> **Distinguish discretionary operations from input conditioning.** A concern
> that is (a) not a user-requested transform and (b) whose behavior is sourced
> entirely from runtime image inspection — the decoded image's own
> headers/interpretation/bytes, which *no operation struct can see* — is **not** a
> `Plan.Operation`. Model it as fixed pipeline preamble or self-managing `State`,
> the way decode access mode, shrink-on-load planning, EXIF auto-orient
> (`pending_orientation`), and input color-management (working-space import)
> already are. Its materialization need is governed by the same sequential-safety
> gate as any operation — prove it, don't assert it. The declarative knob a parser
> *does* control (e.g. the output color-profile policy) belongs on the relevant
> `Plan` struct (`Plan.Output`), not as a synthetic operation.

EXIF auto-orient and input color management are the two worked examples.

## Cache key & ETag

The resolved `color_profile` policy composes into the canonical plan, so it lands
in **both** the cache key and the ETag (the ETag is derived from
`Key.plan_material` minus `[:cache]`, so plan material threads both). It changes
stored bytes, so this is correct per the cache guidelines; it is **not** a safety
limit and stays out of generation gates. cachebuster/vary remain excluded,
preserving the 304-before-fetch fast path.

The boolean appears in **three** emission branches in `cache/key.ex`
(`output_plan_data/2` automatic line ~114 + explicit ~127, and `output_data/3`
conn-aware automatic ~148) — all three move to the policy. (The dead
`KeyData.data(%NormalizeColorProfile{})` clause lives in `plan/key_data.ex`, not
`cache/key.ex`, and is already in the §6 checklist.) Greenfield: reshape in place,
no key-version bump. `supports_hdr?` is constant `false` today so
contributes nothing to the key yet (#121 adds it when variable).

## Telemetry

The preamble emits a dedicated **stage span** `[:transform, :input_color_management]`
(like decode), not a `[:transform, :operation]` span. Metadata may carry the chosen
working space and a profile-imported boolean (product-neutral, non-sensitive).
Logger sync (all five checklist parts):

- **Subscription:** add `[:transform, :input_color_management]` to
  `@group_span_events` under the `transform` group (`PlanExecutor` seeds it at
  execute start).
- **Rendering:** a `message/3` clause that still surfaces the outcome.
- **Levels:** if the preamble or finalize re-embed emits a degraded/fallback
  outcome, extend `level_for/3` to escalate to `:warning` (like `materialize_error`).
- **Coverage:** add the `logger_test.exs` assertion.
- **Docs:** update `docs/telemetry.md`.

## Testing

- **Preamble-specific sequential-safety harness (new, required).** The existing
  `sequential_access_test.exs` gate is *per-op* and runs ops through
  `Chain.execute`; the preamble runs eagerly in `execute/3`. Add a
  preamble-specific harness: apply the preamble on a genuinely streamed open
  (`access: :sequential`, `fail_on: :error`), then a downstream `copy_memory`,
  comparing against a random open, **with** the known-random transpose self-check,
  over wide-gamut + CMYK + Grey16 + **16-bit-with-alpha** fixtures (the band
  split/rejoin path). **Also** run a variant with a quarter-turn orientation flush
  after the preamble (the flush's `copy_memory` is the first realization of the
  lazy color node) to prove they compose. Proves correctness, not the memory win.
- **Carry survival through the flush.** A test for a `scp:0` wide-gamut source with
  EXIF orientation 6 + user rotate: the source profile is re-embedded correctly
  after the orientation flush. (With the State-carry + boundary-stamp design this
  is guaranteed; the test pins it.)
- **Differential conformance:** `scp0_colorspace_124.png` fixture becomes a gate;
  wide-gamut + tone effect, `scp:0` output matches imgproxy.
- **No-geometry / resize-only `scp:0` (required by Test guidelines).** The Risks
  behavioral change (round-trip + gamut clip fires even with no tone effect)
  demands an explicit resize-only **and** a no-geometry `scp:0` wide-gamut
  pixel-decode test vs today's untouched-source baseline.
- **Default unchanged:** `scp:1` identical to today.
- **Trim parity:** wide-gamut + `trim`, detected box matches imgproxy; greyscale +
  `trim` path covered (B_W working space, sRGB detection).
- **Finalize ordering:** re-embed happens before the metadata strip (the private
  fields are consumed, not destroyed) — incl. the `strip_metadata: false` +
  `:preserve_source` case the old short-circuit skipped.
- **Wire-level:** decode the response body and inspect embedded ICC via
  vix/`Image` metadata (not headers) for `scp:0` vs `scp:1`; `scp` option-order
  equivalence; cache reuse for equivalent requests; finalize decode-error mapping
  on a corrupt source.
- **Cache key/ETag:** `:preserve_source` vs `:strip` differ in both; cachebuster/
  vary unaffected.
- **Edge cases:** CMYK `scp:0` re-embed gated by `format_supports_color_profile?`;
  linear-light source drops + does not re-embed but still converts.

### Test migration (delete vs retarget)

- `test/parser/imgproxy_test.exs` — the `NormalizeColorProfile` order-position
  assertions + `operation_name(%NormalizeColorProfile{})` helper (~line 122, 1828):
  **delete** (post-migration parity pin); replace with a parser test that `scp`
  sets `Plan.Output.color_profile` (not an op).
- `test/image_pipe/plan/operation_key_data_test.exs` — `%NormalizeColorProfile{}`
  key-data assertions: **delete** (producer gone).
- `test/image_pipe/transform/sequential_access_test.exs` — the
  `%NormalizeColorProfile{}` op case: replaced by the new preamble harness.
- `test/image_pipe/transform/prefetch_validation_test.exs` — references the
  **Plan** op (`Plan.Operation.NormalizeColorProfile`): drop it from the operation
  list; replacement uses whatever the planner now emits.
- `test/image_pipe/decode_planner_test.exs` (note: under `test/image_pipe/`, **not**
  `transform/`; refs ~lines 29, 37) — drop the op from its operation lists.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` (~1894–1910) — the `scp:1`
  output-colorspace assertion: **retarget** to the new finalize (`scp:1 → :strip →
  sRGB` holds); fix the rationale comment.
- `test/support/image_pipe/test/imgproxy_differential/constellations.ex` (~165) —
  the `diverge("scp0_colorspace_124", :icc_p3, "rs:fit:200:200/scp:0", … issue:
  "#124")` entry asserts the divergence **still holds** (a floor), so intended
  convergence makes it fail. **Flip** it from `diverge(...)` to an `:equal`/`c(...)`
  case and drop the `#124` floor; this reauthors the differential authored-hash, so
  regenerate fixtures/manifest in the same change. (No `NormalizeColorProfile`
  token → escapes the grep checklist; named explicitly here.)
- `test/image_pipe/architecture_boundary_test.exs` — see §6.

## Docs & demo

Axes touched: **surface** + **stage/order** + **behavioral/pixel**.

- `docs/imgproxy_support_matrix.md`:
  - **stage/order + behavioral/pixel:** rewrite stage 4 (`colorspaceToProcessing`,
    line ~82) and stage 16 (`colorspaceToResult`, ~101) from ⚠️ to ✅; flip the
    Mermaid nodes (~47, ~54); remove the trim detection-colorspace divergence note
    (trim row ~80); update the "standing divergence" prose (~124).
  - **surface:** update **both** `scp` option-table rows (~465 and ~769) — the
    "Implemented as a `NormalizeColorProfile` operation … positioned after geometry
    … Diverges" text is now wrong; and the stage-17 `stripMetadata` note (~102) and
    the "Metadata, color profile, …" prose (~443).
  - **differential `:diverges` entry (~146):** the differential-conformance group
    currently asserts the colorspace-#124 + trim-detection divergences **still
    hold** (so accidental convergence fails). #124 *intentionally* converges these,
    so this entry must move out of `:diverges` (it would otherwise fail on the
    intended convergence). Reconcile with the differential test in the same change.
- `fiddle/`: the `scp` control already exists end-to-end (`App.svelte`,
  `demo-url-state.ts`); URL surface unchanged → **verify-only**, no new control.
- `docs/telemetry.md`: the new preamble stage span.

## Risks & accepted divergences

- **8-bit sRGB round-trip clips gamut.** For `scp:0` wide-gamut sources the
  import→working→export round-trip runs even with no tone effect (resize-only),
  and 8-bit sRGB clips out-of-sRGB-gamut colors + adds quantization. **Accepted** —
  matches imgproxy exactly; deliberate behavioral change from today (covered by the
  no-geometry test).
- **CMYK `scp:0` → profile-supporting format** re-embeds the CMYK profile,
  mirroring imgproxy + the format gate.

## De-risk-early (feasibility), confirmed implementable

The two-round review confirmed every API claim against this tree; pin these early
in TDD:
1. **`icc_export` has no blob target** — only path is restore-source-blob-into-
   `icc-profile-data`-then-export-embedded (§4 step 3). Pin with the wire
   ICC-equivalence test first.
2. **`minimize_metadata` destroys the private fields** (verified) — the finalize
   read-before-strip order is mandatory; focused finalize-ordering test.
3. **PCS/depth precision** — re-sniff PCS from the restored profile on export
   (same blob → matches import); depth from `image_depth(interpretation)`, since
   `icc_import` has no depth knob.

## #121 / #119 follow-ups

- When #124 lands, update **#121**'s body to point at the `supports_hdr?` seam in
  the chooser (the flag to flip + the RGB16/Grey16/other rows).
- #119 builds on the finalize state machine via the `{:convert, target}` policy
  value + its profile-identifier validation/security surface; `target` stays a
  product-neutral reference.
