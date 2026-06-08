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
- Generic clamp seam: takes a `max_dimension` and does not care which source produced the number, so #165 can later feed `min(host_max_result_*, encoder_limit(format))` through the same call without reworking the clamp mechanism. (#165 also adds a `max_pixels` budget — a free `clamp/3 → clamp/4` widening in this greenfield codebase, made live by #165's own caller and test; see Resolved Decision D1.)

## Module layout (within the existing `ImagePipe.Output` boundary)

`ImagePipe.Output` deps stay `[ImagePipe.Format, ImagePipe.Plan]`. Two additions:

### `ImagePipe.Output.Encoder.encoder_limit/1` — the per-format table

```elixir
@spec encoder_limit(ImagePipe.Format.output_format()) :: %{max_dimension: pos_integer() | :infinity}
```

| format | max_dimension | source |
|--------|---------------|--------|
| `:webp` | 16383 | `fix_size.go:14` |
| `:avif` | 16384 | `fix_size.go:15` |
| `:jpeg` | 65535 | documented, won't bite |
| `:png` | `:infinity` | effectively unbounded |

The format table is encoder knowledge and lives **only** in `Output.Encoder`. JPEG/PNG are documented, not special-cased — they fall out of the generic `:infinity`/large no-op path. (#165 will extend the returned map with a `max_pixels` budget when its caller makes that constraint live; #150 returns only `max_dimension`.)

### `ImagePipe.Output.Clamp.clamp/3` — the generic, product-neutral downscale

```elixir
@spec clamp(Vix.Vips.Image.t(), pos_integer() | :infinity, keyword()) ::
        {:ok, Vix.Vips.Image.t(), clamp_info() | nil}
        | {:error, {:encode, Exception.t(), list()}}
```

- Knows nothing about formats or hosts — it fits a realized image to a max dimension. This is the seam #165 reuses (#165 changes the *limit it passes in*, and widens the signature to add a `max_pixels` budget with its own caller/test).
- Reads the realized image directly via the `image` library (Vix); it does **not** touch `Transform` or `Telemetry` (which `Output` cannot depend on).
- `opts` carries **`:image_module`** only (defaults to `Image`), matching `Encoder.stream_output/3`'s test-injection convention. Measurement (`Image.width/1`/`Image.height/1`) uses the real `Image` accessors directly (O(1) header reads, no pixel realization), consistent with the producer already calling `Image.has_alpha?/1` directly; the actual resize goes through `image_module.resize/2` so tests can inject. No other `opts` keys are introduced.

`clamp_info` (returned only when a clamp actually occurs; `nil` otherwise):

```elixir
%{
  scale: float(),                       # < 1.0
  source_dimensions: {pos_integer(), pos_integer()},   # {w, h} before
  dimensions: {pos_integer(), pos_integer()},          # {w, h} after (realized, ≤ limit)
  max_dimension: pos_integer()
}
```

## Clamp math

```
w = Image.width(image); h = Image.height(image)
scale = (max_dimension == :infinity) ? 1.0 : min(1.0, max_dimension / max(w, h))     # linear, uniform

scale >= 1.0  →  {:ok, image, nil}        # no-op: image unchanged, NO resize node added (stays lazy)
else          →  resize by scale, enforce ≤ limit, return {:ok, resized, clamp_info}
```

This is **exactly** imgproxy's `fixWebpSize`/`fixHeifSize` (`scale = 1.0 / (max(w,h)/limit)`, a uniform linear downscale). JPEG (`65535`) and PNG (`:infinity`) take the no-op path for any realizable image. The pixel/resolution constraint and its sqrt scaling (imgproxy's GIF path) are **out of scope** here — see #165 and Resolved Decision D1.

### ≤-limit guarantee (defensive; review correctness Lens 1)

The whole point is that encode cannot fail. `scale = limit / max(w,h)` makes `round(max(w,h) * scale) = round(limit) = limit` in normal float arithmetic, and the shorter axis is strictly smaller — so the realized longest axis is `limit`, within bounds. To make this a **hard guarantee** rather than a trust-the-rounding claim, after the resize the clamp measures the realized longest axis `L'`; if `L' > limit` (a libvips rounding quirk), it re-resizes the **original** image by a **floor-biased** corrected factor — derived so the corrected longest axis cannot round back over `limit` (e.g. target `limit` px via a factor computed against `L'` and floored, not rounded). In practice the corrective branch never fires; it exists so a rounding regression cannot silently re-introduce an encode failure. The wire test asserts the decoded longest axis ≤ limit, catching any regression here.

### Resize error contract (review correctness Lens 2 — was a blocker)

