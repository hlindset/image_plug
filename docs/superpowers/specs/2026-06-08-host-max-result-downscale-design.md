# Host `max_result_*` error→downscale (imgproxy `limitScale` parity) — Design

**Issue:** #165. **Builds on:** #150 / #166 (the generic `ImagePipe.Output.Clamp` seam, merged to `main`).
**Verified imgproxy reference:** `local/imgproxy-master/processing/prepare.go:222-265` (`limitScale`).

## Summary

Today the host result-dimension cap is an **error**: `ImagePipe.Request.Processor.validate_result_image/2`
(`check_result_width/height/pixels`) returns `{:error, {:result_limit, …}}` → **413** when the realized
image exceeds `max_result_width` / `max_result_height` / `max_result_pixels`. This change makes the cap a
**uniform downscale-to-fit and serve**, matching imgproxy's `limitScale`, by **reusing #150's
`ImagePipe.Output.Clamp`** at the producer seam: the host caps fold into the same clamp call via
`min(host_cap, encoder_limit(format))`. The error path (`check_result_*`, the `{:result_limit, …}` tag, and
its 413) is **deleted**. `max_input_pixels` (the decode-time image-bomb gate) remains the only hard error —
mirroring imgproxy's split (it downscales the output cap but hard-errors `MaxSrcResolution`).

This is the same mechanism as #150 with a different *limit source* (host config, format-independent, rather
than the output encoder, format-dependent). The clamp does not care which source won the `min`.

## Resolved decisions (from brainstorming)

