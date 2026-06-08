# Design: format-aware output-encoder dimension clamp (#150)

**Issue:** #150 — `fixSize` parity. **Related (out of scope):** #165 (host max_result_* error→downscale), #164 (look-ahead pre-clamp). Do not implement #165/#164 here; only avoid precluding #165's reuse of the clamp seam.

**Upstream reference (verified):** `local/imgproxy-master/processing/fix_size.go`.

## Problem

ImagePipe's `check_result_*` (`request/processor.ex`) errors when the final image exceeds the *host-configured* `max_result_width/height/pixels`. It does **not** know the *output encoder's* hard dimension limit. A request within `max_result_width` but above the encoder limit (e.g. `max_result_width: 20000`, an 18000px WebP) passes the host check and then **fails at encode** — `webpsave` cannot represent > 16383px. imgproxy closes this gap with `fixSize` (step 13): after all geometry, keyed on the chosen output format, it uniformly downscales the realized image to fit the encoder limit and serves it (logging a warning) rather than erroring.

This design adds the equivalent: a **post-hoc, uniform downscale of the realized final image at the `ImagePipe.Output.*` boundary, keyed on the negotiated output format**, so encoding cannot fail. Downscale-and-serve (not error), with a telemetry signal so hosts can observe the clamp.

## Architecture (settled per #150 — not re-opened here)

- Post-hoc: reads the **realized** final image (order-agnostic, trim-robust), not predicted intermediate geometry.
- Uniform downscale (same scale on both axes), mirroring `img.Resize(scale, scale)`.
- Lives at the `ImagePipe.Output.*` boundary, keyed on the negotiated output format.
- Downscale-and-serve, with a telemetry signal.
- Generic clamp seam: takes a `max_dimension` (and `max_pixels`) and does not care which source produced the number, so #165 can later feed `min(host_max_result_*, encoder_limit(format))` through the same call without reworking the clamp mechanism.

## Module layout (within the existing `ImagePipe.Output` boundary)

`ImagePipe.Output` deps stay `[ImagePipe.Format, ImagePipe.Plan]`. Two additions:

### `ImagePipe.Output.Encoder.encoder_limit/1` — the per-format table

```elixir
@spec encoder_limit(ImagePipe.Plan.output_format()) ::
        %{max_dimension: pos_integer() | :infinity, max_pixels: pos_integer() | :infinity}
```

| format | max_dimension | max_pixels | source |
|--------|---------------|-----------|--------|
| `:webp` | 16383 | `:infinity` | `fix_size.go:14` |
| `:avif` | 16384 | `:infinity` | `fix_size.go:15` |
| `:jpeg` | 65535 | `:infinity` | documented, won't bite |
| `:png` | `:infinity` | `:infinity` | effectively unbounded |

The format table is encoder knowledge and lives **only** in `Output.Encoder`. JPEG/PNG are documented, not special-cased — they fall out of the generic `:infinity` no-op path.

### `ImagePipe.Output.Clamp.clamp/4` — the generic, product-neutral downscale

```elixir
@spec clamp(Vix.Vips.Image.t(), pos_integer() | :infinity, pos_integer() | :infinity, keyword()) ::
        {:ok, Vix.Vips.Image.t(), clamp_info() | nil}
        | {:error, {:encode, term()}}
```

- Knows nothing about formats or hosts — it fits a realized image to a max dimension and/or max pixel budget. This is the seam #165 reuses unchanged (#165 only changes the *limit it passes in*).
- Reads the realized image directly via the `image` library (Vix); it does **not** touch `Transform` or `Telemetry` (which `Output` cannot depend on).
- `opts` carries **`:image_module`** only (defaults to `Image`), matching `Encoder.stream_output/3`'s test-injection convention. Measurement (`Image.width/3`/`Image.height/1`) uses the real `Image` accessors directly, consistent with the producer already calling `Image.has_alpha?/1` directly; the actual resize goes through `image_module.resize/2` so tests can inject. If `opts` reads nothing beyond `:image_module`, no other keys are introduced.

`clamp_info` (returned only when a clamp actually occurs; `nil` otherwise):

```elixir
%{
  scale: float(),                       # < 1.0
  source_dimensions: {pos_integer(), pos_integer()},   # {w, h} before
  dimensions: {pos_integer(), pos_integer()},          # {w, h} after (realized, ≤ limits)
  max_dimension: pos_integer() | :infinity,
  max_pixels: pos_integer() | :infinity
}
```

## Clamp math

```
w = Image.width(image); h = Image.height(image)
dim_scale   = (max_dimension == :infinity) ? 1.0 : min(1.0, max_dimension / max(w, h))     # linear
pixel_scale = (max_pixels    == :infinity) ? 1.0 : min(1.0, sqrt(max_pixels / (w * h)))     # sqrt
scale       = min(dim_scale, pixel_scale)

scale >= 1.0  →  {:ok, image, nil}        # no-op: image unchanged, NO resize node added (stays lazy)
else          →  resize by scale, enforce ≤ limit, return {:ok, resized, clamp_info}
```