`image_module.resize/2` returns `{:ok, image} | {:error, reason}`. `clamp/3` matches `{:ok, resized}` on success and maps a resize failure to **`{:error, {:encode, exception, stacktrace}}`** — the same 3-tuple shape the encoder already emits (`encoder.ex:11,21`). A resize `reason` is a term, not an exception, so it is wrapped: `{:encode, RuntimeError.exception("clamp resize failed: #{inspect(reason)}"), []}`, mirroring `runner.ex:205`'s existing `{:session, reason}` wrapping. This is **required**: the response layer's `handle_processing_error/3` (`response/sender.ex`) only has `:encode` clauses for the 3-tuple and the `:empty_stream` literal — a bare `{:encode, reason}` 2-tuple matches no clause and raises `FunctionClauseError` (a crash, not a 500). The 3-tuple routes through `handle_encode_exception` → 500. (`ImagePipe.Error.tag/1` only extracts the leading atom for telemetry; it does not participate in status routing, so the emitted *shape* must be correct at the source.) A resize failure is effectively impossible — `scale ∈ (0, 1)` is always valid — but `resize` is an external-library call at the Output boundary, so we return the tagged error rather than relying on the producer's catch-all rescue.

### Single-frame assumption (review #4)

`Image.width/1`/`Image.height/1` report a single frame's dimensions. If ImagePipe ever emits **animated/multi-page** WebP/AVIF, a vertically-stacked multi-frame image reports stacked height and a naive uniform resize would corrupt frames (imgproxy handles this via `PageHeight`). ImagePipe's `DecodePlanner` loads no extra pages today (no `n:`/pages load option), so output is single-frame and this is a non-issue. The assumption is stated here as a conscious boundary: if multi-page output is added, the clamp must account for page height.

### Alpha / resampling (review #5)

libvips `resize` premultiplies alpha internally, so clamped transparent images do not get dark halos. A plain `Image.resize` (no linear-colourspace conversion) is the correct parity choice — imgproxy's `fixSize` is also a plain `img.Resize`, unlike its main `scale` step. Confirmed against `transform/operation/resize.ex:125`, which resizes the same way.

## Where it runs — the producer seam

In `request/source_session/producer.ex` `prepare_first_chunk/1`, the negotiated `resolved_output.format` and the realized `final_state.image` are both in hand at lines 117–125, between `resolve_output` and `Encoder.stream_output`. The clamp slots in there:

```elixir
with {:ok, decoded} <- ...,
     {:ok, %State{} = final_state} <- Processor.process_decoded_source(...),
     {:ok, %Resolved{} = resolved_output} <- resolve_output(...),
     %{max_dimension: md} = Encoder.encoder_limit(resolved_output.format),
     {:ok, image, clamp_info} <- Clamp.clamp(final_state.image, md, request.opts),
     :ok <- maybe_emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
     {:ok, stream, content_type} <- Encoder.stream_output(image, resolved_output, request.opts),
     {:ok, chunk, stream_state} <- first_chunk(stream) do
  ...
```

- The clamp runs **before** `stream_output`, so `Encoder.finalize`'s `copy_memory` (metadata strip) materializes the already-clamped (smaller) image.
- It runs **after** the transform chain's orientation flush, correctly leaving the flush-buffer materialization optimization to #164.
- **#165 reuse:** the `encoder_limit` line changes to `min(host_max_result_*, encoder_limit(format))`, and #165 widens the call to pass its `max_pixels` budget (`clamp/3 → clamp/4`). The clamp *mechanism* (uniform downscale + ≤-limit guarantee) is untouched. `Clamp` and `Encoder` stay pure functions; telemetry is emitted by the producer (request boundary).

## Telemetry

A one-shot `[:output, :clamp]` event, emitted by the producer **only when `clamp_info` is non-nil** (a clamp actually occurred), via `Telemetry.execute/4`:

- **measurements:** `%{scale: scale}` (`scale` is a genuine numeric measurement, so measurements is its correct home — cf. `[:cache, :eviction]` reading `measurements[:count]`)
- **metadata:** `%{format: format, source_dimensions: {w, h}, dimensions: {w', h'}, max_dimension: md}`

All metadata is non-sensitive (dimensions, format atom, integer limit) — safe to fan out to exporters. No URLs, secrets, or PII.

### Default Logger sync (`telemetry/logger.ex`, per the telemetry guideline)

1. **Subscription.** Add `output: []` to `@group_span_events` (no spans; makes `:output` a selectable group, included in `:all`). Add `@output_oneshot [[:output, :clamp]]` and, in `event_names/2`, `output_oneshots = if :output in groups, do: @output_oneshot, else: []` appended to the attach list.
2. **Rendering.** Add a `message/3` clause for `[:output, :clamp | _]`, e.g. `"image_pipe output clamp: 18000x9000 -> 16383x8191 for webp (max 16383)"`, placed before the generic fallback. The message *is* the outcome (a downscale occurred) — analogous to the `[:transform, :detect, :blend]` clause, which also omits a separate `outcome/1` because the event encodes a single known outcome. No `:result` key is emitted in clamp metadata, so nothing is swallowed (satisfies the "surface the outcome" guideline).
3. **Level.** Add a `level_for/3` clause returning `:warning` for `[:output, :clamp | _]`, matching imgproxy's `slog.Warn` (`fix_size.go:32,52`).
4. **Coverage.** Add a `logger_test.exs` assertion for the new line; update `docs/telemetry.md` to list the event and its rendering.

