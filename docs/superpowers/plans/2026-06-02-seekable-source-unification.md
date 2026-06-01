# Seekable-Source Unification Implementation Plan (Plan A of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop decoding through Vix's read-once stream loader; always hand libvips a *seekable* source (a file path, or an in-memory buffer drained from the guarded origin stream), with no change to output pixels.

**Architecture:** `ImagePipe.Source.Response` gains an optional `path` field alongside `stream` (additive, so HTTP/S3/test adapters are untouched). The file adapter returns a validated `path`; HTTP/S3 keep returning a guarded `stream`. `Request.Processor` turns either into a seekable libvips input — `Image.open(path)` for paths, or drain-the-guarded-stream-to-binary-then-`Image.open(binary)` for streams — with the drain failing closed (body-limit / stream errors surface as `{:source, …}` *before* decode). Output is byte-identical to today, so all pixel-exact tests still pass.

**Tech Stack:** Elixir, `Vix`/`image` (libvips bindings), `Plug`, `ExUnit`. This is **Plan A**; shrink-on-load itself is **Plan B**, written after this lands (it depends on the `Response`/Processor shapes finalized here). Spec: [docs/superpowers/specs/2026-06-01-shrink-on-load-design.md](../specs/2026-06-01-shrink-on-load-design.md).

**Run tests with:** `mise exec -- mix test <path>` (per repo CLAUDE.md). Gate: `mise run precommit`.

---

## Why this is its own plan

The spec's geometry work (Resize must compute targets from *original* dims while scaling from *shrunk* dims) and the `max_input_pixels`-on-original-dims safety reorder only matter once we actually shrink. Getting onto seekable sources is a self-contained refactor with **no output change** — it is independently shippable, independently verifiable (pixel-exactness preserved), and de-risks Plan B. Per the writing-plans scope check, it ships first.

## File Structure

- **Modify** `lib/image_pipe/source/response.ex` — add optional `path` field; relax `@enforce_keys`.
- **Modify** `lib/image_pipe/source.ex` — `wrap_response/2` passes `path` responses through unwrapped; `body_limit_exceeded?/1` and `stream_error_reason/1` already degrade for non-`WrappedStream` (verify).
- **Modify** `lib/image_pipe/source/file.ex` — `fetch/3` returns `%Response{path: validated_path}` instead of a `File.stream!` stream; keep `safe_path/2` + `regular_file/1`.
- **Modify** `lib/image_pipe/request/processor.ex` — `decode_source_response/3` resolves a seekable input: `path` → open path; `stream` → drain-to-binary (fail-closed) → open binary. Remove the now-dead `Source.StreamError` rescue/catch around the streaming open (it moves into the drain).
- **Modify** `test/image_pipe/source/file_test.exs` — assert `fetch` returns a `path` response.
- **Modify** `test/image_pipe/processor_test.exs` — existing body-limit/stream-error/input-pixel tests still pass; add a path-input decode test.

`sequential_compatibility_test.exs` is **not** touched here — it calls `Image.open(stream)` directly (bypassing Processor) and asserts pixel-exactness, which still holds. It is deleted in Plan B when shrink-on-load actually changes pixels.

---

### Task 1: Add an optional `path` to `Source.Response`

**Files:**
- Modify: `lib/image_pipe/source/response.ex`
- Test: `test/image_pipe/source/response_test.exs` (Create)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/response_test.exs`:

```elixir
defmodule ImagePipe.Source.ResponseTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.Response

  test "defaults both fields to nil" do
    assert %Response{} == %Response{stream: nil, path: nil}
  end

  test "carries a stream" do
    response = %Response{stream: ["chunk"]}
    assert response.stream == ["chunk"]
    assert response.path == nil
  end

  test "carries a path" do
    response = %Response{path: "/tmp/image.jpg"}
    assert response.path == "/tmp/image.jpg"
    assert response.stream == nil
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/source/response_test.exs`
Expected: FAIL — `@enforce_keys [:stream]` makes `%Response{}` and `%Response{path: ...}` raise `ArgumentError` ("the following keys must also be given... :stream").

- [ ] **Step 3: Make the struct additive**

Replace the whole body of `lib/image_pipe/source/response.ex`:

```elixir
defmodule ImagePipe.Source.Response do
  @moduledoc false

  defstruct stream: nil, path: nil

  @type t :: %__MODULE__{
          stream: Enumerable.t() | nil,
          path: Path.t() | nil
        }
end
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `mise exec -- mix test test/image_pipe/source/response_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/response.ex test/image_pipe/source/response_test.exs
git commit -m "feat(source): allow Response to carry a seekable path"
```

---

### Task 2: `wrap_response/2` passes path responses through unwrapped

