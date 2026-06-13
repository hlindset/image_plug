# IIIF Image API 3.0 — Parser, info.json, and Level 2 conformance (Phase 2)

**Issue:** [#253](https://github.com/hlindset/image_pipe/issues/253)
**Depends on:** [#252 / PR #260](https://github.com/hlindset/image_pipe/pull/260) — Phase 1 cross-dialect render mechanism (merged)
**Spawns follow-up:** [#267](https://github.com/hlindset/image_pipe/issues/267) — customizable transform/processing error → HTTP status mapping
**Status:** design approved; pending parallel review cycle before implementation

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

| `path_info` | Outcome |
|---|---|
| `[id]` | **303 redirect** → `{base}/{id}/info.json` |
| `[id, "info.json"]` | **info.json render** |
| `[id, region, size, rotation, quality_dot_format]` | **image request** |
| anything else | `404` (or `400` for malformed token) |

`quality_dot_format` splits on the **last** `.` → `quality` + `format`.

The identifier is percent-decoded once and handed to the configured resolver (see below) to obtain a `Plan.Source`.

---

## Region / Size / Rotation / Quality / Format mapping

Operations are emitted into a single pipeline in IIIF order. Crop and resize are sequential-safe; right-angle rotate self-materializes; `gray` is sequential-safe and runs last.

### Region (→ crop op; omitted entirely for `full`)

| IIIF region | Plan operation |
|---|---|
| `full` | *(no crop op)* |
| `square` | `CropGuided{aspect_ratio: {:ratio, 1, 1}, guide: {:anchor, :center, :center}, width: :full_axis, height: :full_axis}` — centered max-square (**verify + pixel test**) |
| `x,y,w,h` (regionByPx) | `CropRegion{x: {:px, x}, y: {:px, y}, width: {:px, w}, height: {:px, h}}` |
| `pct:x,y,w,h` (regionByPct) | `CropRegion` with `{:ratio, n, d}` per axis; decimal percents scaled to integer ratios (e.g. `10.5` → `{:ratio, 105, 1000}`) |

Per IIIF, a pixel/percent region that extends beyond the image is **clipped** to the image bounds; a region wholly outside the image, or with zero width/height, is a **400**. Clipping is the native `CropRegion` runtime behavior; the zero/out-of-bounds rejection is enforced where dimensions are known (region values themselves can be validated for zero at parse time; out-of-bounds-vs-image is a runtime clip, not an error, except the wholly-outside case).

### Size (→ `Resize`)

`^` prefix on any size selects upscaling. Mapping:

| IIIF size | Resize fields | enlargement |
|---|---|---|
| `max` | fit within `max_width`/`max_height`/`max_area` (or identity) | `:deny` |
| `^max` | fit within constraints, upscaling allowed | `:allow` |
| `w,` (sizeByW) | `mode: :fit, width: {:px, w}, height: :auto` | `:reject` / `:allow` |
| `,h` (sizeByH) | `mode: :fit, width: :auto, height: {:px, h}` | `:reject` / `:allow` |
| `w,h` (sizeByWh) | `mode: :stretch, width: {:px, w}, height: {:px, h}` (exact, may distort) | `:reject` / `:allow` |
| `!w,h` (sizeByConfinedWh) | `mode: :fit, width: {:px, w}, height: {:px, h}` (preserve aspect) | `:deny` / `:allow` |
| `pct:n` (sizeByPct) | scale by `n%` | `:reject` (n≤100 never upscales) / `:allow` |

**Enlargement semantics:**
- No `^` on an explicit-size form (`w,`, `,h`, `w,h`, `pct:n>100`) that would upscale → **`enlargement: :reject`** (new native primitive; see below). At execution, when the computed target exceeds the input, `Resize` returns `{:error, _}`.
- No `^` on `!w,h` (confined) or `max` → `enlargement: :deny` (clamp; a smaller image legitimately stays smaller — not an error).
- Any `^` form → `enlargement: :allow`.
- A size that computes to zero width/height is a **400**.

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

`auto_rotate: true` by default, configurable via `iiif: [auto_rotate: …]`. IIIF region/size/rotation and the `width`/`height` in info.json are defined in the **displayed** (post-EXIF-orientation) coordinate system, which is exactly what the existing late `OrientationFlush` machinery produces — crop gravity and resize dimensions are compensated into the storage frame, composing `EXIF → user-rotate → user-flip` (the IIIF rotation param is the user-rotate). info.json reports display dimensions via `display_dimensions(width, height, orientation)`, the same path imgproxy's info uses. No divergence.

---

## New native primitives

### 1. `Resize` `enlargement: :reject`

Add `:reject` to the existing `enlargement: :allow | :deny` field on `ImagePipe.Plan.Operation.Resize` and the executable `Transform.Operation.Resize`.

- `:allow` — upscale as needed (unchanged).
- `:deny` — never upscale; clamp to input size (unchanged).
- `:reject` — never upscale; **return `{:error, _}` at execution when the computed target exceeds the input**, instead of clamping.

`:reject` is a product-neutral primitive ("the request asks for more pixels than exist, and the caller wants that to fail rather than silently clamp"). It flows through the existing transform-error path:

`Resize.execute → {:error, reason}` → `Chain` wraps `{:transform_error, reason}` ([chain.ex:77](../../../lib/image_pipe/transform/chain.ex)) → request runner `{:processing, {:transform_error, reason}, headers}` → `Sender.handle_processing_error` ([sender.ex:112](../../../lib/image_pipe/response/sender.ex)) → **422 "invalid image transform"**.

**Divergence:** IIIF *recommends* 400 for upscale-without-`^`; we surface 422 via the existing flat mapping. 422 is semantically defensible (the request parses; it is only *unprocessable* once the image size is known). Documented in `docs/iiif_3_support_matrix.md` and tracked by [#267](https://github.com/hlindset/image_pipe/issues/267) (customizable error→status, the transform-side twin of #160). No new error surface is added in this phase.

### 2. `gray` quality op (true desaturation)

- `ImagePipe.Plan.Operation.Gray{}` — semantic op, no params (plan boundary).
- `ImagePipe.Transform.Operation.Gray` — executable op (transform boundary):
  - `execute/2 → Image.to_colorspace(state.image, :bw)` — true luminance desaturation, **not** `Monochrome` (which tints to a color via Duotone). Must **preserve alpha** (verify and test).
  - `requires_materialization?/1 → false` (inherited default; per-pixel point op).
  - `name/1 → :gray`.
- Wire `Plan.Operation.Gray → Transform.Operation.Gray` in `Transform.PlanExecutor`; add to the `Transform` `exports`/boundary and the `Plan.Operation` alias list.
- **AGENTS.md gate:** add a sequential-vs-random pixel-equivalence test (streamed open, `access: :sequential`, `fail_on: :error`) plus a property test over input shapes in `test/image_pipe/transform/sequential_access_test.exs`. The existing harness self-check (a known-random op must raise under the streamed open) already prevents tautological passes.

### 3. Redirect parse outcome (`{:redirect, status, location}`)

Widen the neutral `ImagePipe.Parser.parse/2` return type to:

```elixir
{:ok, Plan.t()} | {:redirect, status :: 303, location :: String.t()} | {:error, any()}
```

In `ImagePipe.Plug.do_call`, a `{:redirect, status, location}` short-circuits **before** `validate_client_plan`/`Source.resolve` — no source, decode, or cache — and is emitted by a new `ImagePipe.Response.Sender.send_redirect/3` (sets `Location`, sends `303` with empty body, plus CORS headers). Product-neutral: imgproxy simply never returns it. Flagged for the architecture/compat reviewer.

### 4. info.json content-type negotiation hook (rendered-delivery path)

The Phase 1 `Renderer` returns a fixed content-type and never sees the conn, so Accept-based negotiation must happen where the conn is available (the `Sender`). The body is **byte-identical** regardless of `Accept` (it always embeds `@context`), so cache identity must stay Accept-independent.

Add a **small, product-neutral negotiation hint** to the rendered-delivery path: the `InfoRenderer` returns the base `application/json` body plus a negotiation directive (offer `application/ld+json;profile="http://iiif.io/api/image/3/context.json"` when `Accept` allows `application/ld+json`). The `Sender`, delivering the `{:rendered, …}` result, applies the directive generically — upgrading `Content-Type` and always setting `Vary: Accept`. The `id` (body-shaping) lives in render params and folds into cache identity; the negotiated content-type does **not**. Exact directive shape finalized during planning; flagged for the architecture/compat reviewer. (Aligns with the spirit of #262's "Renderable" unification without expanding the `Renderer` behaviour itself.)

---

## info.json (rides Phase 1)

`ImagePipe.Parser.IIIF.InfoRenderer` implements `ImagePipe.Renderer`:

- `requires/1 → [:header]` (needs decoded source dimensions + orientation).
- `render/3` receives `%RenderContext{info: %SourceInfo{width, height, orientation, ...}}` and parser-supplied `params` (the absolute `id`, the compliance level, the supported `extraFeatures`/`extraQualities`/`extraFormats` lists, and optional `maxWidth`/`maxHeight`/`maxArea`). It builds the IIIF 3.0 document:

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

(`extraFeatures`/`extra*` lists reflect what is actually implemented; finalize the exact list during implementation against the Level 2 compliance matrix.) The `PlanBuilder` emits the render plan with `render: {:custom, InfoRenderer, %{id: ..., ...}}`, `output: nil`, `pipelines: []` — exactly the Phase 1 shape.

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

`validate_options!/1` validates the `iiif:` option namespace (resolver tuple, auto_rotate, max_* constraints, formats/qualities lists) with `NimbleOptions`, rejecting unknown/malformed config at boot.

The source-string resolver (imgproxy-style URL-in-identifier) is **deferred**.

---

## HTTP behavior

- **CORS:** `Access-Control-Allow-Origin: *` on all IIIF responses (image, info.json, redirect). `OPTIONS` preflight → `200` with `Access-Control-Allow-Origin`/`Access-Control-Allow-Methods`.
- **Base-URI redirect:** `{prefix}/{id}` → `303` to `{prefix}/{id}/info.json` (`baseUriRedirect`, required at Level 1+).
- **Canonical `Link` header (optional):** `Link: <canonical-url>;rel="canonical"` on image responses, where the canonical URL uses the normalized/canonical spelling of region/size/rotation/quality/format. Included, marked optional in the matrix.
- **info.json content negotiation:** `Vary: Accept`; `application/ld+json;profile="…/context.json"` when `Accept` allows it, else `application/json`.

---

## Boundaries / namespaces

- `ImagePipe.Parser.IIIF.*` under the **parser** boundary; deps: `plan`, `renderer`, `format` (mirroring imgproxy's `[Format, Parser, Plan, Renderer]`). The IIIF parser must **not** name concrete transform operation modules and must emit `Plan.Operation.*` structs.
- `Plan.Operation.Gray` under the **plan** boundary; `Transform.Operation.Gray` under the **transform** boundary; added to `Transform` exports.
- The `enlargement: :reject` variant stays within the existing `Resize` op (plan + transform).
- The redirect parse outcome and `Sender.send_redirect/3` touch the **request**/**response** boundaries; the `parse/2` typespec widening is on the neutral `Parser` behaviour.
- **Architecture tests:** extend `test/image_pipe/architecture_boundary_test.exs` for the IIIF parser (no concrete transform modules; emits `Plan.Operation.*`) and the new boundaries.

---

## Tests

Per `AGENTS.md` test discipline — boundary contracts, representative wire-level coverage, property tests for invariants, no impossible-misuse or name-policing tests.

- **Parser unit** (`test/parser/iiif_test.exs`): URL → Plan for each region/size/rotation/quality/format token; error cases (zero-dim region/size, wholly-out-of-bounds region, unsupported quality/format, malformed identifier, malformed `path_info` shape); resolver miss → 404.
- **Property tests:** identifier percent-encoding round-trip; `pct` decimal → integer-ratio conversion; size/region numeric parsing across shapes.
- **Wire-level Plug tests** (real `ImagePipe.call/2`): status, `Content-Type`, `Vary`, CORS headers, optional `Link`, decoded output dimensions, and **pixel checks** for representative region/size/rotation and **`gray`**; info.json body + Accept negotiation (json vs ld+json); base-URI `303` redirect; upscale-without-`^` → `422`.
- **`gray` op:** sequential-vs-random equivalence + property test (the AGENTS.md gate); a focused test asserting RGB bands are equal at sampled points (true desaturation) and alpha is preserved.
- **`square` region:** pixel test confirming a centered 1:1 crop from the shorter axis.
- **`enlargement: :reject`:** unit test that a target exceeding the input returns `{:error, _}` (→ 422 at the wire), and that `:deny`/`:allow` are unaffected.

---

## Validator CI gate (wired this phase)

The official IIIF `image-validator` performs real pixel sampling, so the gate is an output-correctness check, not just status/headers. v3.0 support is confirmed in the validator source (`validator.py` and test modules branch on `self.version == "3.0"`; `size_up.py` enforces `^` upscaling; default size is `max`; `gray` quality).

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
- Wire via a mise task + CI workflow. Confirm whether the validator strictly requires `400` (vs accepting `4xx`) for the no-`^` upscale case; if strict, that single assertion is the only thing the documented 422 divergence affects, and #267 is the place to close it.

---

## Docs

`docs/iiif_3_support_matrix.md`, mirroring `docs/imgproxy_support_matrix.md`: per-feature status keyed to the Level 0/1/2 compliance matrix, noting the changed axis for each entry — **surface** (option/config), **stage/order** (pipeline), **behavioral/pixel** (wire conformance). Record the divergences explicitly:

- Upscale-without-`^` returns **422**, not the spec-recommended 400 (tracked by #267).
- `jp2`/`gif`/`tif`/`pdf`, bitonal, arbitrary rotation, and mirroring are unsupported `extraFeatures`.
- `auto_rotate` defaults true (display-frame coordinates) — documented as intentional, not a divergence.

---

## Process

Per `AGENTS.md`: before implementation, run a **parallel review cycle** on this spec + the implementation plan with disjoint-focus reviewers, including at least one **compatibility reviewer** checking observable behavior against the real IIIF 3.0 spec, the compliance document, and the `image-validator` source (region/size/rotation/quality semantics, the `^` upscaling rule, info.json shape, content negotiation, base-URI redirect). Apply accepted feedback, rerun relevant doc checks, and commit the reviewed plan before implementation starts. Then implement with the spec + code-quality reviewer subagents per task.
