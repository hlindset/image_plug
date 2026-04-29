# Input Decode Optimization Design

## Context

ImagePlug now fetches origins through `ImagePlug.Origin.fetch/2`, which returns a guarded stream. `ImagePlug` passes that stream to `Image.open/2`, preserving status checks, content-type checks, redirect limits, receive timeouts, and body-size limits before and during decode.

The current decode path always opens with `access: :random`. This is correct and conservative, but it prevents libvips from using lower-memory sequential decode paths for transform chains that only need one-pass access. Large originals that are immediately downscaled still pay unnecessary decode memory and CPU cost.

The `image` dependency exposes the public options needed for this work:

- `access: :sequential | :random` for `Image.open/2`.

The design must keep using `Image.open/2` for input decode. It should not call private Vix APIs. The only direct public Vix use in the first pass should be isolated inside `ImagePlug.ImageMaterializer`.

## Goals

- Use lower-memory decode options for transform chains that can safely run with sequential access.
- Preserve current output semantics, validation limits, and error behavior.
- Keep decode optimization decisions close to transform definitions so future operations can declare their own constraints.
- Add focused tests or benchmarks that demonstrate reduced decode work for representative large downscales.
- Document supported source formats and transform combinations.

## Non-Goals

- Do not change the public path API.
- Do not change cache storage to streaming entries.
- Do not bypass `ImagePlug.Origin` safety checks.
- Do not fuse cover/crop transforms into `Image.thumbnail/3` in the first pass.
- Do not emit JPEG `shrink` or WebP `scale` options in the first pass.

`Image.thumbnail/3` fusion remains a follow-up. It is a good candidate for center-cover and possibly focus-aware crop paths, but it changes transform execution shape and needs separate semantic-equivalence tests.

Format-specific load hints remain a separate follow-up. They require a proof of loader format, not only origin content type, and they change the meaning of `max_input_pixels` unless original dimensions are preserved separately.

## Recommended Approach

Add operation-level metadata and a decode planner.

Each transform module can declare metadata for a specific `{module, params}` item. The decode planner folds that metadata across the whole chain and returns `Image.open/2` options. Unknown transforms default to random access.

The first implementation should focus only on safe access selection:

- `Scale` can declare sequential compatibility only for width-only or height-only resize paths.
- `Contain` can declare sequential compatibility only for `%ContainParams{type: :dimensions, constraint: :regular, letterbox: false}`.
- `Output` has no decode access requirement.
- `Focus`, `Crop`, `Cover`, and letterboxed `Contain` should initially require random access.

This keeps the initial change conservative. Any chain containing a random-access operation opens the origin with `access: :random`. Chains whose operations are all sequential-compatible may open with `access: :sequential`.

Two-dimensional `Scale` must stay random in the first pass. The native planner currently represents both plain `w` plus `h` requests and `fit:fill` as the same `Transform.Scale.ScaleParams` shape, and proportionality/downscale decisions require source dimensions. The first pass should avoid guessing from params alone.

## Architecture

Introduce `ImagePlug.DecodePlanner`.

`ImagePlug.call/2` keeps its current high-level flow:

1. Parse request.
2. Plan transform chain.
3. Resolve origin identity.
4. Fetch guarded origin stream.
5. Decode guarded stream.
6. Validate input limits.
7. Execute transform chain.

The decode step changes from fixed options to planned options:

```elixir
decode_options = ImagePlug.DecodePlanner.open_options(chain)
Image.open(origin_response.stream, decode_options)
```

`open_options/1` always includes `fail_on: :error`. It chooses `access` by folding transform metadata:

```elixir
[
  access: :sequential,
  fail_on: :error
]
```

or:

```elixir
[
  access: :random,
  fail_on: :error
]
```

The first pass must not include format-specific open options. `Image.open/2` should receive only `access` and `fail_on`.

## Transform Metadata

Add a small optional callback to `ImagePlug.Transform`:

```elixir
@callback metadata(params :: term()) :: map()
@optional_callbacks metadata: 1
```

Metadata shape:

```elixir
%{
  access: :sequential | :random | :none
}
```

`access: :none` means the operation does not affect decode access. This is useful for output format selection.

The decode planner treats missing metadata as:

```elixir
%{access: :random}
```

This protects custom or future transforms until they explicitly opt into sequential decode.

## Initial Metadata Rules

`ImagePlug.Transform.Scale`

- Sequential-compatible only when exactly one dimension is `:auto`.
- Two-dimensional scale should require random access initially because native `fit:fill` and plain two-dimensional scale share the same params shape.
- No format-specific load options are emitted.

`ImagePlug.Transform.Contain`

- Sequential-compatible only for `%ContainParams{type: :dimensions, constraint: :regular, letterbox: false}`.
- Ratio, `:min`, `:max`, externally constructed params, and letterboxed `fit:inside` should require random access initially.
- No format-specific load options are emitted.