| Decision | Resolution | Rationale |
|---|---|---|
| **Cap geometry** | **Per-axis (independent)** width/height + pixels | imgproxy's `limitScale` has a single `MaxResultDimension`; ImagePipe exposes *separate* `max_result_width`/`max_result_height`/`max_result_pixels`. Collapsing to one square cap would **over-shrink** (a behavior change) when caps are asymmetric — e.g. `max_w=10000, max_h=4000`, an `8000x4000` image passes untouched today but a square `min(10000,4000)=4000` clamp would reduce it. Per-axis preserves the no-op boundary. |
| **Hard ceiling** | **None** — pure downscale | The output cap purely downscales; `max_input_pixels` remains the only hard error. Matches imgproxy (`limitScale` never errors; only `MaxSrcResolution` does). Removes `check_result_*` + 413 entirely. |
| **Observability** | **Telemetry only** | Reuse/extend the existing `[:output, :clamp]` one-shot (the #150 mechanism). imgproxy only `slog.Warn`-logs the downscale and sets **no** response header. No new public response surface. |
| **Decode fold** | **Split to follow-up** | Land the post-hoc clamp (the correctness path) now; defer the shrink-on-load decode-work optimization (extend `DecodePlanner` toward `min(resize_target, host_limit)`, declining under trim) to its own issue/PR. The issue explicitly permits this split. |

## Architecture

### Single encode path (verified)

`ImagePipe.Output.Clamp.clamp/3` is called **only** at
`lib/image_pipe/request/source_session/producer.ex:127`, and
`Processor.process_decoded_source/3` is reached **only** through the producer
(`producer.ex:117`). The producer is the sole encode path, so moving the result-dimension policy out of
`Processor.validate_result_image/2` and into the `Output.Clamp` seam loses no coverage: there is no second
path that encodes an un-clamped image.

### Clamp seam — widen to per-axis + pixels

`ImagePipe.Output.Clamp.clamp/3` keeps **arity 3**, but its second argument becomes a **limits descriptor**
instead of a single square `max_dimension`. This honors ImagePipe's three independent host options and folds
in the encoder's per-format limit.

```elixir
@type limits :: %{
        max_width: pos_integer() | :infinity,
        max_height: pos_integer() | :infinity,
        max_pixels: pos_integer() | :infinity
      }

@spec clamp(VixImage.t(), limits(), keyword()) ::
        {:ok, VixImage.t(), clamp_info() | nil}
        | {:error, {:encode, Exception.t(), list()}}
```

The descriptor is a plain map (not a struct): it is constructed by the producer and consumed by the clamp,
both in-repo — no external boundary, so no validation is needed (per the *Validation guidelines*: trust what
another module in this codebase just produced). A struct would force either a nested module (banned —
"Avoid nesting multiple modules in the same file") or a new file for three fields; a typed map is lighter and
matches `Encoder.encoder_limit/1`'s existing map return.

**Scale math — dimension linear (per-axis), pixels sqrt, take the most-aggressive scale.** This is exactly
the #150 hand-off note. It is deliberately **not** imgproxy's `fixGifSize` combined-sqrt
(`fix_size.go:65-72`), which `sqrt`s the dimension component too and can leave a result over the dimension
limit when the dimension constraint binds.

```
w = Image.width(image); h = Image.height(image); px = w * h

wscale = (max_width  == :infinity) or (w  <= max_width)  -> 1.0 ; else max_width  / w
hscale = (max_height == :infinity) or (h  <= max_height) -> 1.0 ; else max_height / h
pscale = (max_pixels == :infinity) or (px <= max_pixels) -> 1.0 ; else :math.sqrt(max_pixels / px)

scale = min(1.0, wscale, hscale, pscale)            # most-aggressive constraint wins

scale >= 1.0  ->  {:ok, image, nil}                 # no-op: image unchanged, NO resize node (stays lazy)
else          ->  resize by scale, enforce caps, return {:ok, resized, clamp_info}
```

When all three caps are `:infinity` (or non-binding) the no-op path is taken — preserving the existing
JPEG/PNG behavior. When `max_width == max_height` (the default 8192/8192) and only dimension binds, the math
reduces to `max_dimension / max(w, h)` — byte-intent identical to imgproxy's `limitScale` linear downscale.

**≤-cap guarantee.** The **dimension** caps are satisfied **by construction** and need no corrective pass:
the primary scale is the most-aggressive per-axis ratio, so each axis lands ≤ its cap — the binding axis
exactly on its cap (`round(d · max_d/d) = max_d` for integer `max_d`), and the other axis is scaled by the
same-or-smaller factor, so `other · scale ≤ max_other`. (#150's single-axis linear corrective is therefore
dropped; it was only ever a defensive no-op for the dimension case.)

The **pixel** cap is the one real subtlety — flagged by the design review (clamp-math lens) as a blocker in
the original closed-form draft. After an isotropic resize the realized pixel count is
`round(w·s) · round(h·s)`: a product of two *independently* rounded factors. A closed-form
`s = sqrt(max_pixels / (w·h))` (or any fixed-epsilon variant like `sqrt((max_pixels − 0.5)/(w·h))`) does
**not** guarantee `round(w·s)·round(h·s) ≤ max_pixels` — the two roundings can each add ~0.5px, injecting
≈ `0.5·(w·s + h·s)` extra area, which for any non-tiny image dwarfs a half-pixel epsilon (verified
overshoots of thousands of pixels for large/extreme-aspect images; **unbounded** overshoot when the short
axis floors to 1px, where a single scalar can never satisfy a *product* cap). So the pixel cap is enforced
by a **bounded verify-and-shrink loop on the realized image**, not a closed form:

```
enforce(original, resized, limits, max_iters):
  rw, rh = realized(resized)
  if within_all_caps?(rw, rh, limits): return {:ok, resized}        # common case: pixels not binding
  if max_iters == 0: return {:error, {:encode, <pixel-enforce-exhausted>, []}}   # bounded escape → 500
  long_real  = max(rw, rh); short_real = min(rw, rh)                # short_real ≥ 1
  # aspect-preserving long-axis target that fits the pixel budget, plus the long axis's own dim cap,
  # and a strict −1 progress floor so the loop always advances at least one pixel:
  t_pixels = (max_pixels == :infinity) -> long_real
             else floor(:math.sqrt(max_pixels * long_real / short_real))
  t_dim    = long-axis dimension cap (max_width or max_height, whichever axis is longer; :infinity → long_real)
  target_long = min(long_real - 1, t_pixels, t_dim)
  s = (target_long + 0.49) / max(orig_w, orig_h)                    # rounds the long axis to target_long
  enforce(original, resize(original, s), limits, max_iters - 1)
```

- The `floor(sqrt(max_pixels · long/short))` target preserves the realized aspect, so it lands the product
  near the budget in **one step** for realistic caps; the `min(long_real − 1, …)` floor guarantees ≥1px of
  progress per iteration, so the loop **always terminates**, even in the 1px-floored regime (where it
  converges geometrically toward the cap, e.g. an absurd `max_result_pixels = 100` on a `40000×1` source
  settles in ~8 steps). `max_iters` is set with ample margin (e.g. 16) so realistic configs finish in one
  iteration and only pathological tiny caps could exhaust it; exhaustion returns the standard `{:encode, …}`
  error contract (→ 500), an acceptable outcome for a misconfiguration that asks for a few-pixel result.
- The loop checks **all** caps each iteration (`within_all_caps?`) and resizes from the **original** every
  time (never the already-resized image, to avoid compounding rounding). Because it only ever shrinks, the
  dimension caps stay satisfied throughout.
- The exact stepping constants are an implementation detail **pinned by a property test** (see Tests): the
  realized `w ≤ max_width`, `h ≤ max_height`, **and** `w·h ≤ max_pixels` after `clamp/3`, across a grid of
  sizes, extreme aspect ratios, and small/large pixel caps including the 1px-floor regime, plus a
  termination self-check within the iteration bound.

The `resize` helper applies a **per-axis 1px floor** — `hscale = max(scale, 1/w)`, `vscale = max(scale, 1/h)`
— so no axis ever rounds below one realized pixel. This is needed because for an extreme aspect ratio with a
tight cap the uniform `scale` can drive the *short* axis to 0 (e.g. `40000×1` with `max_width:100` →
`round(1·0.0025)=0`); the floor pins the short axis at 1px while the long axis shrinks, and the verify-shrink
loop then reduces the long axis until the product fits. This is the **equivalent of imgproxy's**
`WScale ≥ 1/widthToScale` floor (`prepare.go:252-258`) — so ImagePipe matches rather than diverges here.

**`clamp_info`** (returned only when a clamp actually occurs; `nil` otherwise) replaces `max_dimension` with
the effective `limits` applied:

```elixir
%{
  scale: float(),                                     # realized rw / w
  source_dimensions: {pos_integer(), pos_integer()},  # {w, h} before
  dimensions: {pos_integer(), pos_integer()},         # {w, h} after (realized, ≤ all caps)
  limits: limits()                                     # the effective caps applied
}
```

`opts` continues to carry only `:image_module` (defaults to `Image`), matching the existing convention;
measurement uses the real `Image.width/1`/`Image.height/1` accessors (O(1) header reads), the resize goes
through `image_module.resize/2`. The resize-error contract is **unchanged** from #150: a resize failure maps
to `{:error, {:encode, exception, stacktrace}}` (the 3-tuple the response layer routes to 500).

### Producer wiring — effective limits

`ImagePipe.Output.Encoder.encoder_limit/1` gains a `:max_pixels` key (`:infinity` for all four current
formats — now live, per the #150 placeholder note). The producer computes the per-axis effective caps by
intersecting host config with the encoder limit:

```elixir
defp effective_limits(format, opts) do
  %{max_dimension: enc_dim, max_pixels: enc_px} = Encoder.encoder_limit(format)

  %{
    max_width:  min_limit(Keyword.fetch!(opts, :max_result_width),  enc_dim),
    max_height: min_limit(Keyword.fetch!(opts, :max_result_height), enc_dim),
    max_pixels: min_limit(Keyword.fetch!(opts, :max_result_pixels), enc_px)
  }
end

# `:infinity` means "no encoder limit"; host caps are always integers (NimbleOptions
# pos_integer defaults), so today every effective cap resolves to the host integer.
defp min_limit(a, :infinity), do: a
defp min_limit(:infinity, b), do: b
defp min_limit(a, b), do: min(a, b)
```

The producer's `with` chain replaces the two `max_dimension` lines:

```elixir
# before (#150):
#   %{max_dimension: max_dimension} = Encoder.encoder_limit(resolved_output.format),
#   {:ok, image, clamp_info} <- Clamp.clamp(final_state.image, max_dimension, request.opts),
# after (#165):
     limits = effective_limits(resolved_output.format, request.opts),
     {:ok, image, clamp_info} <- Clamp.clamp(final_state.image, limits, request.opts),
```

`effective_limits/2` and `min_limit/2` live in the producer (the request boundary, which legitimately reads
`opts` and calls `Output`). `Clamp` and `Encoder` stay pure, format/host-agnostic functions.

With the default `max_result_*` = 8192/8192/40M, the clamp now triggers at the **host** cap — the commonly
hit path, unlike #150's encoder-only niche (which only fired when an admin raised the host cap above the
encoder limit).

### Removals (the error path)

| Location | Removed |
|---|---|
| `lib/image_pipe/request/processor.ex` | `validate_result_image/2` (and its call in `process_decoded_source`'s `with`), `check_result_width/2`, `check_result_height/2`, `check_result_pixels/2` |
| `lib/image_pipe/response/sender.ex` | the `{:result_limit, error}` `handle_processing_error` clause and `send_result_limit_error/3` (413 "result image is too large") |
| `test/image_pipe/processor_test.exs` | "process_source rejects final images wider than configured result limit" (asserts `{:result_limit, …}`) |
| `test/image_pipe/plug_test.exs` | "rejects static result dimensions above configured limits before encoding" (asserts 413 + `refute_received :stream_encoder_called`) — replaced by a downscale wire test (see Tests) |

`max_input_pixels` 413 handling (`{:input_limit, …}` → `send_input_limit_error/3`) is **untouched**, as are
its tests (`plug_test.exs` "source image is too large", `telemetry_test.exs` input-pixel limit,
`shrink_on_load_test.exs` oversized-JPEG).

### Telemetry — reuse `[:output, :clamp]`

The single existing `[:output, :clamp]` one-shot is kept. Only the metadata changes: `max_dimension:`
(scalar) → `limits:` (the effective caps map). The event fires once per request when a clamp occurs,
regardless of whether the host cap or the encoder limit bound — the event does **not** distinguish the source
of the `min`. (The issue floated distinguishing host-cap vs encoder-cap "if useful"; we judge it not worth
the extra branch — the effective caps and the before/after dimensions are the observable facts a host needs.)

- **measurements:** `%{scale: scale}` (unchanged).
- **metadata:** `%{format: format, source_dimensions: {w, h}, dimensions: {w', h'}, limits: limits}`.

All metadata stays non-sensitive (dimensions, format atom, integer/`:infinity` caps). The clamp event remains
**outcome-free** by design: it carries no `:result`/error field — a downscale *is* the single known outcome,
fully expressed by the before→after dimensions + caps, and its severity is carried structurally by
`level_for/3`'s hard-coded `:warning` (not by a metadata field). This satisfies the *Telemetry guidelines*
"must surface the outcome" rule without an `outcome/1` projection; a future editor must not add a `:result`
field without also threading it into the message.

**Default Logger sync** (`telemetry/logger.ex`, per the *Telemetry guidelines*): update the existing
`message/3` clause for `[:output, :clamp | _]` to render the new `limits` shape, e.g.
`"image_pipe output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)"`. Render
`:infinity` caps gracefully (e.g. `px:∞` / `px:none`) rather than interpolating the raw atom — today
`min_limit/2` resolves effective caps to host integers, but a future format/host combo could leave one
`:infinity`. Level stays `:warning`. Update the `logger_test.exs` assertion (its `max_dimension: 16_383`
metadata and `(max 16383)` substring → the `limits` shape) and `docs/telemetry.md`. Also update
`clamp.ex`'s `@type clamp_info` and `@spec` (drop `max_dimension`, add `limits`).

### Cache / ETag — no change

`max_result_*` stays out of **both** the cache key (`ImagePipe.Cache.Key`) and the ETag
(`ImagePipe.Request.HttpCache`, `"ip{schema}-{hash}"`). Confirmed: `max_result_*` appears in `lib/` only in
the (to-be-deleted) `check_result_*` code — absent from `cache/key.ex` and `http_cache.ex`.

**Subtlety flagged for the compat/cache reviewer:** #165 turns `max_result_*` from a *pure generation gate*
(decides whether a miss may generate) into something that *shapes the output bytes* (downscales them). It is
still **not storage identity**:

- It is **deployment config**, not a request input. Output stays canonical per `(source identity + plan +
  negotiated format)` for a given deployment — there is still exactly one output variant per request, so
  `max_result_*` is not a selector among variants.
- This matches **#150 exactly**: the encoder limit also shapes output bytes (downscales) and is also unkeyed
  — it derives from the negotiated format, already in the key.
- It matches CLAUDE.md's *Cache guidelines*: "Keep safety limits (`max_body_bytes`, `max_input_pixels`,
  static result dimension limits) out of both … those decide whether a cache miss may generate a response."
- A config change is out-of-band: an operator who lowers `max_result_*` and wants old (larger) entries gone
  bumps the cachebuster / data-version — the same posture already in effect for `max_input_pixels` changes,
  which likewise don't bust the cache.

The ETag still returns `304` before any source fetch/decode/encode/clamp; the clamp never participates in
validator derivation.

## imgproxy parity & deliberate divergences (compat)

Verified against `local/imgproxy-master/processing/prepare.go:222-265`:

- **Dimension, equal caps:** `limitScale` computes `downScale = maxResultDim / max(outWidth, outHeight)`
  (`prepare.go:247`) — a uniform linear downscale on the longest axis. ImagePipe's per-axis math reduces
  to exactly this when `max_width == max_height` and dimension binds. ✅ byte-intent identical **in the
  no-padding / no-extend / DPR=1 case** (see the composition divergence below).
- **Deliberate divergences — ImagePipe is a strict superset:**
  - imgproxy's `limitScale` has a **single** `MaxResultDimension` applied to both axes; ImagePipe honors
    **independent** `max_result_width` / `max_result_height`. More granular; strictly safer (never exceeds
    either axis cap, never over-shrinks within them).
  - imgproxy's `limitScale` has **no pixel/resolution cap** — its resolution gate (`MaxSrcResolution`) is
    *input*-side only. ImagePipe additionally honors a **result** pixel cap (`max_result_pixels`, sqrt
    shrink). This has no `limitScale` counterpart; it is an ImagePipe-specific output safety knob. The sqrt
    choice (dimension linear, pixels sqrt, most-aggressive) is the #150 hand-off recommendation, **not**
    `fixGifSize`'s combined-sqrt.
  - **Clamp point — composited result vs. fold-back into the resize scale (behavioral/pixel divergence).**
    imgproxy's `limitScale` does *not* clamp the realized output: it computes the cap against a *projected*
    output dimension that includes extend and padding (`prepare.go:230-244`), then folds the downscale back
    into `WScale`/`HScale`/`DprScale` and re-runs `calcSizes` (`prepare.go:249-263`) — so the image content
    is re-resized and padding/extend is re-applied at the reduced scale. ImagePipe instead clamps the
    **already-composited** final image (content **with** extend/padding/background baked in, matrix stages
    10–12) uniformly at the Output boundary. For the common no-padding/no-extend/DPR=1 request the two are
    byte-intent identical; when padding or extend is present both still land ≤ cap, but the internal
    content-to-padding composition differs (ImagePipe scales the composite as one unit; imgproxy scales
    content then re-applies scaled padding). This is documented as a deliberate "Diverges" note in the
    conformance doc.
  - ImagePipe **matches** imgproxy's sub-1px floor (`prepare.go:252-258`): the `resize` helper pins each axis
    at ≥ 1 realized pixel (`hscale = max(scale, 1/w)`, `vscale = max(scale, 1/h)`), the equivalent of
    imgproxy's `WScale ≥ 1/widthToScale`. (Not a divergence — listed for completeness.)
- **Input gate stays a hard error:** `max_input_pixels` ↔ `MaxSrcResolution` (checked on the loaded source at
  `processing.go:114`, *before* `transformImage`/`limitScale`) — mirrors imgproxy's split (downscale the
  output cap, hard-error the input gate). ✅

