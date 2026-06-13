# IIIF Image API 3.0 — Parser, info.json, and Level 2 conformance (Phase 2)

**Issue:** [#253](https://github.com/hlindset/image_pipe/issues/253)
**Depends on:** [#252 / PR #260](https://github.com/hlindset/image_pipe/pull/260) — Phase 1 cross-dialect render mechanism (merged)
**Spawns follow-ups:** [#267](https://github.com/hlindset/image_pipe/issues/267) — customizable transform/processing error → HTTP status mapping; [#268](https://github.com/hlindset/image_pipe/issues/268) — flatten-to-background for explicit non-alpha output formats
**Status:** design approved; reviewed (two parallel cycles); ready for implementation-plan

## Goal

Implement `ImagePipe.Parser.IIIF` — IIIF Image API 3.0 targeting **Level 2 conformance** — as the second consumer of the Phase 1 render mechanism. Translate the IIIF positional image grammar `{prefix}/{identifier}/{region}/{size}/{rotation}/{quality}.{format}` into `ImagePipe.Plan`, serve a minimal `info.json` via the Phase 1 `Renderer`, and gate output correctness with the official Python IIIF `image-validator` at Level 2.

IIIF processing order **Region → Size → Rotation → Quality (→ Format)** matches the fixed native pipeline order; we emit operations in that list order and the transform `Chain` executes them in order.

`ImagePipe.Parser.Imgproxy` is the structural template throughout.

## Non-goals (deferred — all IIIF `extraFeatures`, optional at every level)

- Arbitrary-angle rotation, mirroring (`!n`), bitonal quality, and `jp2`/`gif`/`tif`/`pdf` output.
- The `fiddle/` demo UI for IIIF (Phase 3, #254). This consciously defers the `AGENTS.md` "keep the demo UI in sync" rule for the new `gray` op and the IIIF parser options; Phase 3 closes that gap.
- A source-string resolver (percent-decode → neutral path/URL/s3). Only the static-map resolver ships now.

---

## Architecture

A new parser mirroring `Parser.Imgproxy`'s sub-module decomposition, but with IIIF's **positional** grammar — segment *position* is the meaning, so there is no order-insensitivity concern (unlike imgproxy options).

```
lib/image_pipe/parser/iiif.ex                 # @behaviour Parser: parse/2, handle_error/2, validate_options!/1
lib/image_pipe/parser/iiif/
  path.ex            # split conn.path_info → endpoint kind + segments; reconstruct absolute base URI
  grammar.ex         # parse region / size / rotation / quality / format tokens → typed values
  parsed_request.ex  # intermediate struct (identifier, region, size, rotation, quality, format, endpoint)
  plan_builder.ex    # ParsedRequest → {:ok, Plan} | {:redirect, status, location} | {:error, _}
  resolver.ex        # @behaviour: resolve(identifier, opts) → {:ok, Plan.Source.t()} | {:error, _}
  resolver/static.ex # built-in static-map resolver
  info_renderer.ex   # @behaviour ImagePipe.Renderer: emits the IIIF info.json body
  info.ex            # builds the info.json document map (id, profile, sizes, extra* lists, max*)
```

The parser is selected per-mount, exactly like imgproxy:

```elixir
plug ImagePipe.Plug,
  parser: ImagePipe.Parser.IIIF,
  iiif: [
    resolver: {ImagePipe.Parser.IIIF.Resolver.Static, %{ "<identifier>" => %ImagePipe.Plan.Source.Path{...} }},
    auto_rotate: true,            # default true
    max_width: nil,              # optional info.json constraints
    max_height: nil,
    max_area: nil,
    formats: [:jpg, :png, :webp, :avif],
    qualities: [:default, :color, :gray]
  ]
```

It operates on `conn.path_info` (the post-mount remainder) and uses `conn.scheme`/`conn.host`/`conn.port`/`conn.script_name` to reconstruct the absolute base URI used for `id` and the canonical `Link` header.

---

## URL grammar → dispatch

The IIIF `{identifier}` is a **single** percent-encoded path segment; any `/` inside it must be `%2F`. After the mount prefix, `conn.path_info` has a fixed shape:

Matching is by **exact segment count** (so an unescaped-slash identifier like `a/b` deterministically misses every shape → 404, matching the validator's `id_error_unescaped`/`id_error_escapedslash` tests):

| `conn.path_info` | Outcome |
|---|---|
| `[id]` (1 segment) | **303 redirect** → `{base}/{id}/info.json` |
| `[id, "info.json"]` (2, last == `info.json`) | **info.json render** |
| `[id, region, size, rotation, quality_dot_format]` (4) | **image request** |
| any other shape | **404** |

`quality_dot_format` splits on the **last** `.` → `quality` + `format`.

The identifier is percent-decoded once and handed to the configured resolver (see below) to obtain a `Plan.Source`.

### Status mapping (the validator asserts specific codes; pin them all)

IIIF `handle_error/2` for this parser must return **400** for *every* malformed/unsupported-token parse failure, and **404** for identifier/shape misses — IIIF must **not** inherit imgproxy's 403 default for any of these. Full mapping (each row is a validator assertion):

| Case | Status | Where |
|---|---|---|
| Malformed region/size/rotation/quality/format **syntax** (`*_error_random`) | **400** | parse → `handle_error/2` |
| Valid-but-unsupported rotation (non-90, `!n`), quality, or format | **400** | parse → `handle_error/2` |
| Region `w=0`/`h=0`, or size literal-zero | **400** | parse → `handle_error/2` |
| Region wholly out of bounds; explicit-size upscale without `^` | **400** | runtime `{:bad_request, _}` (primitive 1) |
| Region partial overlap | **200** (clip) | runtime |
| Unknown identifier (resolver miss) | **404** | resolver `{:error, _}` |
| `path_info` shape mismatch (incl. unescaped-slash identifier) | **404** | dispatch |
| Unsupported format reaching decode/output | 400 (parse) — `[400, 415, 503]` all accepted by the validator | parse preferred |

---

## Region / Size / Rotation / Quality / Format mapping

Operations are emitted into a single pipeline in IIIF order (Region → Size → Rotation → Quality). Crop and resize are sequential-safe; the IIIF **rotation** folds into `pending_orientation` and is applied at the pipeline-end orientation flush (which self-materializes for quarter-turns) — *after* `gray`; `gray` is a sequential-safe point op that runs on the (possibly streamed) pre-rotation image (see primitive 3).

### Region (→ crop op; omitted entirely for `full`)

| IIIF region | Plan operation |
|---|---|
| `full` | *(no crop op)* |
| `square` | `CropGuided{aspect_ratio: {:ratio, 1, 1}, guide: {:anchor, :center, :center}, width: :full_axis, height: :full_axis}` — centered max-square (**verify + pixel test**) |
| `x,y,w,h` (regionByPx) | `CropRegion{x: {:px, x}, y: {:px, y}, width: {:px, w}, height: {:px, h}}` |
| `pct:x,y,w,h` (regionByPct) | `CropRegion` with `{:ratio, n, d}` per axis; decimal percents scaled to integer ratios (e.g. `10.5` → `{:ratio, 105, 1000}`) |

Per IIIF, a pixel/percent region that extends beyond the image is **clipped** to the image bounds; a region with **zero width/height** is a **400** (validatable at parse time); a region **wholly outside** the image is also a **400** but is only knowable at runtime (after decode), so the `CropRegion` op emits the `{:bad_request, _}` client-error reason there (→ 400 via the mapping in primitive 1 below). Partial overlap clips (native `CropRegion` runtime behavior); it is not an error.

### Size (→ `Resize`)

`^` prefix on any size selects upscaling. Mapping:

| IIIF size | Resize fields | enlargement |
|---|---|---|
| `max` | fit within `max_width`/`max_height`/`max_area` (or identity) | `:deny` |
| `^max` | fit within constraints, upscaling allowed | `:allow` |
| `w,` (sizeByW) | `mode: :fit, width: {:px, w}, height: :auto` | `:reject` / `:allow` |
| `,h` (sizeByH) | `mode: :fit, width: :auto, height: {:px, h}` | `:reject` / `:allow` |
| `w,h` (sizeByWh) | `mode: :stretch, width: {:px, w}, height: {:px, h}` (exact, may distort) | `:reject` / `:allow` |
| `!w,h` (sizeByConfinedWh) | `mode: :fit, width: {:px, w}, height: {:px, h}` (preserve aspect) | `:reject` / `:allow` |
| `pct:n` (sizeByPct) | scale by `n%` | `:reject` / `:allow` |

**Enlargement semantics:**
- No `^` on an explicit-size form (`w,`, `,h`, `w,h`, **`!w,h`**, `pct:n>100`) that would upscale → **`enlargement: :reject`** (new native primitive; see below). At execution, when the computed target exceeds the input, `Resize` returns the `{:bad_request, _}` client-error reason → **400** (the IIIF validator's `size_noup.py` runs at Level 2 and asserts exactly 400 — clamping to 200 fails the gate, including for `!w,h`; see primitive 1). `:reject` fires **only on genuine upscale**: a confined `!w,h` (or any form) whose target ≤ input just scales/fits down and returns **200** — so `:reject` correctly covers `!w,h`'s "fit-down is fine, upscale is an error" semantics.
- `max` → `enlargement: :deny` (clamp): `max` is bounded by the source/`max_*` constraints **by definition** and never requests upscaling, so the clamp never fires — `:deny` is correct here (and `^max` → `:allow`).
- Any `^` form → `enlargement: :allow`. The IIIF "`pct:n` value must not exceed 100" rule applies **only to the un-caretted form**: `pct:200` (no `^`) → 400; `^pct:200` is a valid upscale request that the parser must accept. Same for `^!w,h`.
- A size that computes to zero width/height (or `< 1px`) is a **400** — for a literal-zero token this is a parse-time 400 via `handle_error/2`; when it depends on the extracted region it is the runtime `{:bad_request, _}` → 400.

### Rotation (→ `Rotate`)

| IIIF rotation | Plan operation |
|---|---|
| `0` | *(no op)* |
| `90` / `180` / `270` | `Rotate{angle: 90 \| 180 \| 270}` |

`rotationBy90s` only; `!n` mirroring is deferred (extraFeature).

### Quality (→ `gray` op or no-op)

| IIIF quality | Plan operation |
|---|---|
| `default` / `color` | *(no op)* |
| `gray` | `Plan.Operation.Gray{}` (new; see below) |

`bitonal` deferred (extraFeature).

### Format (→ `Output`)

| IIIF format | Output |
|---|---|
| `jpg` | `Output{mode: {:explicit, :jpeg}}` |
| `png` | `Output{mode: {:explicit, :png}}` |
| `webp` | `Output{mode: {:explicit, :webp}}` (bonus) |
| `avif` | `Output{mode: {:explicit, :avif}}` (bonus) |

`jp2`/`gif`/`tif`/`pdf` deferred. An unsupported but syntactically valid format is a **400**.

### EXIF auto-orientation

`auto_rotate: true` by default, configurable via `iiif: [auto_rotate: …]`. IIIF region/size/rotation and the `width`/`height` in info.json are defined in the **displayed** (post-EXIF-orientation) coordinate system.

**Exact mechanism (load-bearing — get this right or region pixels are silently wrong):**
- An absolute-coordinate `CropRegion` (regionByPx/Pct) is made display-correct by the executor **flushing the EXIF pending orientation *before* the crop** and rescaling the region against the orientation-swapped `decode_shrink` (`plan_executor.ex` `do_execute_crop` for `%CropRegion{}`). This is **not** the gravity-compensation path — that applies only to `CropGuided`. (The `square` region uses `CropGuided` and *is* gravity-compensated.)
- The IIIF **rotation** param is emitted as a trailing `%Plan.Operation.Rotate{}` that the executor **folds into `pending_orientation`**, applied at the *next* flush boundary — i.e. **after** the region crop. This is the invariant that makes region coordinates pre-rotation/display-correct: the region crop flushes only the EXIF orientation present at that point; the user-rotate has not yet been folded.
- **Ordering invariant:** the region crop must precede the rotation op in the pipeline, and the IIIF rotation must *not* be folded into the same pending bundle as EXIF before the crop. Pinned by the combined region+rotation+gray pixel test (Tests §T1).
- info.json reports display dimensions, computed **by the `InfoRenderer` itself** from `SourceInfo.orientation` via the shared `ImagePipe.Plan.SourceInfo.display_dimensions/1` (see primitive 6) — the render path never runs the pipeline, so this does **not** depend on `auto_rotate`. No divergence.

---

## New native primitives

> Each primitive below is product-neutral (IIIF is the first caller, not the owner). Every reference to a specific module/line is a touch-point an implementer must hit; the architecture review confirmed the seams that the first spec draft mis-stated, and those corrections are baked in here.

### 1. Transform-emitted client error → 400 (`{:bad_request, _}`)

Today **every** transform-execution `{:error, _}` flattens to **422** at `Sender.handle_processing_error({:transform_error, reason}, …)` ([sender.ex:112](../../../lib/image_pipe/response/sender.ex), `send_transform_error/2` → 422). IIIF needs a **400** for two execution-time conditions (upscale-without-`^`, wholly-out-of-bounds region), and the official validator asserts **exactly 400** (`size_noup.py`, which runs at Level 2, calls `check('size', last_status, 400, …)` and raises if the server returns 200) — so 422 fails the gate.

Add a **minimal, reason-aware branch**: a transform op may return `{:error, {:bad_request, detail}}`; `Chain` wraps it as `{:transform_error, {:bad_request, detail}}` ([chain.ex:77](../../../lib/image_pipe/transform/chain.ex)). In `Sender`, add a **new head that precedes** the existing generic `{:transform_error, reason}` clause ([sender.ex:112](../../../lib/image_pipe/response/sender.ex)) — Elixir matches top-to-bottom, so ordering is load-bearing:

```elixir
defp handle_processing_error(conn, {:transform_error, {:bad_request, _}}, headers),
  do: send_bad_request_error(conn, headers)            # NEW — must come first
defp handle_processing_error(conn, {:transform_error, _reason}, headers),
  do: send_transform_error(conn, headers)              # existing 422
```

400 is **not** currently used in `Sender` (no conflict), and `:transform_error` is **not** in `@plan_validation_error_tags`, so no other dispatch interferes. There is **no** existing 400 helper — add `send_bad_request_error/2` (a 4-line mirror of `send_transform_error/2`). Product-neutral (any op can signal "the request — not the image — is bad"). This is the minimal slice of [#267](https://github.com/hlindset/image_pipe/issues/267); #267 stays open for the *general, host-customizable* error→status mapping (and its source-side twin #160).

### 2. `Resize` `enlargement: :reject`

The **plan** op `ImagePipe.Plan.Operation.Resize` carries `enlargement :: :allow | :deny` ([plan/operation/resize.ex](../../../lib/image_pipe/plan/operation/resize.ex)); the **executable** op carries only `enlarge: boolean()` ([transform/operation/resize.ex](../../../lib/image_pipe/transform/operation/resize.ex)), set by `resize_from/2` via `enlarge: operation.enlargement == :allow` ([plan_executor.ex](../../../lib/image_pipe/transform/plan_executor.ex)). So a third value cannot just be "added to the field" — the executable boolean can't express three states.

Concretely:
- Plan side: add `:reject` to the `enlargement` type **and** to `@enlargements [:allow, :deny]` in `plan/operation.ex` (used by the constructor and the `valid_resize?` gate).
- Executable side: replace `enlarge: boolean()` with a tri-state (`enlargement: :allow | :deny | :reject`, or add `reject_enlargement: boolean()`), and thread it through `resize_from/2`.
- Runtime: the check belongs in **`resolve_dimensions/2`** ([transform/operation/resize.ex:96](../../../lib/image_pipe/transform/operation/resize.ex)), comparing the **`requested`** box (the `apply_dpr(base, effective_dpr)` value computed once at line 96) against `source` — **not** "before `clamp_to_source/3`", which is called per-mode from 2–4 sites (`target_dimensions`/`intermediate_dimensions`), not a single chokepoint. If mode is `:reject` and `requested` would upscale, return `{:error, {:bad_request, :upscale_required}}` → 400 (primitive 1). Two subtleties: (a) treat an **`:auto`** axis as "no constraint exceeded" (IIIF `w,`/`,h`/`pct:n` bind only one axis — mirror how `fit_axis_exceeds?` handles `:auto`); (b) also detect upscale forced by **`min_width`/`min_height`** (`target_box_dimensions`), not just the plain requested box. `:deny` keeps clamping; `:allow` keeps upscaling.

Per the validation guidelines this is a legitimate runtime error from a correctly-constructed op (a data-determined condition: the request asks for more pixels than exist), **not** impossible-misuse — so it is exempt from "trust operation structs inside the transform boundary."

### 3. `gray` quality op (true desaturation)

- `ImagePipe.Plan.Operation.Gray{}` — semantic op, no params (plan boundary).
- `ImagePipe.Transform.Operation.Gray` — executable op (transform boundary):
  - `execute/2 → Image.to_colorspace(state.image, :bw)` — true luminance desaturation, **not** `Monochrome` (which tints to a color via Duotone). Gray **preserves alpha**: `vips_colourspace` carries an alpha band into `B_W` (a 2-band B_W+alpha result for an RGBA source), so `gray.png`/`gray.webp`/`gray.avif` keep transparency. **`gray.jpg` (or any explicit non-alpha format) on an alpha source 500s today** — a *pre-existing, general* output-layer gap (plain `default.jpg` on an RGBA source fails identically), tracked by **[#268](https://github.com/hlindset/image_pipe/issues/268)** (flatten-to-background for explicit non-alpha formats). The Level 2 validator gate is unaffected (its reference image is an opaque JPEG); until #268 lands, `gray.jpg` coverage uses an opaque source (Tests §S1).
  - `requires_materialization?/1 → false` (inherited default; per-pixel point op). **Note (corrected):** in IIIF order the trailing rotation folds into `pending_orientation` and flushes *after* gray, so **gray runs before the rotate materializes**, on a possibly-streamed image. Correctness holds (gray is a per-pixel point op and commutes with the rotate), but this is exactly why the sequential-vs-random equivalence gate below is **required**, not "always materialized."
  - `name/1 → :gray`. **The literal `:gray` must appear in the compiled transform module** — `Plan.Operation.name/1` derives the atom via `String.to_existing_atom/1` and will raise otherwise.
- **Real wiring seams (there is no `@pipeline_operations` registry):**
  - a `Plan.Operation.semantic?(%Gray{}) -> true` clause in `plan/operation.ex` — **without it, `Plan.validated_pipelines/1` rejects every Gray plan as `:invalid_pipeline_operation`** (the fallthrough `semantic?(_) -> false`). Load-bearing.
  - an `executable_operations(%Plan.Operation.Gray{}, …) -> [%Transform.Operation.Gray{}]` clause (+ alias) in `Transform.PlanExecutor` — the actual Plan→Transform "wire".
  - add `Operation.Gray` to the **`Plan` Boundary `exports`** and `Transform.Operation.Gray` to the **`Transform` Boundary `exports`**.
  - architecture-test lists in `test/image_pipe/architecture_boundary_test.exs`: the **Plan** list uses **exact-match** `assert_boundary_exports`, so it **must** gain `Operation.Gray` or the test fails. The **Transform** list uses **`assert_boundary_exports_include`** (subset), so adding `Operation.Gray` to the transform `exports` code does **not** break it — updating the test list is hygiene, not test-forced. (Don't treat the Transform list as exact-match.)
- **AGENTS.md gate:** add a sequential-vs-random pixel-equivalence test (streamed open, `access: :sequential`, `fail_on: :error`) plus a property test over input shapes in `test/image_pipe/transform/sequential_access_test.exs`. The existing harness self-check (a known-random op must raise under the streamed open) already prevents tautological passes.

### 4. Redirect parse outcome (`{:redirect, status, location}`)

Widen the neutral `ImagePipe.Parser.parse/2` `@callback` return type to:

```elixir
{:ok, Plan.t()} | {:redirect, status :: 303, location :: String.t()} | {:error, any()}
```

A `{:redirect, …}` cannot ride `Plug.do_call`'s existing `with` (its first head matches `{:ok, %Plan{}}`), so detect it **around** the `with`: `case parse(...)` with a `{:redirect, status, location}` arm that calls `ImagePipe.Response.Sender.send_redirect/3` inside the existing `send_response(conn, opts, :redirect, fn -> … end)` telemetry wrapper (which reads `conn.status`, so 303 is captured), falling through to the current `with` for `{:ok, plan}`. Short-circuits **before** `validate_client_plan`/`Source.resolve` — no source, decode, or cache.

Touch-points the implementer must not miss:
- the `Parser` `@callback parse/2` typespec ([parser.ex:22](../../../lib/image_pipe/parser.ex)) — imgproxy returns only `{:ok|:error}`, so its Dialyzer surface is unaffected;
- `wrap_parser_error/1` ([plug.ex:158](../../../lib/image_pipe/plug.ex)) already passes non-`{:error,…}` through unchanged, so `{:redirect,…}` survives — add a test;
- **`result_metadata/1` ([plug.ex:212](../../../lib/image_pipe/plug.ex)) is the crash site**: it runs *inside* the `parse/2` telemetry span and has only `:ok`/`:error` heads, so a `{:redirect, …}` raises `FunctionClauseError` at span-stop *before* the redirect is ever sent — it **must** gain a `{:redirect, …}` head. (`request_result/1` is **not** on the redirect path — it's reached only via `send_conditional_response` on the `{:ok, plan}` branch — so it needs no change if detection happens around the `with`.)
- the redirect arm of `do_call` must **return the `{conn, metadata}` 2-tuple** the `[:request]` span expects (e.g. `{conn, %{result: :redirect, status: 303}}`), mirroring the other `do_call` arms;
- `Sender.send_redirect/3` lives under the response boundary; sets `Location`, sends `303` empty body, plus CORS headers.

### 5. info.json content-type negotiation hook (rendered-delivery path)

The Phase 1 `Renderer` returns a fixed content-type and never sees the conn (`RenderRunner.run/3` passes only `%RenderContext{}` + host `opts`), and `Json.send/3` hardcodes `send_resp(200, …)` with no `Vary`. The body is **byte-identical** regardless of `Accept` (it always embeds `@context`), so cache identity must stay Accept-independent. The renderer therefore stays **Accept-blind**; negotiation happens in the `Sender`, which does have the conn.

**`offers` is a parser-supplied render *param*, not a renderer return value.** `Renderer.render/3`'s return is `{:ok, {content_type :: String.t(), iodata()}}` ([renderer.ex:20](../../../lib/image_pipe/renderer.ex)) — a 2-tuple. Making the renderer *return* `offers` would change that `@callback` (and cascade through `RenderRunner.run/3`'s match at [render_runner.ex:34](../../../lib/image_pipe/request/render_runner.ex) and `Runner.run/4` at [runner.ex:47](../../../lib/image_pipe/request/runner.ex)). Since `offers` is conn-independent and per-identifier-static, it is already known at parse time. So:

- the `PlanBuilder` puts `offers` in the render **`params`** map: `{:custom, InfoRenderer, %{id: …, offers: [{"application/ld+json;profile=\"http://iiif.io/api/image/3/context.json\"", ["application/ld+json"]}]}}`. The `Renderer` behaviour and `render/3` return are **genuinely unchanged**.
- `Runner.run/4` (which already destructures `%Plan{render: {:custom, _module, params}}` at [runner.ex:41](../../../lib/image_pipe/request/runner.ex)) **lifts `params[:offers]`** into a widened delivery tuple `{:rendered, content_type, body, offers, prepared}` at the construction site ([runner.ex:48](../../../lib/image_pipe/request/runner.ex)). Update **both** `@type delivery()` declarations ([runner.ex:23-26](../../../lib/image_pipe/request/runner.ex), [sender.ex:27-30](../../../lib/image_pipe/response/sender.ex)).
- `Json.send/4` grows a response-headers arg; the `Sender` `{:rendered, …}` clause ([sender.ex:72](../../../lib/image_pipe/response/sender.ex)) matches the conn's `Accept` against `offers`, upgrades `Content-Type` when matched, and sets `Vary: Accept` whenever `offers != []`.
- cache identity: the `id`/`offers` (body-shaping/static) live in render `params` and fold into `Cache.Key.representation_data/1` (`{module, params}`, [key.ex:91](../../../lib/image_pipe/cache/key.ex)); a custom render has `output: nil` so the `Accept`-bearing `output_data` key path is not taken — and the `offers` list is identical for all requests of an identifier, so cache identity stays Accept-independent. The negotiated `Content-Type` never enters the key.
- net: `render/3` return + `RenderContext` are **untouched**; the changes are `PlanBuilder` params, `Runner.run/4` (lift + 5-tuple), both `@type delivery()`, `Json.send/4`, and the `Sender` clause. (Aligns with the spirit of #262's "Renderable" unification.)

### 6. `SourceInfo.display_dimensions/1` (extract, don't copy)

The EXIF orientation → display-dimension swap currently lives as a private `display_dimensions/3` in the imgproxy `InfoRenderer` ([info_renderer.ex:52-54](../../../lib/image_pipe/parser/imgproxy/info_renderer.ex)). It is pure geometry over `SourceInfo`'s own fields (swap w/h for orientations 5–8), with no imgproxy entanglement, and the IIIF `InfoRenderer` needs the identical computation. **Extract** it to a public `ImagePipe.Plan.SourceInfo.display_dimensions/1` (→ `{w, h}`) — the struct deriving a fact about itself — and refactor the imgproxy `InfoRenderer` to call it. No boundary change: `SourceInfo` is already in the **plan** boundary that both info renderers depend on. (Per the brainstorming "improve the code you're working in" rule and CLAUDE.md's no-duplication stance; the imgproxy `@moduledoc` note about orientation-adjusted dimensions stays accurate.)

---

## info.json (rides Phase 1)

`ImagePipe.Parser.IIIF.InfoRenderer` implements `ImagePipe.Renderer`:

- `requires/1 → [:header]` (needs decoded source dimensions + orientation).
- `render/3` receives `%RenderContext{info: %SourceInfo{width, height, orientation, ...}}` and parser-supplied `params` (the absolute `id`, the compliance level, the supported `extraFeatures`/`extraQualities`/`extraFormats` lists, the static `offers` list for negotiation, and optional `maxWidth`/`maxHeight`/`maxArea`). It computes **display** dimensions itself via the shared `SourceInfo.display_dimensions/1` (primitive 6) — the render path never runs the pipeline, so it does not depend on `auto_rotate`. It builds the IIIF 3.0 document:

```json
{
  "@context": "http://iiif.io/api/image/3/context.json",
  "id": "<absolute base URI without /info.json>",
  "type": "ImageService3",
  "protocol": "http://iiif.io/api/image",
  "profile": "level2",
  "width": <display width>,
  "height": <display height>,
  "maxWidth": <optional>, "maxHeight": <optional>, "maxArea": <optional>,
  "extraQualities": ["color", "gray"],
  "extraFormats": ["webp", "avif"],
  "extraFeatures": ["regionByPx", "regionByPct", "regionSquare",
                    "sizeByW", "sizeByH", "sizeByWh", "sizeByPct",
                    "sizeByConfinedWh", "sizeUpscaling",
                    "rotationBy90s", "baseUriRedirect", "cors", "jsonldMediaType"]
}
```

(`extraFeatures`/`extra*` lists reflect what is actually implemented; finalize the exact list during implementation against the Level 2 compliance matrix. Note: `regionByPx/Pct/Square`, `sizeByW/H/Wh/Pct/ConfinedWh`, `rotationBy90s`, `baseUriRedirect`, `cors`, `jsonldMediaType` are **Level-2 required** and thus implied by `profile: "level2"` — listing them is harmless and explicit but optional; the genuinely-*extra* entries are `sizeUpscaling` and the bonus formats `webp`/`avif`. The validator's `info_json` test does not reject over-listing.) The `PlanBuilder` emits the render plan with `render: {:custom, InfoRenderer, %{id: ..., offers: [...], ...}}`, `output: nil`, `pipelines: []` — exactly the Phase 1 shape.

---

## Identifier → Source resolution

A resolver seam owned by the IIIF parser, mirroring the existing Parser extension pattern (`source_schemes`, `validate_options!`):

```elixir
defmodule ImagePipe.Parser.IIIF.Resolver do
  @callback resolve(identifier :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
end
```

Configured via `iiif: [resolver: {Module, resolver_opts}]`. Ship one built-in now:

- `ImagePipe.Parser.IIIF.Resolver.Static` — maps a percent-decoded identifier to a pre-configured `Plan.Source` from a static map. Opaque IDs, zero source-structure leakage, and exactly what serves the validator's canonical reference image. An unknown identifier → `{:error, _}` → `404`.

`validate_options!/1` validates the `iiif:` option namespace (resolver tuple, auto_rotate, max_* constraints, formats/qualities lists) with `NimbleOptions`, rejecting unknown/malformed config at boot. A boot-time `function_exported?(module, :resolve, 2)` check on the resolver module is appropriate (host config is a real boundary); per the validation guidelines, **runtime** dispatch just calls `module.resolve/2` directly and lets a missing callback raise — no runtime duck-typing probe. The resolver's `{:ok, %Plan.Source{}}` / `{:error, _}` return crosses a host boundary and is validated at the parser before use.

The source-string resolver (imgproxy-style URL-in-identifier) is **deferred**.

---

## HTTP behavior

- **CORS:** `Access-Control-Allow-Origin: *` on all IIIF responses (image, info.json, redirect). `OPTIONS` preflight → `200` with `Access-Control-Allow-Origin`/`Access-Control-Allow-Methods`.
- **Base-URI redirect:** `{prefix}/{id}` → `303` to `{prefix}/{id}/info.json` (`baseUriRedirect`, required at Level 1+).
- **Canonical `Link` header (optional):** `Link: <canonical-url>;rel="canonical"` on image responses, where the canonical URL uses the normalized/canonical spelling of region/size/rotation/quality/format. Included, marked optional in the matrix.
- **info.json content negotiation (gate-blocking):** `Vary: Accept`; `application/ld+json;profile="…/context.json"` when `Accept` allows it, else `application/json`. The validator's `jsonld` test sends `Accept: application/ld+json` and asserts the response `Content-Type` starts with `application/ld+json` — so primitive 5's negotiation is required for the gate, not optional polish. (`info_json` sends no `Accept` and accepts either type; `profile` must be the string `"level2"`.)

---

## Boundaries / namespaces

- `ImagePipe.Parser.IIIF.*` under the **parser** boundary; deps: `plan`, `renderer`, `format` (mirroring imgproxy's `[Format, Parser, Plan, Renderer]`). The IIIF parser must **not** name concrete transform operation modules and must emit `Plan.Operation.*` structs.
- `Plan.Operation.Gray` added to the **`Plan`** Boundary `exports`; `Transform.Operation.Gray` added to the **`Transform`** Boundary `exports`.
- The `enlargement: :reject` variant stays within the existing `Resize` op (plan + transform); the `{:bad_request, _}` → 400 mapping is a `Sender` clause (response boundary).
- The redirect parse outcome and `Sender.send_redirect/3` touch the **request**/**response** boundaries; the `parse/2` typespec widening is on the neutral `Parser` behaviour.
- **Architecture tests** (`test/image_pipe/architecture_boundary_test.exs`) — name the specific additions: register `ImagePipe.Parser.IIIF` in `@boundary_files` and add an `assert_boundary_deps(iiif, [Format, Plan, Renderer])` assertion mirroring imgproxy's; add `Operation.Gray` to **both** the Plan and Transform expected-`exports` lists (exact-match `assert_boundary_exports`). The generic source-scan test (`parser code does not depend on executable transform operation modules`) already globs the new `lib/image_pipe/parser/iiif/**` files, so it auto-covers the "emits `Plan.Operation.*`, names no concrete transform module" rule.

---

## Tests

Per `AGENTS.md` test discipline — boundary contracts, representative wire-level coverage, property tests for invariants, no impossible-misuse or name-policing tests.

- **Parser unit** (`test/parser/iiif_test.exs`): URL → Plan for each region/size/rotation/quality/format token; error cases (zero-dim region/size, wholly-out-of-bounds region, unsupported quality/format, malformed identifier, malformed `path_info` shape); resolver miss → 404.
- **Property tests:** identifier percent-encoding round-trip; `pct` decimal → integer-ratio conversion; size/region numeric parsing across shapes.
- **Wire-level Plug tests** (real `ImagePipe.call/2`): status, `Content-Type`, `Vary`, CORS headers, optional `Link`, decoded output dimensions, and **pixel checks** for representative region/size/rotation and **`gray`**; info.json body + Accept negotiation (json vs ld+json); base-URI `303` redirect; **upscale-without-`^` → `400`** (incl. `!w,h`), **wholly-out-of-bounds region → `400`**, and the full status-mapping table (random region/size/rotation/quality/format → 400; resolver miss + unescaped-slash `a/b` → 404).
- **§T1 — combined region + IIIF-rotation + gray pixel test (highest-value, pins the orientation invariant).** Construct the baseline from primitives the pipeline does **not** share, or it proves nothing: take the source bytes → `Image.autorotate/1` (apply EXIF to the whole image, giving the display frame) → `Image.crop/5` the literal display-frame rectangle `{x,y,w,h}` → `Vix.Vips.Operation.rot(:VIPS_ANGLE_D90|D270)` → `Image.to_colorspace(:bw)`. Compare to the IIIF request `…/{x},{y},{w},{h}/max/90/gray.png` (use `.png`, not `.jpg`, to dodge #268). Use an **orientation 6 or 8** source (a quarter-turn, so the swapped-`decode_shrink` axis-swap path is exercised; a half-turn won't catch it). Add a **negative control**: a variant that folds the rotation *before* the crop must produce different pixels, proving the test discriminates.
- **§T2 — ETag / 304 for info.json:** an `If-None-Match` conditional GET returns `304` **before any source fetch/decode** (`Source.resolve` runs first to seed identity, but no fetch/decode/render), and the ETag is Accept-independent.
- **§T3 — cache reuse for equivalent IIIF requests:** two semantically equivalent image URLs (e.g. `max` vs the explicit dims it computes to, `pct:100` vs `max`, `default` vs `color` quality) hit the same cache entry / the second avoids source fetch.
- **`gray` op:** sequential-vs-random equivalence + property test (the AGENTS.md gate); **§S1** split by alpha support: (a) on an **RGBA** source, `gray.png`/`gray.webp`/`gray.avif` round-trip `200` with a non-opaque alpha band intact (gray preserves alpha); (b) on an **opaque** source, `gray.jpg` → `200` valid JPEG with RGB bands equal at sampled points (true desaturation). The `gray.jpg`-on-RGBA → flatten case is **#268**, not tested here.
- **`square` region:** pixel test confirming a centered 1:1 crop from the shorter axis.
- **`enlargement: :reject`:** unit test that a genuine-upscale target returns `{:error, {:bad_request, _}}` and a wire-level test that it surfaces as **400** (cover `w,h` and `!w,h`); that a fit-down `!w,h` and `:deny`/`:allow` are unaffected; that min_width/min_height-forced upscale also rejects.
- **Other wire tests:** `OPTIONS` preflight → `200` with CORS headers; resolver-miss → `404` at the wire (before any source fetch); configured `maxWidth`/`maxHeight`/`maxArea` appear in info.json (and are omitted when nil); explicit `.webp`/`.avif` bypass `Accept` negotiation.
- **Negative `Vary`:** assert **image** responses (delivered via `{:prepared_stream,…}`/`{:cache_entry,…}`, not `{:rendered,…}`) carry **no** `Vary: Accept` from the new negotiation plumbing — `get_resp_header(conn, "vary") == []`.
- **Avoid (AGENTS.md smell):** no standalone "the `Gray` module exists / `name/1` returns `:gray`" assertion — the gray pixel tests already force the module and the `:gray` atom to compile.

---

## Validator CI gate (wired this phase)

The official IIIF `image-validator` performs real pixel sampling, so the gate is an output-correctness check, not just status/headers. v3.0 support is confirmed in the validator source (`validator.py` and test modules branch on `self.version == "3.0"`; default size is `max`; `gray` quality). The validator runs every test whose `level <= requested`, so at **Level 2**: `size_noup.py` (level 1) enforces no-`^` upscale → **400** (incl. `!w,h`, `pct:200`) — this is the gate-relevant upscale check; the pixel-verifying `size_up.py` is **level 3** and does **not** run at the L2 gate (so the advertised `sizeUpscaling` `^`-forms are exercised by our own §-tests, not the validator).

- Purpose-built slim image (per issue), **not** the repo's Apache/WSGI Dockerfile:

  ```dockerfile
  FROM python:3.12-slim
  RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 \
      && rm -rf /var/lib/apt/lists/*
  RUN pip install --no-cache-dir iiif-validator
  ENTRYPOINT ["iiif-validate.py"]
  ```

- The validator makes HTTP requests **out to** a running ImagePipe IIIF endpoint serving the canonical `67352ccc-…` reference image (committed as a test fixture) via the **Static resolver**. Reach the service via `docker-compose` on a shared network (use the ImagePipe service name as `--server`) or `--network host` / `host.docker.internal`.
- Invoke `iiif-validate.py -s <server> -p <prefix> -i <identifier> --version=3.0` at Level 2; assert exit `0`. The gate goes green only once info.json is in place (the validator discovers sizes/features from it).
- Wire via a mise task + CI workflow. The validator **requires exactly `400`** for the no-`^` upscale case (`size_noup.py`, level 1, runs at L2; `check(..., 400, ...)` raises on mismatch) — primitive 1's `{:bad_request, _}` → 400 mapping is what makes this pass; there is no 422 fallback to live with.

---

## Docs

`docs/iiif_3_support_matrix.md`, mirroring `docs/imgproxy_support_matrix.md`: per-feature status keyed to the Level 0/1/2 compliance matrix, noting the changed axis for each entry — **surface** (option/config), **stage/order** (pipeline), **behavioral/pixel** (wire conformance). Record the divergences explicitly:

- Upscale-without-`^` (incl. `!w,h`) and wholly-out-of-bounds region return **400** (spec-conformant) via the minimal `{:bad_request, _}` mapping; the *general, host-customizable* error→status policy remains open as #267.
- `gray` (and any quality) on an explicit **non-alpha format** with an alpha source 500s until **#268** (general flatten-to-background gap); IIIF gray preserves alpha for alpha-supporting formats.
- `jp2`/`gif`/`tif`/`pdf`, bitonal, arbitrary rotation, and mirroring are unsupported `extraFeatures`.
- `auto_rotate` defaults true (display-frame coordinates) — documented as intentional, not a divergence.

---

## Process

Per `AGENTS.md`, this spec went through **two parallel review cycles** (IIIF-3.0 compatibility + architecture/boundary + integration/test, disjoint focus) against the real spec, the compliance document, the `image-validator` source, and the actual codebase. Round 1 corrected the Gray wiring, the orientation mechanism, and the 422→400 gate gap; round 2 corrected `!w,h` upscaling, the `offers`/Renderer contradiction, the Resize check point, and the status-mapping completeness, and spun out #268. The next gate is the **implementation plan** (`writing-plans`), which should get its own focused review (esp. a compatibility lens) before implementation, then per-task spec + code-quality reviewers during execution.