**Files:**
- Modify: `lib/image_pipe/source.ex:101-103` (the `wrap_response/2` stream clause)
- Test: `test/image_pipe/source_test.exs` (add tests near the existing `wrap_response` coverage)

`wrap_response/2` must only wrap a `stream` response in a `WrappedStream`; a `path` response has no body bytes to count and is returned as-is. `body_limit_exceeded?/1` and `stream_error_reason/1` already fall through to `%Response{}` clauses for non-`WrappedStream` responses, so a `path` response yields `false`/`:error` — no change needed there (this task adds a test that pins that).

- [ ] **Step 1: Write the failing tests**

Add to `test/image_pipe/source_test.exs` (inside the existing `describe "wrap_response/2"` block if present; otherwise add a new `describe`):

```elixir
test "wrap_response wraps a stream response in a WrappedStream" do
  {:ok, wrapped} = Source.wrap_response(%Response{stream: ["a"]}, max_body_bytes: 10)
  assert %Source.WrappedStream{} = wrapped.stream
  assert wrapped.path == nil
end

test "wrap_response passes a path response through unwrapped" do
  response = %Response{path: "/tmp/x.jpg"}
  assert {:ok, ^response} = Source.wrap_response(response, max_body_bytes: 10)
end

test "body/stream queries degrade for a path response" do
  response = %Response{path: "/tmp/x.jpg"}
  refute Source.body_limit_exceeded?(response)
  assert Source.stream_error_reason(response) == :error
end
```

Confirm the test module already aliases `ImagePipe.Source` and `ImagePipe.Source.Response`; if not, add `alias ImagePipe.Source` and `alias ImagePipe.Source.Response`.

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/source_test.exs`
Expected: FAIL — the path-passthrough test fails because `wrap_response/2`'s only non-error clause matches `%Response{stream: stream}` with `stream: nil` and rebuilds `%Response{stream: WrappedStream.new(nil, …)}`, losing `path` and wrapping a nil stream.

- [ ] **Step 3: Add the path clause to `wrap_response/2`**

In `lib/image_pipe/source.ex`, replace:

```elixir
  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{stream: stream}, runtime_opts) do
    max_body_bytes = Keyword.fetch!(runtime_opts, :max_body_bytes)
    {:ok, %Response{stream: WrappedStream.new(stream, max_body_bytes)}}
  end

  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}
```

with:

```elixir
  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{path: path} = response, _runtime_opts) when is_binary(path) do
    {:ok, response}
  end

  def wrap_response(%Response{stream: stream} = response, runtime_opts)
      when not is_nil(stream) do
    max_body_bytes = Keyword.fetch!(runtime_opts, :max_body_bytes)
    {:ok, %Response{response | stream: WrappedStream.new(stream, max_body_bytes)}}
  end

  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}
```

- [ ] **Step 4: Run to confirm pass**

Run: `mise exec -- mix test test/image_pipe/source_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source.ex test/image_pipe/source_test.exs
git commit -m "feat(source): pass path responses through wrap_response unwrapped"
```

---

### Task 3: File adapter returns a validated path

**Files:**
- Modify: `lib/image_pipe/source/file.ex:62-68` (`fetch/3`)
- Test: `test/image_pipe/source/file_test.exs`

- [ ] **Step 1: Update the failing test first**

In `test/image_pipe/source/file_test.exs`, find the test that asserts `fetch/3` returns a stream (it will assert something like `%Response{stream: stream}` and consume it). Replace its body so it asserts a `path` response pointing at the resolved fixture and that the bytes read from that path equal the file. Example replacement (adapt the existing test's name and the `Resolved`/opts setup it already builds):

```elixir
test "fetch/3 returns the resolved file path" do
  resolved = resolved_for(["images", "beach.jpg"])

  assert {:ok, %Response{path: path, stream: nil}} =
           ImagePipe.Source.File.fetch(resolved, file_opts(), [])

  assert Path.expand(path) == Path.expand("priv/static/images/beach.jpg")
  assert File.read!(path) == File.read!("priv/static/images/beach.jpg")
end
```

Reuse whatever `resolved_for/1` + `file_opts/0` helpers the file test already defines (the existing fetch test builds these). If the file test currently has no such helper, mirror the `resolve/3` call the existing tests use to obtain a `%Resolved{}` and pass the adapter opts (`root:`, `root_id:`) that the rest of the file tests use. Ensure `alias ImagePipe.Source.Response` is present.

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/source/file_test.exs`
Expected: FAIL — `fetch/3` still returns `%Response{stream: File.stream!(...)}`, so `path` is `nil`.

- [ ] **Step 3: Return a path response**

In `lib/image_pipe/source/file.ex`, replace `fetch/3`:

```elixir
  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, _runtime_opts) do
    with {:ok, path} <- safe_path(fetch[:root], fetch[:segments]),
         :ok <- regular_file(path) do
      {:ok, %Response{path: path}}
    end
  end
```

(`safe_path/2` and `regular_file/1` are unchanged — the path is still validated before it is exposed.)

- [ ] **Step 4: Run to confirm pass**

Run: `mise exec -- mix test test/image_pipe/source/file_test.exs`
Expected: PASS. (If other file tests consumed `response.stream`, update them to read `response.path` the same way — they were asserting the old contract.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/file.ex test/image_pipe/source/file_test.exs
git commit -m "feat(source): file adapter returns a seekable path, not a chunk stream"
```

---

### Task 4: Processor opens a seekable input (drain streams, open paths)

**Files:**
- Modify: `lib/image_pipe/request/processor.ex:159-170` (`decode_source_response/3`)
- Test: `test/image_pipe/processor_test.exs`

This is the core change. `decode_source_response/3` currently pipes `source_response.stream` straight into `image_open_module.open/2` with a `StreamError` rescue. Replace it with a resolver that produces a **seekable input** — the path for path responses, or a fully-drained binary for stream responses — and move the `StreamError` mapping into the drain so body-limit/stream errors fail closed *before* `open/2` is called.

- [ ] **Step 1: Write the failing test — path input decodes via the path**

Add to `test/image_pipe/processor_test.exs`. First add a recording stub module near the other stub modules at the top of the file:

```elixir
defmodule RecordingPathOpen do
  def open(input, _opts) do
    send(self(), {:opened_input, input})
    Image.open(input)
  end
end
```

Then add the test (uses the real fixture as a path response):

```elixir
test "decode_validate_source_response opens a path response via the path" do
  response = %Response{path: "priv/static/images/beach.jpg"}

  assert {:ok, %{image: image}} =
           Processor.decode_validate_source_response(
             response,
             plan(),
             Keyword.put(opts(), :image_open_module, RecordingPathOpen)
           )

  assert Vix.Vips.Image.width(image) > 0
  assert_received {:opened_input, "priv/static/images/beach.jpg"}
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs:LINE` (the new test)
Expected: FAIL — current code calls `source_response.stream |> open(...)`; `stream` is `nil` for a path response, so `open(nil, …)` errors (not `{:opened_input, path}`).

- [ ] **Step 3: Replace `decode_source_response/3`**

In `lib/image_pipe/request/processor.ex`, replace:

```elixir
  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    source_response.stream
    |> image_open_module.open(decode_options)
    |> prefer_source_stream_error(source_response)
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  catch
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %Source.StreamError{reason: reason} -> {:error, {:source, reason}}
  end
```

with:

```elixir
  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    with {:ok, input} <- seekable_input(source_response) do
      input
      |> image_open_module.open(decode_options)
      |> prefer_source_stream_error(source_response)
    end
  end

  defp seekable_input(%Source.Response{path: path}) when is_binary(path), do: {:ok, path}

  defp seekable_input(%Source.Response{stream: stream}) when not is_nil(stream) do
    {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  catch
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %Source.StreamError{reason: reason} -> {:error, {:source, reason}}
  end
```

Notes for the implementer:
- The drain (`Enum.to_list/1` over the `WrappedStream`) is what triggers the byte-count and the `WrappedStream`'s `StreamError` raise on `:body_too_large` / `:invalid_stream_chunk` / `:stream_exception`. The rescue maps those to `{:source, reason}` *before* `open/2` runs — fail closed.
- `prefer_source_stream_error/2` and `prefer_source_body_limit/2` (already wrapping the result in `decode_validate_source_response/3`) remain as a belt-and-suspenders check against the `WrappedStream` atomics; for a successful drain they are no-ops, and for a `path` response (no `WrappedStream`) they degrade to no-ops.

- [ ] **Step 4: Run the new test + the full processor suite**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS, including the pre-existing tests:
- `"decode_validate_source_response returns input limit errors"` (still decodes the drained binary, still reports `{:input_limit, {:too_many_input_pixels, _, 1}}`).
- `"unsupported decoded source format is reported before input pixel limits"`.
- `"deferred source stream errors remain source errors during decode"` — the raising stream now raises during the in-process drain; the rescue maps it to `{:source, :stream_exception}`. (The `DecodeRaisesSourceStreamError` stub is now never reached because the drain fails first; the asserted result is unchanged. If the test's intent comment references "during decode", leave the assertion as-is — the tag is identical.)
- `"body limit errors beat later decode errors..."` — the body-too-large `StreamError` is now raised during our drain, returning `{:source, :body_too_large}` before `open/2`; the `DecodeConsumesBodyLimitThenReturnsDecodeError` stub is no longer invoked but the asserted result is identical, so the test stays green.

If any of these four fail on the *tag*, stop and reconcile — the tags must be preserved exactly. (Behavior change to their internal mechanism is expected; the asserted result is not.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/image_pipe/processor_test.exs
git commit -m "feat(request): decode from a seekable input (path open / drained buffer)"
```

---

### Task 5: Full-suite regression sweep

**Files:** none expected; this task finds and fixes fallout from the input-path change.

- [ ] **Step 1: Run the whole suite**

Run: `mise exec -- mix test`
Expected: GREEN. Watch specifically for:
- Wire-level plug tests that assert `access:`/`fail_on:` decode options (e.g. "safe one-pass resize opens origin with sequential access"): these still pass — `decode_options` is unchanged and is passed to `open/2` on the drained binary.
- Any test that asserted the origin body is consumed *lazily* / not fully buffered. Slice A deliberately buffers HTTP/S3 input. Such a test pins the **old** input contract; update it to assert the user-visible result (status, body, dimensions) instead of input laziness, or remove the laziness-specific assertion. Document any test changed here in the commit message.

- [ ] **Step 2: If failures occurred, fix each by asserting the user-visible contract, not the old streaming-input mechanism. Re-run `mise exec -- mix test` until green.**

- [ ] **Step 3: Run the architecture-boundary test explicitly**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — no new cross-boundary references were introduced (Source still owns `Response`; Processor is in Request and already depends on Source).

- [ ] **Step 4: Commit any test adjustments**

```bash
git add -A
git commit -m "test: align input-streaming assertions with seekable-source decode"
```

(Skip this commit if Step 1 was already green.)

---

### Task 6: Gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

- [ ] **Step 2: Fix any format/credo/warning issues, re-run until green.**

- [ ] **Step 3: Final commit (if the gate required fixes)**

```bash
git add -A
git commit -m "chore: satisfy precommit gate for seekable-source unification"
```

---

## Self-Review

**Spec coverage (Plan A's slice only):**
- "One seekable-source decode path / off the read-once pipe" → Tasks 3, 4. ✓
- "`Source.Response` path-vs-stream contract change (Source boundary)" → Tasks 1, 2. ✓
- "Drain fails closed before `Image.open`; preserve error tags" → Task 4 (`seekable_input` rescue + Step 4 tag checks). ✓
- "File source keeps `safe_path`/`regular_file`" → Task 3 Step 3 (helpers retained). ✓
- "Materialize-before-delivery unchanged" → not touched (verified: `materialize_before_delivery/4` keys off `access:`, which is unchanged). ✓
- Deferred to **Plan B** (correctly out of scope here): `DecodePlanner {access, load_shrink}`, shrink open, `max_input_pixels` on original dims, `State.source_dimensions` + Resize geometry, equivalence-contract change, `sequential_compatibility_test.exs` deletion, measurement.

**Placeholder scan:** none — every code step shows complete code; every run step shows the exact command and expected outcome. The one variable (`:LINE` in Task 4 Step 2) is a literal instruction to target the just-added test.

**Type consistency:** `%Response{stream: ..., path: ...}` used identically across Tasks 1–4; `seekable_input/1` returns `{:ok, path | binary}` consumed by `open/2` in Task 4; `wrap_response/2` clauses in Task 2 match the struct shape from Task 1. Error tags (`{:source, :body_too_large}`, `{:source, :stream_exception}`, `{:input_limit, …}`) are preserved, not renamed.

---

## Next: Plan B — Shrink-on-load

To be written once Plan A lands (its tasks reference the finalized `Response`/Processor shapes). Scope, per the spec:
1. `DecodePlanner.open_options/3` → `{access, load_option}` from `(operations, source_format, original_dims)`, pure (caller supplies format + dims). Format gating: JPEG `shrink: 1|2|4|8`, WebP/vector `scale:`, PNG/HEIF/AVIF none.
2. Processor: open the seekable input lazily, read header dims + format, validate `max_input_pixels` on **original** dims, then re-open with the load option when `load_shrink > 1`.
3. `Transform.State` gains `source_dimensions: {w, h} | nil`; `Resize.resolve_dimensions` computes the target from `source_dimensions` (original) while `resize_image` scales from the actual (shrunk) current image — guaranteeing dimension-exact output vs. the full-decode path.
4. Replace `sequential_compatibility_test.exs` with wire-level dimension-exact + coarse-downsample-MAE/SSIM equivalence tests; PNG stays pixel-exact.
5. Deterministic decoded-dimension gate proving no full-res materialization; reported (non-gating) memory benchmark.