These divergences are documented in `docs/imgproxy_support_matrix.md` as more-granular, strictly-safe
choices, in the same spirit as #150's linear-dimension divergence from `fixGifSize`.

## Tests (per CLAUDE.md)

### Direct unit tests — `test/image_pipe/output/clamp_test.exs`

Extend the existing file. Every case uses a producer-constructible shape (realized image + a limits map of
integers/`:infinity`):

- width binds (per-axis): `max_width` small, `max_height`/`max_pixels` large → scale = `max_width/w`.
- height binds (per-axis): symmetric.
- pixels bind: dims within `max_width`/`max_height` but `w*h > max_pixels` → dimensions reduced, realized
  `w'*h' <= max_pixels`.
- most-aggressive: a shape where pixel and dimension constraints disagree → the smaller scale wins.
- no-op: within all caps (and all-`:infinity`) → `{:ok, image, nil}`, no resize node; cap exactly equal to a
  dimension is a no-op (no degenerate resize).
- ≤-cap guarantee: realized longest axis == its cap and realized pixels ≤ pixel cap.
- `clamp_info.scale` faithfulness: on a pixel-bound clamp, `rw/w == rh/h` (within fp tolerance) — the resize
  is isotropic, so the reported scalar is not a half-truth.

**Pixel ≤-cap property test** (the blocker fix from review — `StreamData`, the *correctness gate* per CLAUDE.md
"Add StreamData property tests when correctness depends on invariants across many input shapes"): over a grid
of widths/heights (including extreme aspect ratios and 1×N / N×1 shapes) × small-and-large `max_pixels`
(including caps small enough to force the short axis to 1px), assert after `clamp/3` that realized
`w ≤ max_width`, `h ≤ max_height`, **and** `w*h ≤ max_pixels`, and that the enforce loop terminates within its
iteration bound. This is the test that would have caught the closed-form overshoot; it pins the loop, not the
exact stepping constants.

