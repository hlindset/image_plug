# Design: `preserve_hdr` / `ph` HDR preservation (imgproxy compat)

Issue: [#121](https://github.com/hlindset/image_plug/issues/121) — deferred from #30.
Type: `type:design`. Target: imgproxy compatibility.

## Problem

imgproxy's `preserve_hdr` (`ph`) keeps HDR data (high-bit-depth / wide-gamut)
through processing instead of tone-mapping it to 8-bit SDR. ImagePipe does not
model an HDR-preservation policy today, so the outcome depends on libvips
decode/encode defaults. We need to:

1. detect/represent HDR through decode → transform → encode,
2. add a product-neutral HDR-policy field to `ImagePipe.Plan.Output` (SDR
   tone-map is the conservative default),
3. define per-format fallback for formats that cannot carry HDR.

## Upstream ground truth (imgproxy v4.1.1, `/Users/hlindset/src/imgproxy`)

`preserve_hdr` is consumed in exactly one place: the `colorspaceToProcessing`
stage, at the **start** of the per-frame pipeline, before any geometry
(`processing/colorspace_to_processing.go`):

```go
supportsHDR := c.PO.Format().SupportsHDR() && c.PO.PreserveHDR()
cs := guessTargetColorspace(c.Img, supportsHDR)
... c.Img.Colorspace(cs)
```

`guessTargetColorspace` chooses the **working colorspace**: a 16-bit source
(`RGB16` / `GREY16`, or an unknown interpretation) is kept 16-bit when
`supportsHDR`, otherwise collapsed to 8-bit `sRGB` / `B_W`. 8-bit `RGB`/`sRGB`/
`B_W` and `CMYK` ignore the flag. So `preserve_hdr` is fundamentally a
**working-colorspace / bit-depth decision made before processing**, gated on the
output format's HDR capability. The finalize stage (`colorspaceToResult`) is
ICC-only and never touches bit depth.

`Format().SupportsHDR()` per `imagetype/defs.go`, restricted to ImagePipe's four
output formats:

| Output format | imgproxy `SupportsHDR` |
| --- | --- |
| AVIF | ✅ true |
| PNG  | ✅ true (16-bit PNG) |
| WebP | ❌ false (8-bit only) |
| JPEG | ❌ false |

Critically, imgproxy resolves the output format **before** processing
(`processing/processing.go` `ProcessImage`: `determineOutputFormat` at the call
site precedes `transformImage`), predicting transparency from the *source*:

```go
expectTransparency := !po.ShouldFlatten() &&
    (img.HasAlpha() || po.PaddingEnabled() || po.ExtendEnabled())
```

So by the time `colorspaceToProcessing` runs, `Format()` is definitive.

## What already exists in ImagePipe (the #121 seam)

The hard part is already ported as a deliberate seam:

- `ImagePipe.Transform.InputColorManagement.working_space/2`
  (`lib/image_pipe/transform/input_color_management.ex:181`) is a faithful port
  of `guessTargetColorspace`, **including** the HDR branches:
  `RGB16/true → RGB16`, `RGB16/false → sRGB`, `GREY16/true → GREY16`,
  `GREY16/false → B_W`, `other/true → RGB16`, `other/false → sRGB`.
- `InputColorManagement.condition/2` already accepts `supports_hdr?`.
- The call site (`lib/image_pipe/transform/plan_executor.ex:98,100`) hardwires
  `false`; the moduledoc names this "the #121 seam".

So #121 is principally **wiring a resolved `supports_hdr?` boolean through to the
seam**, plus the parser surface, docs, demo, and tests. No new color math.

## Decisions

1. **Field shape** — `ImagePipe.Plan.Output` gets `hdr: :tone_map | :preserve`,
   default `:tone_map`. A semantic atom enum (not a bare boolean), mirroring the
   existing `color_profile: :strip | :preserve_source | {:convert, _}` style on
   the same struct and leaving room for future policies. Like the other output
   fields it is a *resolved* value (never `nil`) by plan-construction time.

2. **Residual ambiguity → conservative tone-map.** ImagePipe resolves the output
   format **after** the transform (negotiation can depend on the processed
   image's alpha, `producer.ex` → `Policy.resolve_final_image_alpha`). Reading
   `Output.Policy.resolve/2`, the format is in fact knowable *before* the
   transform in every case **except one**: `:source` (automatic) mode + the
   client accepts no modern format + the source is itself a modern format
   (`:needs_final_image_alpha`, resolving to PNG-if-alpha / JPEG-if-not). In that
   one branch we treat `supports_hdr?` as **false** (tone-map). This is always
   *correct* (8-bit working space → 8-bit output); it only forgoes preserving HDR
   for an HDR source requested in automatic mode by a client that accepts no
   modern format and resolves to a PNG fallback — a deep corner where the client
   already signaled it wants legacy formats. Documented as a deliberate
   divergence. Rejected the alternative (mirror imgproxy's pre-transform
   transparency prediction) because it re-introduces a second, less-accurate
   notion of "the output format" alongside ImagePipe's deliberate post-transform
   measurement, and only preserves HDR when prediction and served format both
   land on PNG. Per repo validation guidelines, the prediction can be added later
   *with a test* if a real caller needs it.

## Design

### 1. `ImagePipe.Plan.Output` — new field

`lib/image_pipe/plan/output.ex`:

- add `hdr: :tone_map` to the struct defaults,
- add `@type hdr :: :tone_map | :preserve` and `hdr: hdr()` to `@type t`,
- extend the moduledoc's "resolved values" note to include `hdr`.

### 2. `ImagePipe.Format` — HDR capability

`lib/image_pipe/format.ex`: add `supports_hdr?/1` mirroring
`supports_color_profile?/1`, backed by a module attribute:

```elixir
@hdr_formats [:avif, :png]
@spec supports_hdr?(output_format()) :: boolean()
def supports_hdr?(format), do: format in @hdr_formats
```

This is the single source of truth for the per-format fallback; it matches
imgproxy's `SupportsHDR` for the four output formats.

### 3. imgproxy parser surface

Upstream, `ph`/`preserve_hdr` is a **per-request URL boolean** that overrides the
`IMGPROXY_PRESERVE_HDR` config default in **both** directions — `PreserveHDR()`
is `po.Main().GetBool(keys.PreserveHDR, config.PreserveHDR)`: the URL value if
present, else the config default (pinned by upstream
`TestPreserveHDROptionOverride`, `processing/colorspace_test.go`). (`o.Main()` in
the parser is the main-options *namespace* the value is parsed into, not a
config-only accessor.) So it follows the `strip_metadata` / `keep_copyright`
pattern: a per-request boolean resolved against a host-config default. We route
it to the **`:output`** scope because its *effect* is gated on the output format,
not because it is config-only. (It does **not** follow the
`strip_color_profile` pattern — that one is pipeline-scoped with a `*_requested`
flag; `ph` has no such per-pipeline semantics.)

- `lib/image_pipe/parser/imgproxy/option_grammar.ex`: add
  `"preserve_hdr"`/`"ph"` → `{:preserve_hdr, [:preserve_hdr]}` to `@option_specs`;
  add `:preserve_hdr` to the **existing** generic `parse_known_option` head's
  `kind in [...]` list (which routes to `parse_exact_fields`); add a
  `parse_field(:preserve_hdr, value), do: parse_boolean(value)` clause; and route
  `:preserve_hdr` to the `:output` scope in `scoped_assignments/2`. (No bespoke
  new `parse_known_option` clause — mirror `strip_metadata` exactly.)
- `lib/image_pipe/parser/imgproxy/parsed_request.ex`: add `preserve_hdr: nil` to
  `@default_output` and `required(:preserve_hdr) => boolean() | nil` to
  `output_request()`.
- `lib/image_pipe/parser/imgproxy/options.ex`: in `apply_request_defaults/2`
  resolve `preserve_hdr` via `resolve_bool(output.preserve_hdr,
  Keyword.get(defaults, :preserve_hdr, false))` (analogous to
  `resolve_metadata_defaults/2`); default `false`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex`: in `output_plan/1` set
  `hdr: if(request.preserve_hdr, do: :preserve, else: :tone_map)` on the `Output`
  struct (both clauses). The parser's resolved boolean is translated into the
  product-neutral atom here, at the parser→plan boundary.
- `lib/image_pipe/parser/imgproxy.ex`: add
  `preserve_hdr: [type: :boolean, default: false]` to `@imgproxy_schema` and
  `preserve_hdr: Keyword.get(imgproxy_opts, :preserve_hdr, false)` to
  `request_defaults/1` (mirrors `IMGPROXY_PRESERVE_HDR`, default off).

### 4. Resolving `supports_hdr?` and threading it to the seam

The boolean is computed in the Request/Output boundary (which may depend on
`Output`) and passed as a **plain boolean** through `opts` into the Transform
boundary — keeping Transform free of any `Output` dependency.

- New helper in the `Output` boundary, e.g.
  `ImagePipe.Output.Policy.supports_hdr?(policy, output, source_format, opts)`
  (or a small dedicated function), returning:
  - `output.hdr == :preserve` **and**
  - the pre-transform format is HDR-capable, determined from `Policy.resolve/2`:
    - `{:ok, %Resolved{format: f}}` → `Format.supports_hdr?(f)`,
    - `{:needs_final_image_alpha, _}` → `false` (decision 2),
    - `{:error, _}` → `false`.
- `lib/image_pipe/request/source_session/producer.ex` `prepare_first_chunk/1`:
  compute the boolean from `request.output_policy`, `request.plan.output`, and
  `decoded.source_format`, and thread it into the transform call:
  `Processor.process_decoded_source(decoded, request.plan,
  Keyword.put(request.opts, :supports_hdr?, hdr?))`. `request.plan` and
  `request.output_policy` are both already in scope here.
- `lib/image_pipe/request/processor.ex`: `process_decoded_source/3` already
  forwards `opts` into `execute_transform_plan/3` →
  `Transform.execute_plan(plan, state, [seed_orientation: true | opts])`. No new
  parameter; the boolean rides `opts`. The test-only `process_source/3` path and
  bare `process_decoded_source` test callers simply omit the key (default
  `false`), which is correct for them.
- `lib/image_pipe/transform/plan_executor.ex`: in `run_color_management/1` read
  `hdr? = Keyword.get(opts, :supports_hdr?, false)` and use it for **both** the
  telemetry `working_space` computation and `condition(state, supports_hdr?:
  hdr?)`. (`seed_color_management/2` must pass `opts` down to
  `run_color_management`.) This replaces the two hardwired `false` literals.

Telemetry (firm decision): the `[:transform, :input_color_management]` span
already reports `working_space` and the default Logger already renders it
(`logger.ex` `message/3`, event already subscribed under `@group_span_events`).
With the flag wired, that value will now observably render `RGB16`/`GREY16` for
preserved HDR — a rendered-output change. We will **not** add a new metadata key
(keep the change minimal; the working-space value already conveys the outcome).
Per the telemetry sync rule, even with no new key this observable change still
requires: a `logger_test.exs` assertion that `working_space` renders the HDR
interpretation for a preserved request, and an aligned note in
`docs/telemetry.md`. No new Logger subscription is needed (the event is already
listed).

### 5. Encoder / finalize — no functional change

imgproxy's `colorspaceToResult` is ICC-only; bit depth was fixed at the
processing stage. ImagePipe's `Output.Encoder` (`color_result`) likewise need not
change: when the working space is kept `RGB16`/`GREY16`, the image reaching the
encoder is already high-bit-depth, and libvips `pngsave`/`heifsave` emit >8-bit
from a USHORT image. `Output.Resolved` / `Output.Policy` do **not** gain an `hdr`
field — the encoder makes no HDR decision. This is asserted by the
request-boundary test (§Testing 3), which is the real verification that the
encoders carry the bit depth through.

### 6. Cache key + ETag — `hdr` must partition both

`hdr` changes the output bytes (16-bit vs 8-bit), so it MUST be part of the cache
key and the ETag. Neither picks it up automatically:
`ImagePipe.Cache.Key.output_plan_data/2` (`lib/image_pipe/cache/key.ex`, both
clauses) builds the output portion of the key from an **explicit field list**
(`mode`, `format`/`auto`, `quality`, `format_qualities`, `strip_metadata`,
`color_profile`, `keep_copyright`) — it reads named fields, it does not splat the
struct. Without an edit, `ph:1` and `ph:0` (same `format:png`) would produce the
**same key and same ETag** and alias a preserved 16-bit PNG to a tone-mapped
8-bit one — a correctness bug, not just an efficiency one.

- Add `hdr: output.hdr` to **both** `output_plan_data/2` clauses.
- This flows to the ETag for free: `Request.HttpCache.etag_material/4` derives
  the ETag from `Key.plan_material/2` (which calls `output_plan_data`), dropping
  only the cachebuster. That is correct — `hdr` is a real byte-identity input and
  belongs in the strong validator (a `ph:1` conditional GET must not 304 against
  a cached `ph:0` body). The key/ETag see the **requested** policy
  (`:preserve | :tone_map`), never the realized `supports_hdr?` boolean, so they
  stay computable pre-fetch; the realized outcome is deterministic given the same
  source bytes (already in the source identity seed).
- Per the greenfield cache guideline, **do not** bump `@schema_version` /
  `@transform_key_data_version` — reshape the key data and update the
  `cache/key.ex` tests in place.

### Per-format fallback (falls out of `working_space/2` + `supports_hdr?/1`)

| Output | `ph:1` effect on a 16-bit source |
| --- | --- |
| AVIF | preserved — working space stays `RGB16`/`GREY16`, encoded high-bit-depth |
| PNG  | preserved — 16-bit PNG |
| WebP | tone-mapped to 8-bit sRGB/B_W (`supports_hdr?` false) |
| JPEG | tone-mapped to 8-bit sRGB/B_W (`supports_hdr?` false) |

No explicit per-format branching is needed: a non-HDR format yields
`supports_hdr? == false`, so `working_space/2` collapses to 8-bit. `ph:1` is a
silent no-op for 8-bit sources regardless of format (matches imgproxy).

## Boundary impact

- `parser` → `plan`: unchanged (still only emits `Plan.Output`).
- `request` → `output`: already allowed; the new `supports_hdr?` helper call
  lives here.
- `transform`: receives a plain boolean via `opts`; **no** new dependency on
  `output`/`plan` beyond what `execute_plan` already takes. No concrete-module
  references added. Architecture tests should continue to pass unchanged.
- `cache` → `plan`: unchanged direction; `output_plan_data/2` already reads
  `Plan.Output` fields, so adding `hdr` is within the existing dep.

## Documentation (`docs/imgproxy_support_matrix.md`)

This change touches all three conformance axes; update each:

- **surface**: change the `preserve_hdr` / `ph` option row (line ~778) from
  Missing → Supported, and the `IMGPROXY_PRESERVE_HDR` config bullet (line ~475)
  from ⭕ to supported, noting default off.
- **stage/order**: extend the stage-4 `colorspaceToProcessing` row (line 82) to
  note that the working-space chooser now consumes the resolved HDR policy
  (`Format.supports_hdr?` ∧ `Plan.Output.hdr == :preserve`); previously hardwired
  SDR.
- **behavioral/pixel + Diverges**: write the **per-format fallback table**
  (§Per-format fallback) into the matrix *body* (near the stage-4 notes or a
  Diverges subsection) — it must have a home in the doc, not only in this spec.
  Document the decision-2 divergence (the automatic + non-modern-Accept +
  modern-source PNG fallback conservatively tone-maps rather than predicting
  transparency imgproxy-style), and note that for all other cases `supports_hdr?`
  is resolved pre-transform and matches imgproxy. Two upstream nuances to state
  honestly so the divergence note is correctly scoped:
  - In automatic mode imgproxy's chosen format (hence `SupportsHDR()`) can also
    be **AVIF** (HDR ✅) via `PreferAvif`/preferred-formats, not only the
    PNG/JPEG transparency fork; the conservative-tone-map divergence only bites
    the specific `:needs_final_image_alpha` PNG-fallback branch.
  - Upstream `saveImage` has an **AVIF < 16px → PNG/JPEG** fallback that runs
    *after* `colorspaceToProcessing` already fixed the (HDR) working space, so
    imgproxy itself can process 16-bit then save 8-bit in that corner. One-line
    note only; no code parity needed.

Keep the conformance doc updated in the same change (per the compatibility-doc
rule), and have the compatibility reviewer confirm it against upstream.

## Demo (`fiddle/`)

The fiddle is **bidirectional** (emit URL + reverse-parse URL on load) and has
**two** independent segment builders. All four touch points are required or the
toggle won't round-trip:

- `fiddle/assets/processing-path.ts`: add `preserveHdr: boolean` to the demo
  state type and `defaultDemoState` (`false`); emit `ph:1` from `optionSegments`
  **only when enabled** (default off ⇒ no segment).
- `fiddle/assets/App.svelte`: add a "Preserve HDR (ph)" switch in the
  "Metadata & color" section, following the `Strip color profile (scp)` switch
  pattern; AND add the `if (preserveHdr) push("ph:1")` branch to the **separate**
  `metadataSegments(currentState)` builder defined inside `App.svelte` that drives
  `metadataSummary` (it duplicates the scp/sm/kcr logic independently of
  `processing-path.ts`). Both builders need the branch — one feeds the URL, the
  other the drawer summary.
- `fiddle/assets/demo-url-state.ts`: add a `case "ph":` route plus a
  `parsePreserveHdr/2` setter mirroring `parseStripColorProfile`, so a shared
  `…/ph:1/…` URL re-parses with the switch on (otherwise the round-trip drops it).
- `fiddle/assets/processing-path.test.ts`: add a `ph:1` round-trip + emit test
  mirroring the existing `sm:0` round-trip test.

## Testing

Per the test guidelines (boundary-focused; no impossible-misuse / name-policing):

1. **Parser/planner** (`test/parser/imgproxy/` — e.g. `options_test.exs`,
   `plan_builder_test.exs`, and `test/parser/imgproxy_test.exs` for host-config):
   `ph:1` / `preserve_hdr:1` and the off/absent cases parse and translate to
   `Plan.Output{hdr: :preserve | :tone_map}`; option-order-insensitivity holds;
   invalid boolean rejected. Include the **override-both-directions** case
   matching upstream `TestPreserveHDROptionOverride`: host-config
   `preserve_hdr: true` + URL `ph:0` → `:tone_map`, and host-config `false` +
   `ph:1` → `:preserve` (mirror the existing `imgproxy: [strip_metadata: false]`
   pattern at `test/parser/imgproxy_test.exs`). The automatic/explicit Output
   parity property in `plan_builder_test.exs` (`Map.drop(_, [:mode])` equality)
   exercises the new field for free — no separate parity pin needed.
2. **`working_space/2`** already covers `RGB16 stays RGB16` / `GREY16 stays
   GREY16` for `supports_hdr?: true` (`input_color_management_test.exs`). No new
   cases unless a gap is found; do not duplicate the existing ones.
3. **Request-boundary pixel test** (the AC's headline): using the existing
   genuine-16-bit `rgb16.png` / `rgba16.png` fixtures, make real
   `ImagePipe.call/2` requests and compare **preserved vs tone-mapped** by reading
   the decoded body's `Vix.Vips.Image.header_value(img, "format")`:
   - explicit `format:png` (and/or `format:avif`) with `ph:1` → `:VIPS_FORMAT_USHORT`;
   - **the tone-map baseline must be the same request with `ph:0`** (driving the
     pipeline's own `working_space/2` colourspace collapse) → `:VIPS_FORMAT_UCHAR`.
     Do **not** build the baseline by hand-casting to UCHAR — libvips re-promotes
     on `pngsave`, so a cast baseline passes for the wrong reason;
   - explicit `format:jpeg` (or `webp`) with `ph:1` → still `UCHAR` (per-format
     fallback);
   - include a no-geometry form (HDR policy must work without resize/crop).
   Decode with `Image.open!(body, access: :random, fail_on: :error)`; this is pure
   libvips header inspection — **no** `:image_vision`/Nx dependency, so it runs in
   the default lane.
4. **Cache key** (`test/.../cache/key_test.exs`): `ph:1` and `ph:0` for the same
   otherwise-identical request produce **different** keys (and, via
   `etag_material`, different ETags); assert in place, no schema-version bump.
5. **Conformance** (`imgproxy_wire_conformance_test.exs`): a compact
   representative case for `ph` if it fits the existing matrix discipline
   (status/headers/decoded-format), kept minimal.

A request-boundary test exercising the residual divergence branch is optional
(deep corner); if added, assert the documented conservative-tone-map behavior so
the divergence is pinned intentionally.

## Interaction with #119 (cp / icc), in flight

#119 also adds a field to `ImagePipe.Plan.Output`, and touches the support
matrix, the imgproxy parser option table, and the fiddle metadata controls. The
two are **orthogonal** in behavior (imgproxy: `PreserveHDR` drives
`colorspaceToProcessing` working space; `StripColorProfile` drives
`colorspaceToResult` ICC). Expect a small **additive** rebase on whichever PR
lands second: a second struct field, a second option row, a second parser
clause, a second fiddle switch — no semantic conflict. Whoever lands second
rebases and re-runs the gate.

## Out of scope / YAGNI

- No new HDR *source* decoding beyond what libvips already provides; `rad2float`
  for Radiance sources already exists in the preamble.
- No tone-mapping operator/curve choice — "tone-map" means libvips' existing
  colorspace collapse (matching today's default), not a new HDR→SDR algorithm.
- No imgproxy-style pre-transform transparency prediction (decision 2).
- No `Output.Resolved`/`Output.Policy` HDR field; the encoder makes no HDR
  decision.
- No memory/perf benchmark of 16-bit processing (consistent with the existing
  "materialization is correctness-verified, not perf-verified" stance).

## Acceptance criteria mapping

- Parser/planner tests for `preserve_hdr`/`ph` (incl. override-both-directions)
  → §Testing 1.
- Request-boundary test on an HDR fixture, preserved vs tone-mapped → §Testing 3.
- Documented default + per-format fallback → §Per-format fallback,
  §Documentation; default `:tone_map` / `ph:0`.
- Docs + demo controls → §Documentation, §Demo.
- Cache-key/ETag partition on HDR policy → §Design 6, §Testing 4.
