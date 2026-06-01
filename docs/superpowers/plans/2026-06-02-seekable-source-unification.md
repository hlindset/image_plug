# Seekable-Source Unification Implementation Plan (Plan A of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop decoding through Vix's read-once stream loader; always hand libvips a *seekable* source (a file path, or an in-memory buffer drained from the guarded origin stream), with no change to output pixels.

**Architecture:** `ImagePipe.Source.Response` gains an optional `path` field alongside `stream` (additive, so HTTP/S3/test adapters keep compiling unchanged). The file adapter returns a validated `path`; HTTP/S3 keep returning a guarded `stream`. `Request.Processor` turns either into a seekable libvips input — `Image.open(path)` for paths, or **drain-the-guarded-stream-to-binary then `Image.open(binary)`** for streams — with the drain failing closed (body-limit / stream errors surface as `{:source, …}` *before* decode). Output is byte-identical to today, so all pixel-exact tests still pass.

**Tech Stack:** Elixir, `Vix`/`image` (libvips bindings), `Plug`, `ExUnit`. This is **Plan A**; shrink-on-load itself is **Plan B**, written after this lands (it depends on the `Response`/Processor shapes finalized here). Spec: [docs/superpowers/specs/2026-06-01-shrink-on-load-design.md](../specs/2026-06-01-shrink-on-load-design.md).

**Run tests with:** `mise exec -- mix test <path>` (per repo CLAUDE.md). Gate: `mise run precommit`.

---

## Why this is its own plan

The spec's geometry work (Resize must compute targets from *original* dims while scaling from *shrunk* dims) and the `max_input_pixels`-on-original-dims safety reorder only matter once we actually shrink. Getting onto seekable sources is a self-contained refactor with **no output change** — independently shippable, independently verifiable (pixel-exactness preserved), and it de-risks Plan B. Per the writing-plans scope check, it ships first.

## What changes behaviorally in Plan A (read before implementing)

This is **not** purely "only `file.ex` changes." Two real behavior changes ship here, both intended and both greenfield-acceptable:

1. **HTTP/S3 input decode moves from a lazy read-once pipe to a full in-memory buffer.** Today the Processor hands `Image.open` the live stream (`new_from_enum`, read-once); under Plan A it drains the *entire* guarded stream into one binary, then `Image.open(binary)`. Compressed-body memory is still bounded by `max_body_bytes` (the spec's stated non-goal: "not lowering compressed-body memory"). The offsetting shrink-on-load win arrives in Plan B.
2. **Body-limit / stream errors for the stream case now surface during the Processor's drain**, not during libvips' lazy pixel pull. Error *tags* are preserved (`{:source, :body_too_large}`, `{:source, :stream_exception}`); the *mechanism* and *timing* change — which is why two cross-process race tests are deleted (Task 4) rather than kept as green no-ops.

Output pixels, response streaming (the encoder produces the response body, not a re-stream of the source), the `access:`/`fail_on:` decode options, telemetry spans, and cache key/ETag inputs are all **unchanged**.

**TOCTOU:** the file adapter validates `safe_path`/`regular_file` in `fetch/3`, and the Processor opens the returned path later — the same open-vs-validate window that exists today (`File.stream!` also opens lazily after `fetch`). The existing test `"fetch rechecks path safety after cache lookup can delay the open"` (`test/image_pipe/source/file_test.exs`) pins the fetch-time recheck and stays green. Plan A deliberately does **not** add a second Processor-side re-validation; the residual window is accepted for `stable: :trusted` files, exactly as the spec notes.

## File Structure

- **Modify** `lib/image_pipe/source/response.ex` — add optional `path` field; drop `@enforce_keys`.
- **Modify** `lib/image_pipe/source.ex` — `wrap_response/2` passes `path` responses through unwrapped; `body_limit_exceeded?/1`/`stream_error_reason/1` already degrade for non-`WrappedStream` (pin with a test).
- **Modify** `lib/image_pipe/source/file.ex` — `fetch/3` returns `%Response{path: validated_path}`; keep `safe_path/2` + `regular_file/1`.
- **Modify** `lib/image_pipe/request/processor.ex` — `decode_source_response/3` resolves a seekable input: `path` → open path; `stream` → drain-to-binary (fail-closed) → open binary; all-nil → tagged error. Remove the now-dead `Source.StreamError` rescue/catch around the streaming open (it moves into the drain).
- **Modify** `test/image_pipe/source/file_test.exs` — `"fetch streams regular file bytes"` becomes a path-response assertion.
- **Modify** `test/image_pipe/processor_test.exs` — delete two cross-process race tests + their dead stubs; add a path-input decode test and an in-process drain-fail-closed test; keep the input-limit / unsupported-format / deferred-stream-error contracts.
- **Create** `test/image_pipe/source/response_test.exs` — one test pinning the relaxed-enforcement contract.

`sequential_compatibility_test.exs` is **not** touched here — it calls `Image.open(stream)` directly (bypassing Processor) and asserts pixel-exactness, which still holds. It is deleted in Plan B when shrink-on-load actually changes pixels.

---

### Task 1: Add an optional `path` to `Source.Response`

**Files:**
- Modify: `lib/image_pipe/source/response.ex`
- Test: `test/image_pipe/source/response_test.exs` (Create)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/response_test.exs`. One test, pinning the actual behavior under change (relaxed enforcement + nil defaults). Field-echo tests are intentionally omitted — they would only pin `defstruct` semantics and are exercised end-to-end by Tasks 3–4.

```elixir
defmodule ImagePipe.Source.ResponseTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.Response

  test "constructs without enforcing a stream and defaults both fields to nil" do
    assert %Response{} == %Response{stream: nil, path: nil}
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `mise exec -- mix test test/image_pipe/source/response_test.exs`
Expected: FAIL — `@enforce_keys [:stream]` makes `%Response{}` raise `ArgumentError` ("the following keys must also be given when building struct ... :stream").

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
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/response.ex test/image_pipe/source/response_test.exs
git commit -m "feat(source): allow Response to carry a seekable path"
```

---

### Task 2: `wrap_response/2` passes path responses through unwrapped

**Files:**
- Modify: `lib/image_pipe/source.ex:101-103` (`wrap_response/2`)
- Test: `test/image_pipe/source_test.exs`

`wrap_response/2` must only wrap a `stream` response in a `WrappedStream`; a `path` response has no body bytes to count and is returned as-is. Assert the *behavior* the wrapping confers (and the degraded path-response queries), not the internal struct tag.

- [ ] **Step 1: Write the failing tests**

Add to `test/image_pipe/source_test.exs` (reuse the existing `describe "wrap_response/2"` block if present; otherwise add one). Confirm the module aliases `ImagePipe.Source` and `ImagePipe.Source.Response` (add the aliases if missing).

```elixir
test "wrap_response wrapping a stream enforces the body limit on consumption" do
  {:ok, wrapped} = Source.wrap_response(%Response{stream: ["abc"]}, max_body_bytes: 2)
  assert wrapped.path == nil

  assert_raise ImagePipe.Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
  assert Source.body_limit_exceeded?(wrapped)
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

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/source_test.exs`
Expected: FAIL — the path-passthrough test fails: `wrap_response/2`'s only non-error clause matches `%Response{stream: stream}` with `stream: nil`, rebuilding `%Response{stream: WrappedStream.new(nil, …)}` and dropping `path`.

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

(An all-nil `%Response{}` now falls to the catch-all and returns `{:error, {:source, :invalid_adapter_result}}` — an improvement, since `@enforce_keys` no longer guards it at construction.)

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
- Test: `test/image_pipe/source/file_test.exs:80` (`"fetch streams regular file bytes"`)

The file test uses a per-test tmp dir (`setup` creates `images/cat.jpg` containing `"image bytes"`) and builds `%Resolved{}` via `validate_options/1` + `resolve/3`. Keep that setup; rewrite the fetch assertion. The TOCTOU recheck test (`"fetch rechecks path safety after cache lookup can delay the open"`, lines 60-78) is untouched and stays green (it asserts `fetch/3` returns `{:error, {:source, :denied_path}}` after a symlink swap, which still holds because `safe_path`/`regular_file` remain).

- [ ] **Step 1: Update the failing test**

In `test/image_pipe/source/file_test.exs`, replace the test `"fetch streams regular file bytes"` (lines 80-90) with:

```elixir
test "fetch returns the resolved file path", %{root: root} do
  assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

  assert {:ok, resolved} =
           SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

  assert {:ok, %Response{path: path, stream: nil}} =
           SourceFile.fetch(resolved, opts, max_body_bytes: 20)

  assert path == Path.join(root, "images/cat.jpg")
  assert File.read!(path) == "image bytes"
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `mise exec -- mix test test/image_pipe/source/file_test.exs`
Expected: FAIL — `fetch/3` still returns `%Response{stream: File.stream!(...)}`, so `path` is `nil` and `stream` is non-nil.

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
Expected: PASS (all file tests, including the TOCTOU recheck and missing-file tests, which do not read `response.stream`).

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

The core change. Replace the streaming open + `StreamError` rescue with a resolver that produces a **seekable input** — the path for path responses, or a fully-drained binary for stream responses — moving the `StreamError` mapping into the drain so body-limit/stream errors fail closed *before* `open/2`.

- [ ] **Step 1: Replace `decode_source_response/3`**

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

  defp seekable_input(%Source.Response{}), do: {:error, {:source, :invalid_adapter_result}}
```

Notes for the implementer:
- The third `seekable_input/1` clause guards the all-nil response: `decode_validate_source_response/3` is a public function, so it must return a tagged error rather than raise `FunctionClauseError` if ever handed `%Response{stream: nil, path: nil}` directly.
- The drain (`Enum.to_list/1` over the `WrappedStream`) is what triggers the byte-count and the `WrappedStream`'s `StreamError` raise (in *this* process) on `:body_too_large` / `:invalid_stream_chunk` / `:stream_exception`. The rescue maps those to `{:source, reason}` *before* `open/2` runs.
- `prefer_source_stream_error/2` / `prefer_source_body_limit/2` (already wrapping the result in `decode_validate_source_response/3`) remain as belt-and-suspenders against the `WrappedStream` atomics; for a successful drain or a `path` response they are no-ops.

- [ ] **Step 2: Compile and run the existing processor suite to see what breaks**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: the two cross-process tests still pass *by tag* but their stubs are now never invoked (dead code). The input-limit and unsupported-format tests pass. We delete the stale tests next.

- [ ] **Step 3: Delete the two cross-process race tests and their now-dead stubs**

These pinned a cross-process race (decode-in-another-process vs. body-limit) that no longer exists once the drain runs in-process before `open/2`. Per the repo's "no post-migration parity pins / no impossible-misuse" rule, delete them rather than keep green no-ops.

In `test/image_pipe/processor_test.exs`:
- Delete the module `DecodeConsumesBodyLimitThenReturnsDecodeError` (the `defmodule` block, lines ~27-50).
- Delete the module `DecodeConsumesStreamErrorThenReturnsDecodeError` (lines ~52-75).
- Delete the module `DecodeRaisesSourceStreamError` (lines ~20-25) — see Step 5, the deferred-stream-error test no longer needs a stub.
- Delete the test `"body limit errors beat later decode errors from another stream consumer process"`.
- Delete the test `"source stream errors beat later decode errors from another stream consumer process"`.

- [ ] **Step 4: Add the path-input decode test + the in-process fail-closed test**

Add a recording stub near the top of the file (mirroring `RecordingImageOpen`'s `$callers` idiom from `plug_test.exs`):

```elixir
defmodule RecordingPathOpen do
  def open(input, opts) do
    send(message_target(), {:opened_input, input})
    Image.open(input, opts)
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
```

Add the path-open test (a `path` response is opened *by path*, not drained):

```elixir
test "decode_validate_source_response opens a path response via the path" do
  response = %Response{path: "priv/static/images/beach.jpg"}

  assert {:ok, %{image: image}} =
           Processor.decode_validate_source_response(
             response,
             plan(),
             Keyword.put(opts(), :image_open_module, RecordingPathOpen)
           )

  assert VipsImage.width(image) > 0
  assert_received {:opened_input, "priv/static/images/beach.jpg"}
end
```

Add the in-process fail-closed test (the honest replacement for the deleted cross-process pins — body limit wins *because* the drain runs before decode):

```elixir
test "oversized stream body fails closed before decode is attempted" do
  body = File.read!("priv/static/images/beach.jpg")

  {:ok, response} =
    Source.wrap_response(%Response{stream: [body]}, max_body_bytes: byte_size(body) - 1)

  assert {:error, {:source, :body_too_large}} =
           Processor.decode_validate_source_response(
             response,
             plan(),
             Keyword.put(opts(), :image_open_module, RecordingPathOpen)
           )

  refute_received {:opened_input, _input}
end
```

- [ ] **Step 5: Simplify the deferred-stream-error test (keep the contract, drop the dead stub)**

The contract — a raising source stream yields `{:source, :stream_exception}`, not a decode error — is still real and now realized by the drain. Update the existing test `"deferred source stream errors remain source errors during decode"` to drop the `image_open_module: DecodeRaisesSourceStreamError` override (the stub is deleted in Step 3); the default `Image` open is never reached because the drain fails first:

```elixir
test "deferred source stream errors remain source errors during decode" do
  response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
  assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

  assert {:error, {:source, :stream_exception}} =
           Processor.decode_validate_source_response(response, plan(), opts())
end
```

- [ ] **Step 6: Run the processor suite**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS. Surviving/added coverage:
- `"decode_validate_source_response returns input limit errors"` — unchanged, still `{:input_limit, {:too_many_input_pixels, _, 1}}` (decodes the drained binary).
- `"unsupported decoded source format is reported before input pixel limits"` — unchanged.
- `"deferred source stream errors remain source errors during decode"` — `{:source, :stream_exception}` via the drain.
- `"decode_validate_source_response opens a path response via the path"` — new.
- `"oversized stream body fails closed before decode is attempted"` — new; proves `{:source, :body_too_large}` and that `open/2` was never called.

If a tag differs from the above, stop and reconcile — the tags are the contract.

- [ ] **Step 7: Commit**

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
- Wire-level plug tests asserting `access:`/`fail_on:` decode options (e.g. `"safe one-pass resize opens origin with sequential access"`, `plug_test.exs:1839+`): these still pass — `decode_options` is unchanged and is passed to `open/2` on the drained binary. **Do not rewrite these**; they assert a decode-option contract, not input laziness.
- Any test that asserted the origin body is consumed *lazily* / not fully buffered. Slice A deliberately buffers HTTP/S3 input, so such a test pins the **old** input contract.

- [ ] **Step 2: For each laziness-pinning failure, fix per this rule**

- If the test has a meaningful user-visible assertion besides input laziness (status, body, dimensions, headers), drop only the laziness-specific assertion and keep the rest.
- If input laziness was the test's *only* point, **delete the test** rather than converting it into a redundant `status == 200` check — the wire-level suite (`plug_test.exs` body-limit / format tests at `:2061+`) already covers the user-visible contracts. Note any deletion in the commit message.
Re-run `mise exec -- mix test` until green.

- [ ] **Step 3: Run the architecture-boundary test explicitly**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — no new cross-boundary reference (Source still owns `Response`; `seekable_input/1` uses only `Enum`/`IO`/`Source.StreamError`; Request already depends on Source; no concrete Transform/Plan module named).

- [ ] **Step 4: Commit any test adjustments**

```bash
git add -A
git commit -m "test: align input-streaming assertions with seekable-source decode"
```

(Skip if Step 1 was already green.)

---

### Task 6: Gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

Watch for `--warnings-as-errors`: after deleting the three stubs, confirm no remaining reference to them and no now-unused alias in `processor_test.exs` (e.g. if `DecodeErrorImageOpen`/`Materializer` aliases become unused — they are used by other tests, so should stay; verify).

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
- "Drain fails closed before `Image.open`; preserve error tags" → Task 4 (`seekable_input` rescue + the in-process fail-closed test). ✓
- "All-nil adapter result returns a tagged error, not a crash" → Task 2 (catch-all) + Task 4 (third `seekable_input` clause). ✓
- "File source keeps `safe_path`/`regular_file`; TOCTOU window unchanged" → Task 3 (helpers retained) + the existing `"fetch rechecks path safety..."` test. ✓
- "Materialize-before-delivery unchanged" → not touched (keys off `access:`, unchanged). ✓
- Deferred to **Plan B** (correctly out of scope here, all explicitly listed below): `DecodePlanner {access, load_shrink}`, shrink open, `max_input_pixels` on original dims, `State.source_dimensions` + Resize geometry, equivalence-contract change, `sequential_compatibility_test.exs` deletion, measurement, **the multi-frame single-page input-pixel safety test**, and **telemetry shrink metadata on `[:source, :fetch_decode]`**.

**Placeholder scan:** none — every code step shows complete code; every run step shows the command and expected outcome. Line-number references (`:1839+`, `lines ~27-50`) are locator hints into existing files, not placeholders.

**Type consistency:** `%Response{stream: ..., path: ...}` used identically across Tasks 1–4; `seekable_input/1` returns `{:ok, path | binary} | {:error, {:source, _}}` consumed by the `with` in `decode_source_response/3`; `wrap_response/2` clauses (Task 2) match the struct from Task 1; `RecordingPathOpen.open/2` forwards `opts` to `Image.open/2`; error tags (`:body_too_large`, `:stream_exception`, `:invalid_adapter_result`, `{:input_limit, …}`) are preserved, not renamed.

---

## Next: Plan B — Shrink-on-load

To be written once Plan A lands (its tasks reference the finalized `Response`/Processor shapes). Scope, per the spec:
1. `DecodePlanner.open_options/3` → `{access, load_option}` from `(operations, source_format, original_dims)`, pure (caller supplies format + dims). Format gating: JPEG `shrink: 1|2|4|8`, WebP/vector `scale:`, PNG/HEIF/AVIF none. Orientation-corrected axis when computing `load_shrink`.
2. Processor: open the seekable input lazily, read header dims + format, validate `max_input_pixels` on **original** dims, then re-open with the load option when `load_shrink > 1`.
3. `Transform.State` gains `source_dimensions: {w, h} | nil`; `Resize.resolve_dimensions` computes the target from `source_dimensions` (original) while `resize_image` scales from the actual (shrunk) current image — guaranteeing dimension-exact output vs. the full-decode path.
4. Replace `sequential_compatibility_test.exs` with wire-level dimension-exact + coarse-downsample-MAE/SSIM equivalence tests; PNG stays pixel-exact. Add the **multi-frame/animated single-page** input-pixel safety test (assert animated inputs decode single-page so the limit can't be bypassed by frame count).
5. **Telemetry:** emit `load_option`/`achieved_shrink` + original/loaded dims on the existing `[:source, :fetch_decode]` span metadata.
6. Deterministic decoded-dimension gate proving no full-res materialization; reported (non-gating) memory benchmark.

## Review cycle

Plan v2 incorporates a 3-way parallel review (execution-correctness, scope/boundaries, test-quality):
- **Execution:** corrected Task 3 to the real `file_test.exs` fixtures (tmp dir + `images/cat.jpg` = `"image bytes"`); confirmed `Image.open/2` binary-vs-path routing, in-process `StreamError` raising on drain, intact control flow, and clean `--warnings-as-errors`.
- **Scope/boundaries [BLOCKER fixed]:** added the all-nil `seekable_input/1` clause (public function must not crash); corrected the framing to state HTTP/S3 input decode moves to a full buffer in A; added the explicit TOCTOU note; assigned the previously-unlisted multi-frame safety test and telemetry-metadata items to Plan B.
- **Test-quality [BLOCKER fixed]:** delete the two cross-process race tests + their dead stubs instead of keeping green no-ops; trimmed Task 1 to one relaxed-enforcement test; switched Task 2 to a behavior assertion; adopted the `$callers` recording idiom; added the in-process drain-fail-closed test with `refute_received`.