### Wire conformance — `test/image_pipe/imgproxy_wire_conformance_test.exs`

Real `ImagePipe.call/2` + real encode + body decode (the file already has `dimensions/1`/`content_type/1`):

- **Default-cap downscale:** a request that realizes above 8192 on an axis (e.g. `el:1`/`w:` enlarge),
  `f:jpeg`, **default** host caps → `200`, decode body, longest axis ≤ 8192 and strictly reduced,
  `[:output, :clamp]` fired with matching `source_dimensions`/`dimensions`/`limits`.
- **Asymmetric caps (per-axis):** raise one axis cap, lower the other; assert the result fits both and is not
  over-shrunk (a case that the square-collapse alternative would get wrong).
- **Pixel-cap downscale:** dims within width/height caps but over `max_result_pixels` → decoded `w*h ≤
  max_result_pixels`, `[:output, :clamp]` fired.
- **No-clamp control:** a request under all caps → no `[:output, :clamp]` event, unchanged dimensions.
- Update #150's existing encoder-clamp conformance tests if they assert `max_dimension` metadata → `limits`.

### Converted / deleted error tests (full inventory — completed per review)

- `plug_test.exs` "rejects static result dimensions above configured limits before encoding" (~2051) → a
  downscale assertion (200 + clamp). The new behavior decodes and re-encodes, so it is expressed against the
  real encoder in the conformance file (the old test used `StreamingOnlyImage`, whose body is undecodable,
  and asserted `refute_received :stream_encoder_called`, which no longer holds — encode now runs).