For #150 every format passes `max_pixels: :infinity`, so `pixel_scale` is always `1.0` and `scale = dim_scale`: this is **exactly** imgproxy's `fixWebpSize`/`fixHeifSize` (`scale = 1.0 / (max(w,h)/limit)`, linear). The sqrt/pixels branch is structurally present for #165 but **never live in #150** — see Open Decision D1.

**Deliberate divergence from imgproxy's GIF path (latent until #165):** imgproxy's `fixGifSize` takes `max(resShrink, dimShrink)` and then `sqrt`s the *combined* shrink (`fix_size.go:65-72`), so its dimension component is also sqrt'd. We keep dimension linear, pixels sqrt, and take the most-aggressive scale — correct for each constraint independently and identical to imgproxy for our live WebP/AVIF (dimension-only) formats. Zero observable effect in #150. (If D1 defers the pixel path, this note moves to #165.)

### ≤-limit guarantee (defensive; flagged by review #2)

The whole point is that encode cannot fail. `scale = limit / max(w,h)` makes `round(max(w,h) * scale) = round(limit) = limit` in normal float arithmetic, and the shorter axis is strictly smaller — so the realized longest axis is `limit` and within bounds. To make this a **hard guarantee** rather than a trust-the-rounding claim, after the resize the clamp measures the realized longest axis `L'`; if `L' > limit` (a libvips rounding quirk), it re-resizes the **original** image by a corrected `scale * limit / L'`. In practice the corrective branch never fires; it exists so a rounding regression cannot silently re-introduce an encode failure. The wire test asserts the decoded longest axis ≤ limit, catching any regression here.

### Resize error contract (review #3)