## Cache / ETag — no change

The clamp's output is fully deterministic from the request inputs that are **already** in the cache key and ETag: the **source-identity byte-identity seed**, the **canonical plan**, and the **negotiated output format** (`modern_candidates` for automatic, explicit `format` otherwise — confirmed in `cache/key.ex`). The final dimensions are not a key field; they **derive from** those inputs (source + plan), and the clamp threshold derives from the format. Therefore:

- **No new cache key field.** Same key shape; greenfield, no data-version bump.
- **No ETag change.** A conditional GET still returns `304` before any source fetch, decode, encode, or clamp — the clamp never participates in validator derivation.

## Tests (per CLAUDE.md)

### Wire-level imgproxy tests (real `ImagePipe.call/2`)

These go in **`test/image_pipe/imgproxy_wire_conformance_test.exs`**, not `plug_test.exs`. Asserting *decoded* clamped dimensions requires the real `Image` module + a real encode; the conformance file's `call_imgproxy` path uses the real encoder and already has the body-decode helpers `dimensions/1` (`Image.open!(resp_body, access: :random, fail_on: :error)` → `{width, height}`) and `content_type/1`. `plug_test.exs`'s result-limit tests use `image_module: StreamingOnlyImage`, whose `stream!/2` returns the literal `"streamed jpeg"` — an **undecodable** body — so they cannot assert decoded dims.

**Reachability gotcha:** default `max_result_width/height` is 8192 (`request/options.ex`), *below* the encoder limits — tests must raise the host result cap above the encoder limit or `check_result_*` 413s first and the clamp is never reached.

- **WebP over 16383:** wide-and-short source enlarged via `el:1`/`w:` to just over 16383 (keeps encoded pixel count tiny/fast), `f:webp`, host `max_result_width/height` raised above 16383. Assert: `status 200`; `content-type: image/webp`; **decode the body and assert the longest axis ≤ 16383 and strictly reduced from the pre-clamp size**; `[:output, :clamp]` telemetry fired (in-test attached handler) with matching `source_dimensions`/`dimensions`.
- **AVIF over 16384:** same shape, `f:avif`, assert longest axis ≤ 16384. (AVIF encode is available in the test lane — the conformance file already asserts real `image/avif` responses with non-empty bodies.)
- **No-clamp control:** a WebP request under the limit asserts no `[:output, :clamp]` event and unchanged dimensions.

### Direct unit test of `ImagePipe.Output.Clamp.clamp/3`

Covers the generic contract: dimension clamp (linear, uniform), the no-op path (`scale >= 1.0` → image unchanged + `nil`, no resize node), and the ≤-limit guarantee (a result whose longest axis equals the limit). Every case uses an input shape a real producer constructs (a realized image + an integer/`:infinity` `max_dimension`), so none pins an impossible-misuse shape.

## Out of scope / non-changes

- **No demo UI change** — internal output safety clamp, not a user-controllable transform or parser option (no URL knob), so the demo-sync guideline does not apply.
- **No #165** (host error→downscale) and **no #164** (look-ahead pre-clamp).
- **No new architecture test** — staying within the existing `Output` boundary with unchanged deps; the `Boundary` compile check already enforces the namespace rules. No concrete `Transform` operation module is named.

## Resolved Decision D1 — pixel/sqrt path deferred to #165

The design review (four disjoint lenses, incl. the mandatory imgproxy-compat lens) returned a **unanimous verdict to defer** the `max_pixels`/sqrt path, and the user confirmed. Ship dimension-only **`clamp/3`**. Rationale:

- In #150 every format's limit is dimension-only, so a sqrt/pixels branch would be dead code, and its only unit test would feed a `max_pixels` value **no in-repo producer constructs** — the exact "impossible-internal-misuse" shape CLAUDE.md's test guideline bans, and a violation of "constructor APIs accept the narrowest shape real callers use / add when the future caller appears."
- Greenfield makes the later `clamp/3 → clamp/4` widening free (no compat cost), so deferral does **not** preclude #165; #165 adds `max_pixels` together with its real caller and a test that exercises it.
- The compat lens confirmed deferral has **zero** effect on #150's imgproxy parity (WebP/AVIF are dimension-only; the live linear `dim_scale` is byte-for-byte-intent identical to `fixWebpSize`/`fixHeifSize` whether `clamp/3` or `clamp/4` ships).

### Hand-off note for #165 (pixel/resolution clamp)

When #165 adds the `max_pixels` budget, keep **dimension linear, pixels sqrt, and take the most-aggressive scale** — do **not** copy imgproxy's `fixGifSize` combined-sqrt (`fix_size.go:65-72`), which `sqrt`s even the dimension component and therefore **can leave the result over the dimension limit when the dimension constraint binds** (e.g. a very wide, low-pixel GIF). ImagePipe's linear-dimension choice is strictly safer (it always respects the hard dimension cap); this is a deliberate, more-correct divergence, not a parity gap to "fix" back to upstream. (GIF is not an ImagePipe output format today regardless.)
