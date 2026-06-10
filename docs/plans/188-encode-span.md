# Plan: instrument the real output encode (#188)

## Problem

In span traces the heaviest stage — forcing the lazy libvips encoder to produce
the first encoded chunk — is wrapped in **no** span. It shows as a ~2.5s gap
between `image_pipe.transform.materialize` and `image_pipe.send`. Separately, the
existing `[:encode]` span (in `Response.Sender`) is misnamed: it measures
connection streaming of already-produced chunks, not encode compute.

## Root cause (confirmed in code)

- `lib/image_pipe/request/source_session/producer.ex` `prepare_first_chunk/1`:
  `Encoder.stream_output/3` builds the lazy encoder pipeline, then
  `first_chunk/1` → `reduce_stream/1` pulls the first chunk, **forcing the
  encoder**. This runs in the **producer** process, on the trace stack whose top
  (after the delivery-backstop `materialize_for_delivery/2` span pops) is the
  adopted `remote_parent` frame carrying the request root's `span_id`. Wrapped in
  no span today.
- `lib/image_pipe/response/sender.ex` `send_prepared_stream/5`: wraps streaming
  the prepared chunks back over the connection in `Telemetry.span(... [:encode] ...)`,
  in the **request** process, nested under `[:send]`.

## Decisions

1. **New encode-compute span: `[:encode]`** (reuse the name freed by the rename).
   Emitted from the producer process around `Encoder.stream_output/3` +
   `first_chunk/1` in `prepare_first_chunk/1`. It is an honest forced-evaluation
   span (genuine compute), peer of the delivery-backstop `transform.materialize`
   — both children of the request root (adopted `remote_parent`). Top-level
   un-namespaced stage, like `[:request]`, `[:parse]`, `[:send]`.
2. **Rename the sender span `[:encode]` → `[:deliver]`.** It measures connection
   streaming, not encoding. Nested under `[:send]` in the request process.
   - `stream_phase: :encode` stays — that field classifies *where in streaming*
     an error occurred (the encoder failed mid-stream), independent of the span
     name. Only the event name changes.

## Changes

### 1. `producer.ex` — add the `[:encode]` span
- Extract `Encoder.stream_output/3` + `first_chunk/1` from the `with` in
  `prepare_first_chunk/1` into a new private `encode_first_chunk(image, resolved_output, opts)`
  that wraps both in `Telemetry.span(telemetry_opts, [:encode], %{output_format: resolved_output.format}, fn -> ... end)`.
  The span fun **must return the `{result, stop_metadata}` 2-tuple** that
  `Telemetry.span/4` expects — threading the inner `result`
  (`{:ok, chunk, content_type, stream_state}` | `:empty` | `{:error, reason}`)
  through as the first element. `encode_first_chunk` itself returns that inner
  `result`.
- The `with` in `prepare_first_chunk/1` binds
  `{:ok, chunk, content_type, stream_state} <- encode_first_chunk(image, resolved_output, request.opts)`
  and the success body uses `content_type`/`stream_state` directly (no behavior change otherwise).
- Stop metadata helper:
  - `{:ok, _, _, _}` → `%{result: :ok, output_format: format}`
  - `:empty` → `%{result: :processing_error, output_format: format, error: :empty_stream}`
  - `{:error, reason}` → `%{result: :processing_error, output_format: format, error: Error.tag(reason)}`
- `Encoder.stream_output/3` and `first_chunk/1` both return tagged tuples (they
  rescue internally), so the span never sees a raise → always `:stop`, never
  `:exception`. Error tagging/propagation is unchanged: the outer
  `with_stream_translation(&prepare_fallback/2, …)` still wraps the whole body.
  `Error` is already aliased in the module.

### 2. `sender.ex` — rename `[:encode]` → `[:deliver]`
- `send_prepared_stream/5`: change the span stage list to `[:deliver]`.
- Rename the metadata helpers for cleanliness: `prepared_encode_stop_metadata/3`
  → `deliver_stop_metadata/3`; the shared `encode_stop_metadata/3` →
  `deliver_ok_metadata/3` (or fold in). `output_metadata/1` stays.
  **The success arm must still emit `result: :ok`** (preserve the current
  `encode_stop_metadata(:ok, …)` behavior under the new name) so the success-path
  stages loop (`telemetry_test.exs:229-232`) does not regress.
- `stream_error_phase/1`, `stream_error_tag/1` unchanged (`:encode` phase stays —
  that is the streaming *error phase* classification, not the span name).

### 3. `telemetry/trace/capture.ex` — span stage list
- Add `[:deliver]` to `@span_stages`. Keep `[:encode]` (now captures the producer
  span). No allowlist change (`output_format` stays out, consistent with
  `[:output, :negotiate]` — it is emitted in raw events but not copied into trace
  attributes).

### 4. `telemetry/logger.ex` — subscription + rendering
- Add `[:encode]` to the `request` group in `@group_span_events` (it is a
  request-lifecycle stage; the producer emits it). Optionally add `[:deliver]`
  too so the connection-streaming span is Logger-visible (it was not subscribed
  before). Decision: add **both** to the `request` group.