`ImagePlug.Transform.Output`

- `access: :none`.

`ImagePlug.Transform.Focus`

- Requires random access initially.

`ImagePlug.Transform.Crop`

- Requires random access initially.

`ImagePlug.Transform.Cover`

- Requires random access initially.
- A later thumbnail-fusion issue can map eligible center-cover or focus-cover chains to `Image.thumbnail/3`.

## Validation Limits

Existing limits must stay intact:

- Origin body byte limits remain enforced by `ImagePlug.Origin` while Vix consumes the guarded stream.
- Decode errors remain `415`.
- Origin stream errors remain origin errors.
- `max_input_pixels` remains checked after decode.

Sequential access makes origin errors more subtle. `Image.open/2` may return before the guarded stream is fully consumed, and later reads can happen during transforms or response encoding. The implementation must preserve the existing HTTP status mapping:

- Origin status, content-type, transport, timeout, and body byte-limit failures return the existing origin error response, not transform failures.
- Decoded pixel-limit failures return the existing input-limit response.
- Invalid image bytes remain decode failures when the stream is otherwise valid.
- If a stream-time origin error appears after `Image.open/2` returns but before response headers are sent, the request must still return the existing error status.
- If a stream-time error appears after an uncached response has started streaming, the implementation cannot change the already-sent status. Sequential-eligible responses must therefore force all origin reads before response headers are sent.

The first implementation should therefore include a materialization boundary after transform execution and before response send/cache write. That boundary must force the libvips graph and then check the idempotent origin terminal-status API again.

`ImagePlug.Origin` also needs an idempotent terminal-status API. The current `stream_error/1` consumes a terminal process message and returns `nil` for both terminal success and no terminal message yet. The new API must preserve terminal state and report `:pending`, `:done`, or `{:error, reason}` repeatedly without losing information between the post-open check and the post-materialization check.

Sequential access alone does not change image dimensions and therefore does not affect `max_input_pixels`.

Format-specific `shrink` and `scale` are excluded from the first pass, so they do not affect `max_input_pixels`.

## Planner Semantics

Access folding rules:

- Empty chains return random access.
- Output-only chains return random access.
- Sequential access is selected only when at least one operation opts into sequential access and no operation requires random access.
- Any random-access operation downgrades the whole chain to random access.
- Unknown operations require random access.

This avoids changing no-op and output-only request behavior and prevents custom transforms from accidentally receiving sequential images.

## Materialization Strategy

Sequential access is allowed only for pipelines that pass both checks:

- Chain metadata selects desired `access: :sequential`.
- The delivery path can materialize the transformed image before sending headers or writing a cache entry.

The planner should expose desired access based on the transform chain. `ImagePlug` should then apply a delivery policy. In the first pass, the delivery policy may use sequential access for both cached and uncached eligible requests because both paths must run the same pre-delivery materialization step.

The materialization operation should force pixels, not encode the final output. No suitable public `Image` API is currently identified for forcing realization without writing an output format. The checked public candidates do not fit this boundary: `Image.write/3` and `Image.stream!/2` encode output, `Image.to_list/1` and `Image.to_nx/2` move all pixels into BEAM data structures, and `Image.mutate/2` is not a dedicated realization API. The first pass should use `Vix.Vips.Image.copy_memory/1`, isolated behind `ImagePlug.ImageMaterializer`, as the materialization boundary.

This is a deliberate lower-level public Vix boundary. Request handling must call only the internal materializer module, not Vix directly. The implementation plan must test that boundary directly and keep all direct Vix usage isolated there.

The materialization boundary must leave the origin stream in a terminal state before response headers or cache writes. If forcing pixels does not produce either terminal success or a stream error, ImagePlug must explicitly finalize the origin stream before delivery. If finalization is unavailable or cannot reach a terminal state, the request must fail before delivery; downgrading after a sequential open is too late. Compatibility tests must prove `Vix.Vips.Image.copy_memory/1` reaches terminal status for every sequential opt-in params shape.

Sequential request flow:

1. Open the guarded origin stream with planned options.
2. Check the idempotent origin terminal-status API immediately after open.
3. Validate `max_input_pixels` against the opened image dimensions.
4. Execute the transform chain.
5. If the request used sequential access, call the materializer on the transformed image before any response headers or cache write.
6. Confirm through the idempotent origin status API that the origin stream is terminal, either `:done` or `{:error, reason}`.
7. Continue to cache write or output streaming using the materialized image.

This preserves uncached response streaming after materialization: the encoded output may still stream chunk-by-chunk, but origin reads have finished before `send_chunked/2`.

Error precedence at the materialization boundary:

- Origin stream error wins and returns the existing origin error response.
- Decoded pixel-limit failure returns `413`.
- Materialization is used only to force source-backed image graphs before delivery. Materialization failure without an origin stream error is treated as source decode/materialization failure and returns `415`.
- Transform validation errors from `TransformChain.execute/2` remain `422`.
- Output negotiation failures remain `406`.
- Output encoder failures after successful materialization remain `500`.

The implementation plan should make this boundary its own task. It should not be hidden inside the decode planner task.

## Sequential Compatibility Proof

Sequential compatibility is not inferred from transform names or implementation intuition. A transform may opt into `access: :sequential` only when a dedicated compatibility test proves the exact params shape works under ImagePlug's materialization strategy.

Each opt-in params shape needs a test that:

1. Opens the same source fixture with `access: :random`.
2. Opens the same source fixture with `access: :sequential`.
3. Executes the same transform chain on both images.
4. Runs the same materialization boundary on both results before assertions.
5. Asserts the sequential result matches the random result for dimensions, output mode, and rendered content. Prefer an exact deterministic comparison when feasible; otherwise encode both materialized results to the same deterministic format and compare dimensions plus representative pixel samples or a documented perceptual threshold.
6. Asserts the idempotent origin status API is checked after materialization in the sequential path.

The first compatibility tests should cover:

- Width-only `Scale`.
- Height-only `Scale`.
- `%ContainParams{type: :dimensions, constraint: :regular, letterbox: false}`.

The first pass should also include negative tests proving these shapes stay random:

- Two-dimensional `Scale`.
- Ratio `Contain`.
- `Contain` with `constraint: :min`.
- `Contain` with `constraint: :max`.
- `Contain` with `letterbox: true`.
- `Focus`, `Crop`, and `Cover`.
- Unknown transform modules.

Future transforms or new params shapes must add compatibility tests before changing metadata from random to sequential. If a compatibility test cannot force materialization without using an unacceptable lower-level API, the transform must stay random.

## Testing

Add unit tests for `ImagePlug.DecodePlanner`:

- Empty chain returns `[access: :random, fail_on: :error]`.
- Output-only chain returns random access.
- Width-only or height-only scale returns sequential access.
- Two-dimensional scale returns random access.
- Contain with `%ContainParams{type: :dimensions, constraint: :regular, letterbox: false}` returns sequential access.
- Contain with ratio, `:min`, `:max`, or `letterbox: true` returns random access.
- Chain with a random-access transform returns random access.
- Unknown transform defaults to random access.
- Output transform does not downgrade an otherwise sequential chain.
- Planned options never include JPEG `shrink` or WebP `scale`.

Add integration coverage in `ImagePlugTest` with an internal `:image_open_module` option or decode adapter seam used for tests. Do not document it as a public Plug option unless the implementation intentionally supports it. Do not reuse `:image_module`, which is currently encode-only and is used by tests that do not implement `open/2`. The test should prove that a safe downscale request passes `access: :sequential` and a cover request passes `access: :random`.

Add explicit lazy-stream error tests for a sequential-eligible request:

- Body byte limit exceeded after initial valid JPEG bytes still returns the existing origin error response before headers for the transformed image are sent.
- Timeout after initial valid JPEG bytes still returns the existing origin error response before headers for the transformed image are sent.
- Invalid image tail remains a decode error if no origin stream error occurred.
- Materialization failure without an origin stream error returns the decode error response, not a transform or encode error response.

Run the existing transform and plug tests to ensure behavior remains unchanged.

Add an opt-in benchmark script or tagged benchmark for a generated large JPEG downscale. It should report wall time and memory for the current random-access path and the planned sequential path. Memory measurement should prefer Vix/libvips-supported metrics if available; ordinary Erlang memory metrics are coarse and may miss native libvips allocations. The default test suite should not assert benchmark thresholds; the implementation notes should record representative local output. The expected optimization target is lower memory during source decode and downscale; the final materialized image will still be held in memory before output, which is acceptable for large downscales because the transformed result is small.

## Documentation

Update `README.md` operational notes:

- Explain that ImagePlug may open eligible downscale pipelines with sequential access.
- State that unsupported or crop/focus-heavy chains keep random access.
- State that JPEG/WebP load-size hints are not implemented in this pass.
- Mention that cache hits still serve stored binary entries and do not participate in origin decode optimization.

## Implementation Plan Boundary

This document is the design spec. The next workflow stage must create a separate implementation plan under `docs/superpowers/plans/` with the required plan header, file map, checkbox tasks, exact test code, exact `mise exec -- ...` commands, expected red/green results, and commit steps.

## Follow-Up Issue

Create a separate issue for fusing eligible cover/crop chains into `Image.thumbnail/3`.

Suggested scope:

- Start with center-cover requests.
- Add semantic-equivalence tests against the current cover implementation.
- Expand only if focus anchors and coordinate focus can be mapped exactly enough.
- Keep custom crop-origin behavior on the existing transform path unless equivalence is proven.