`image_module.resize/2` returns `{:ok, image} | {:error, reason}`. `clamp/4` matches `{:ok, resized}` on success and maps a resize failure to `{:error, {:encode, reason}}`, which the producer threads through its existing `with`/`else` (→ `{:stop, {:error, reason}}`) instead of crashing the producer into a generic 500. (A resize failure is effectively impossible here — `scale ∈ (0, 1)` is always valid — but `resize` is an external-library call at the Output boundary, so we return a tagged error rather than relying on the producer's catch-all rescue. The final error tag is reconciled with `ImagePipe.Error.tag/1` during implementation so it maps to a sensible status.)

### Single-frame assumption (review #4)

`Image.width/3`/`Image.height/1` report a single frame's dimensions. If ImagePipe ever emits **animated/multi-page** WebP/AVIF, a vertically-stacked multi-frame image reports stacked height and a naive uniform resize would corrupt frames (imgproxy handles this via `PageHeight`). ImagePipe's `DecodePlanner` loads no extra pages today (no `n:`/pages load option), so output is single-frame and this is a non-issue. The assumption is stated here as a conscious boundary: if multi-page output is added, the clamp must account for page height.

### Alpha / resampling (review #5)

libvips `resize` premultiplies alpha internally, so clamped transparent images do not get dark halos. A plain `Image.resize` (no linear-colourspace conversion) is the correct parity choice — imgproxy's `fixSize` is also a plain `img.Resize`, unlike its main `scale` step. Confirmed against `transform/operation/resize.ex:125`, which resizes the same way.

## Where it runs — the producer seam

In `request/source_session/producer.ex` `prepare_first_chunk/1`, the negotiated `resolved_output.format` and the realized `final_state.image` are both in hand at lines 117–125, between `resolve_output` and `Encoder.stream_output`. The clamp slots in there:

```elixir
with {:ok, decoded} <- ...,
     {:ok, %State{} = final_state} <- Processor.process_decoded_source(...),
     {:ok, %Resolved{} = resolved_output} <- resolve_output(...),
     %{max_dimension: md, max_pixels: mp} = Encoder.encoder_limit(resolved_output.format),
     {:ok, image, clamp_info} <- Clamp.clamp(final_state.image, md, mp, request.opts),
     :ok <- maybe_emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
     {:ok, stream, content_type} <- Encoder.stream_output(image, resolved_output, request.opts),
     {:ok, chunk, stream_state} <- first_chunk(stream) do
  ...
```

- The clamp runs **before** `stream_output`, so `Encoder.finalize`'s `copy_memory` (metadata strip) materializes the already-clamped (smaller) image.
- It runs **after** the transform chain's orientation flush, correctly leaving the flush-buffer materialization optimization to #164.
- **#165 reuse:** only the `encoder_limit` line changes to `min(host_max_result_*, encoder_limit(format))`. The `Clamp.clamp/4` call is untouched. `Clamp` and `Encoder` stay pure functions; telemetry is emitted by the producer (request boundary).

## Telemetry

A one-shot `[:output, :clamp]` event, emitted by the producer **only when `clamp_info` is non-nil** (a clamp actually occurred), via `Telemetry.execute/4`:

- **measurements:** `%{scale: scale}`
- **metadata:** `%{format: format, source_dimensions: {w, h}, dimensions: {w', h'}, max_dimension: md, max_pixels: mp}`

All metadata is non-sensitive (dimensions, format atom, integer limits) — safe to fan out to exporters. No URLs, secrets, or PII.

### Default Logger sync (`telemetry/logger.ex`, per the telemetry guideline)

1. **Subscription.** Add `output: []` to `@group_span_events` (no spans; makes `:output` a selectable group, included in `:all`). Add `@output_oneshot [[:output, :clamp]]` and, in `event_names/2`, `output_oneshots = if :output in groups, do: @output_oneshot, else: []` appended to the attach list.
2. **Rendering.** Add a `message/3` clause for `[:output, :clamp | _]` that surfaces the outcome, e.g. `"image_pipe output clamp: 18000x9000 -> 16383x8191 for webp (max 16383)"`. Placed before the generic fallback.
3. **Level.** Add a `level_for/3` clause returning `:warning` for `[:output, :clamp | _]`, matching imgproxy's `slog.Warn` (`fix_size.go:32,52`).
4. **Coverage.** Add a `logger_test.exs` assertion for the new line; update `docs/telemetry.md` to list the event and its rendering.

## Cache / ETag — no change

The clamp's output is fully deterministic from the request inputs that are **already** in the cache key and ETag: the **source-identity byte-identity seed**, the **canonical plan**, and the **negotiated output format** (`modern_candidates` for automatic, explicit `format` otherwise — confirmed in `cache/key.ex`). The final dimensions are not a key field; they **derive from** those inputs (source + plan), and the clamp threshold derives from the format. Therefore:

- **No new cache key field.** Same key shape; greenfield, no data-version bump.
- **No ETag change.** A conditional GET still returns `304` before any source fetch, decode, encode, or clamp — the clamp never participates in validator derivation.

## Tests (per CLAUDE.md)

### Wire-level imgproxy Plug tests (real `ImagePipe.call/2`)

Mirror the existing result-limit tests in `plug_test.exs`. **Reachability gotcha:** default `max_result_width/height` is 8192, *below* the encoder limits — tests must raise the host result cap above the encoder limit or the clamp is never reached.

- **WebP over 16383:** wide-and-short source enlarged via `el:1`/`w:` to just over 16383 (keeps encoded pixel count tiny/fast), `f:webp`, host `max_result_width/height` raised above 16383. Assert: `status 200`; `content-type: image/webp`; **decode the body and assert the longest axis ≤ 16383 and strictly reduced from the pre-clamp size**; `[:output, :clamp]` telemetry fired with matching `source_dimensions`/`dimensions`.
- **AVIF over 16384:** same shape, `f:avif`, assert longest axis ≤ 16384. (AVIF encode is available in the test lane — `plug_test.exs` already asserts real `image/avif` responses.)
- **No-clamp control:** a WebP request under the limit asserts no `[:output, :clamp]` event and unchanged dimensions.

### Direct unit test of `ImagePipe.Output.Clamp.clamp/4`

Covers the generic contract: dimension-only clamp (linear), pixel-only clamp (sqrt), both-apply (most-aggressive scale wins), and no-op (`scale >= 1.0` → image unchanged + `nil`, no resize node). This is the path that documents the #165 seam. *(Conditional on Open Decision D1 — if the pixel path is deferred, only dimension-only + no-op are tested.)*

## Out of scope / non-changes

- **No demo UI change** — internal output safety clamp, not a user-controllable transform or parser option (no URL knob), so the demo-sync guideline does not apply.
- **No #165** (host error→downscale) and **no #164** (look-ahead pre-clamp).
- **No new architecture test** — staying within the existing `Output` boundary with unchanged deps; the `Boundary` compile check already enforces the namespace rules. No concrete `Transform` operation module is named.

## Open Decision (for the design review)

**D1 — Include the `max_pixels`/sqrt path now, or defer to #165?** In #150 every format returns `max_pixels: :infinity`, so the sqrt branch is dead code and its direct unit test exercises a shape no in-repo producer constructs — which the repo's test guideline flags as a smell, and which fights the "narrowest shape real callers use" / "add when the future caller appears" discipline. Counter: the task instruction is to "structure it so #165 can pass `max_pixels` without rework"; greenfield makes a later `clamp/3 → clamp/4` widening free, so deferral does not preclude #165. **The design as written includes the generic `clamp/4` (per the task instruction); the design review must return an explicit verdict — keep `clamp/4` now or ship dimension-only `clamp/3` and add pixels with its real caller in #165.** If deferred: drop the `max_pixels` param, the sqrt branch, its unit-test cases, and move the GIF-divergence note to #165.