- Add a specific `message/3` clause for `[:encode]` that surfaces outcome +
  format, e.g. `"image_pipe encode: ok (jpeg)"`; it must still surface
  `outcome(meta)` for the error case. `[:deliver]` can fall through to the
  generic clause (`label + outcome`). Clause ordering: specific before generic.
- `level_for/3` — **deliberate, narrowly-scoped escalation.** Today `level_for`
  escalates only `:cache_error`/`:materialize_error` (plus exceptions and detect
  fallbacks); `[:send]` and `[:request]` already emit `:processing_error` and are
  **not** escalated. To avoid changing that established treatment, add a clause
  matching the `[:encode]` suffix specifically: an encode-compute
  `:processing_error` (a genuine server-side encode failure → 500, analogous to
  `:materialize_error`) escalates to `:warning`. Do **NOT** add a generic
  `result == :processing_error` clause (it would retroactively escalate
  `[:send]`/`[:request]`), and do **NOT** escalate `[:deliver]` — its
  `:processing_error`/`:client_closed` outcomes are streaming/connection events
  that match the existing un-escalated `[:send]` treatment (and `:client_closed`
  is a normal disconnect, never a warning).

### 5. `docs/telemetry.md`
- Add a "### Output encode span (`[:encode]`)" subsection: honest forced-encode
  timing in the producer process, parented to the request root (sibling of the
  delivery-backstop materialize). Note it is NOT per-op construction timing.
- Add a "### Delivery streaming span (`[:deliver]`)" note (or fold into the send
  description): connection-delivery streaming of already-produced chunks, nested
  under `[:send]` in the request process. It measures connection streaming, not
  encoding.
- Update the event-name list (line ~63) and the `@stages` example handler (line
  ~445) — add `[:deliver]`, keep `[:encode]`.
- Fix the line-51 prose ("cache hits skip … encoding, and send streaming spans")
  so it reads correctly given the two distinct spans now exist.
- Tracing section (lines ~480-486): mention the new producer `[:encode]` seam
  (Producer process, parented to request root) and `[:deliver]` under `[:send]`.
- Optional: add an `[:encode]`/`[:deliver]` → `:ok`/`:processing_error` row to the
  representative stage→result mappings.
- Axis changed: **stage/order** (pipeline section) — no option-table or pixel
  change. (imgproxy compatibility reviewer optional: telemetry plumbing, no
  observable image/HTTP behavior change.)

## Tests

- **`telemetry/trace/encode_span_test.exs`** (rewrite): assert
  `image_pipe.encode` now runs in the **producer** process (pid == the
  delivery-backstop `image_pipe.transform.materialize` pid, ≠ the `image_pipe.send`
  pid), `trace_id == root.trace_id`, and `parent_span_id == root.span_id`
  (sibling of the materialize). Assert a separate `image_pipe.deliver` span nests
  under `image_pipe.send` (same pid as send). Update the module doc comment.
- **`telemetry_test.exs`**:
  - `stages/0` and the start/stop loop (~line 216): add `[:deliver]`; `[:encode]`
    stays and must report `result: :ok` (now from producer).
  - "encode stop metadata reports processing error after chunked stream failure":
    the `:processing_error` assertion moves to `[:image_pipe, :deliver, :stop]`;
    add that the producer `[:image_pipe, :encode, :stop]` reports `result: :ok`
    (first chunk succeeded) with `output_format: :jpeg`.
  - "request and send stop metadata report processing error when streaming encode
    fails before response": now the producer `[:image_pipe, :encode, :stop]` fires
    with `result: :processing_error` — add an assertion. Also add a
    `refute_event(events, [:image_pipe, :deliver, :stop])` — the 500 path goes
    through `handle_processing_error`, not `send_prepared_stream`, so no
    `[:deliver]` span fires.
- **`response_sender_test.exs`**: the three tests attaching to
  `[:image_pipe, :encode, :stop]` → `[:image_pipe, :deliver, :stop]`; metadata
  (`stream_phase: :encode`, `error`, `status`, `output_format`) unchanged. Update
  the `handle_telemetry_event` doc comment (line ~478) referencing
  `[:image_pipe, :encode, :stop]` to `[:image_pipe, :deliver, :stop]`.
- **`test/support/telemetry.ex`** (line ~12): update the stale `[:image_pipe, :encode, :stop]`
  example comment to `[:image_pipe, :deliver, :stop]` (the in-process emission it demonstrates).
- **`logger_test.exs`**: add an assertion that the new `[:image_pipe, :encode, :stop]`
  renders `"encode: ok (jpeg)"` (or similar); that an encode `[:image_pipe, :encode, :stop]`
  with `result: :processing_error` escalates to `[warning]`; and that a
  `[:image_pipe, :deliver, :stop]` ok event renders (newly subscribed line).
- No new impossible-internal-misuse / name-policing tests; assert at the
  request/telemetry boundary.

## Verification
- `mise run precommit` (format, compile --warnings-as-errors, credo --strict, test).
- Spot-run the touched telemetry/sender/producer tests first.