- `processor_test.exs` "process_source rejects final images wider than configured result limit" (~181) →
  **deleted** (the function is gone; clamp behavior is covered by `clamp_test.exs` + wire tests).
- `processor_test.exs` "process_source accepts final images within configured result limits" (~197) →
  **deleted** (it sets `max_result_*` and asserts a property `process_source` no longer owns — `max_result_*`
  no longer participates there; keeping it would be a post-migration parity pin on a coincidental pass).
- `plug_test.exs` "allows static result dimensions within configured limits" (~2069, `StreamingOnlyImage`,
  asserts `:stream_encoder_called`) → **kept as a no-clamp control**: `max_result_width: 64` == realized
  `w:64` so the producer's now-unconditional `Clamp.clamp` no-ops (no resize node) and the stub still streams
  through. Verify it still passes unchanged after the wiring lands; it usefully exercises the no-op path on
  the streaming stub.

## Docs

- `docs/imgproxy_support_matrix.md`:
  - Row 113 (host result-dimension cap) ⚠️ → ✅, pointing at the `Output.Clamp` reuse with `min(host,
    encoder)`.
  - `limitScale` in the processing-pipeline section (a **stage/order** + **behavioral/pixel** change per the
    compat-doc-sync rule), incl. the composited-vs-fold-back "Diverges" note (above) and the omitted 1px
    floor.
  - Update the stale `fixSize` row (~91) sentence "The `max_pixels`/sqrt branch … is deferred to #165" — #165
    has landed, and it implements an **independent result-pixel sqrt cap**, *not* `fixGifSize`'s combined-sqrt
    (which it deliberately avoids). Reword so the doc doesn't imply ImagePipe now mirrors `fixGifSize`.
  - "standing divergences" note (line ~124): drop the host-result-cap divergence; add the per-axis /
    result-pixel / composited-clamp superset divergences.
  - Input/output safety-limits section (~426-437): reflect downscale-not-error for the result cap.
- `docs/telemetry.md`: rewrite the "Output dimension clamp" section **prose** (not just the metadata bullet) —
  it currently describes the event as *encoder*-only; after #165 the same event also fires for the **host**
  cap (the common path). Update the metadata to the `limits` shape and describe the merged
  `min(host, encoder)` semantics.
- `docs/operational_notes.md`: the result-limit 413 mention → downscale behavior.

## Out of scope

- Shrink-on-load decode fold (`DecodePlanner`) — split to a follow-up; the post-hoc clamp is the correctness
  path.
- #164 look-ahead pre-clamp — untouched.
- Native strict-error policy — no native caller exists; default everything to downscale (per the *Validation
  guidelines*: add the policy when the future caller appears, with a test that exercises it).
- Demo UI — `max_result_*` are host config, not URL/transform knobs; no demo control exists.
- Cache key/ETag data-version bump — no key shape change.
