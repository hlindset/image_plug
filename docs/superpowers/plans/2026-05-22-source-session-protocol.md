# SourceSession Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to build this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the protocol-only `ImagePlug.Request.SourceSession` slice that owns source-backed lazy encoding and exposes `prepare/1`, `next/1`, and `cancel/1`.

**Architecture:** This is Slice 2 only. It adds an unlinked, direct-start GenServer for protocol tests and a private request shape. Focused tests cover first-chunk preparation, one-chunk pull, cancellation, owner death, tagged call wrapper errors, and pre/post-first-chunk failure classification. It doesn't add supervision, `ImagePlug.Response.PreparedStream`, Runner wiring, `Response.Sender` changes, cache teeing, or public docs.

**Tech Stack:** Elixir, OTP `GenServer`, ExUnit, `Enumerable.reduce/3`, `Image.stream!/2`, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

Commit `ca8fee7` contains Slice 1.

`mix.exs` must still pin Vix to:

```elixir
{:vix,
 git: "https://github.com/hlindset/vix.git",
 ref: "3a30758d44526d3c914b2076bd0be201c972f2b7",
 override: true}
```

Use `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS` for focused tests that compile or run Vix.

Don't start Slice 3 from this plan. Slice 2 ends after the protocol build, verification, review cycle, accepted fixes, and design-plan updates if review changes the decision.

## Files

- Edit: `lib/image_plug/output/encoder.ex`
- Edit: `test/image_plug/output_encoder_test.exs`
- Create: `lib/image_plug/request/source_session/request.ex`
- Create: `lib/image_plug/request/source_session/prepared.ex`
- Create: `lib/image_plug/request/source_session.ex`
- Create: `test/image_plug/request/source_session_test.exs`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Read as needed: `lib/image_plug/request/processor.ex`
- Read as needed: `lib/image_plug/request/runner.ex`
- Read as needed: `lib/image_plug/response/sender.ex`
- Read as needed: `test/image_plug/request/vix_stream_continuation_test.exs`
- Update after review only if needed: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`
- Update after review only if needed: `docs/superpowers/plans/2026-05-22-source-session-protocol.md`

## Non-Goals

- Don't add `ImagePlug.Request.SourceSessionSupervisor`.
- Don't add `ImagePlug.Response.PreparedStream`.
- Don't wire `ImagePlug.Request.Runner`.
- Don't change `ImagePlug.Response.Sender`.
- Don't remove `ImagePlug.Request.SourceStreamBoundary`.
- Don't add cache teeing.
- Don't add public user documentation.
- Don't add production routing to direct-start sessions.

## Task 1: Add A Stream Output Helper

`SourceSession` needs to build the same encoded stream that `Response.Sender` builds today, but it shouldn't duplicate suffix, quality, and content-type logic. Add a narrow helper to `ImagePlug.Output.Encoder`. Leave `Response.Sender` unchanged in this slice.

**Files:**
- Edit: `test/image_plug/output_encoder_test.exs`
- Edit: `lib/image_plug/output/encoder.ex`

- [ ] **Step 1: Add failing stream helper tests**

Add these tests to `test/image_plug/output_encoder_test.exs`:

```elixir
test "stream_output returns an enumerable and content type" do
  {:ok, image} = Image.new(1, 1)
  Process.put(:test_pid, self())

  resolved_output = %Resolved{
    format: :webp,
    quality: {:quality, 80},
    response_headers: []
  }

  assert {:ok, stream, "image/webp"} =
           Encoder.stream_output(image, resolved_output, image_module: CaptureImage)

  assert Enum.to_list(stream) == ["encoded"]
  assert_received {:stream_opts, [suffix: ".webp", quality: 80]}
end

test "stream_output normalizes stream construction exceptions as encode errors" do
  {:ok, image} = Image.new(1, 1)

  assert {:error, {:encode, %RuntimeError{message: "forced stream failure"}, stacktrace}} =
           Encoder.stream_output(
             image,
             %Resolved{format: :jpeg, quality: :default, response_headers: []},
             image_module: RaisingStreamImage
           )

  assert is_list(stacktrace)
end
```

Add this nested test module near `CaptureImage`:

```elixir
defmodule RaisingStreamImage do
  def stream!(_image, _opts) do
    raise "forced stream failure"
  end
end
```

- [ ] **Step 2: Run the failing focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_encoder_test.exs
```

Expected: the two new tests fail because `Encoder.stream_output/3` doesn't exist.

- [ ] **Step 3: Add `stream_output/3`**

Add this public function after `memory_output/3`:

```elixir
@spec stream_output(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
        {:ok, Enumerable.t(), String.t()} | {:error, {:encode, Exception.t(), list()}}
def stream_output(%Vix.Vips.Image{} = image, %Resolved{} = resolved_output, opts) do
  with {:ok, mime_type, suffix} <- output_format(resolved_output) do
    stream =
      opts
      |> Keyword.get(:image_module, Image)
      |> stream_image!(image, output_options(suffix, resolved_output))

    {:ok, stream, mime_type}
  end
rescue
  exception -> {:error, {:encode, exception, __STACKTRACE__}}
end

defp stream_image!(image_module, image, output_options) do
  image_module.stream!(image, output_options)
end
```

Keep `output_options/2` private. Don't change `memory_output/3`.

- [ ] **Step 4: Run the output encoder tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_encoder_test.exs
```

Expected: all tests in the file pass.

## Task 2: Add SourceSession Request And Prepared Structs

Add the request input and protocol result shapes before the GenServer implementation.

**Files:**
- Create: `lib/image_plug/request/source_session/request.ex`
- Create: `lib/image_plug/request/source_session/prepared.ex`
- Create: `test/image_plug/request/source_session_test.exs`

- [ ] **Step 1: Write struct tests**

Create `test/image_plug/request/source_session_test.exs` with these initial tests and helpers:

```elixir
defmodule ImagePlug.Request.SourceSessionTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:stream_finalized, state})
          end
        end
      )
    end
  end

  test "request struct carries source session inputs without Plug.Conn" do
    request = request()

    assert %Request{} = request
    assert %Plan{} = request.plan
    assert %ResolvedSource{} = request.resolved_source
    assert %Policy{} = request.output_policy
    assert is_list(request.opts)
    refute match?(%{conn: _conn}, request)
  end

  test "prepared struct carries the first non-empty encoded chunk" do
    prepared = %Prepared{
      first_chunk: "first chunk",
      content_type: "image/jpeg",
      headers: [],
      resolved_output: resolved_output()
    }

    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.headers == []
  end

  defp request(overrides \\ []) do
    %Request{
      plan: Keyword.get(overrides, :plan, plan()),
      resolved_source: Keyword.get(overrides, :resolved_source, resolved_source()),
      output_policy: Keyword.get(overrides, :output_policy, output_policy()),
      opts: Keyword.get(overrides, :opts, opts())
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source(fetch \\ :fixture) do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      cache: :normal,
      fetch: fetch
    }
  end

  defp output_policy do
    %Policy{
      mode: {:explicit, :jpeg},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{}
    }
  end

  defp resolved_output do
    %Resolved{format: :jpeg, quality: :default, response_headers: []}
  end

  defp opts(extra_opts \\ []) do
    Keyword.merge([sources: %{path: {ValidAdapter, []}}, image_module: MultiChunkImage], extra_opts)
  end

  defp real_image_opts do
    opts() |> Keyword.delete(:image_module)
  end

  defp register_stream_events! do
    Process.register(self(), __MODULE__.StreamEvents)
  end
end
```

- [ ] **Step 2: Run the failing struct tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: the test file fails to compile because `Request` and `Prepared` don't exist.

- [ ] **Step 3: Add `SourceSession.Request`**

Create `lib/image_plug/request/source_session/request.ex`:

```elixir
defmodule ImagePlug.Request.SourceSession.Request do
  @moduledoc false

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Source

  @enforce_keys [:plan, :resolved_source, :output_policy, :opts]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          plan: Plan.t(),
          resolved_source: Source.Resolved.t(),
          output_policy: Policy.t(),
          opts: keyword()
        }
end
```

- [ ] **Step 4: Add `SourceSession.Prepared`**

Create `lib/image_plug/request/source_session/prepared.ex`:

```elixir
defmodule ImagePlug.Request.SourceSession.Prepared do
  @moduledoc false

  alias ImagePlug.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :resolved_output]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          resolved_output: Resolved.t()
        }
end
```

The implementation must enforce `first_chunk != ""` before constructing this struct. The type can't enforce non-empty binaries.

- [ ] **Step 5: Run the struct tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: the two struct tests pass.

## Task 3: Add The Happy SourceSession Protocol

Add `SourceSession.start/2`, `prepare/1`, `next/1`, and `cancel/1` for successful explicit-output requests. This task proves the protocol shape and one-chunk pull model only.

**Files:**
- Edit: `test/image_plug/request/source_session_test.exs`
- Create: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Add happy-path protocol tests**

Append these tests before the helper functions in `test/image_plug/request/source_session_test.exs`:

```elixir
test "prepare returns the first encoded chunk before next is called" do
  {:ok, session} = SourceSession.start(request())

  assert {:ok, %Prepared{} = prepared} = SourceSession.prepare(session)
  assert prepared.first_chunk == "first chunk"
  assert prepared.content_type == "image/jpeg"
  assert prepared.headers == []
  assert prepared.resolved_output.format == :jpeg
  assert :ok = SourceSession.cancel(session)
end

test "next returns one encoded chunk per call and then done" do
  {:ok, session} = SourceSession.start(request())

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  assert {:chunk, "second chunk"} = SourceSession.next(session)
  assert :done = SourceSession.next(session)
end

test "prepare and next exercise the real Image stream path" do
  {:ok, session} = SourceSession.start(request(opts: real_image_opts()))

  assert {:ok, %Prepared{first_chunk: first_chunk, content_type: "image/jpeg"}} =
           SourceSession.prepare(session)

  assert is_binary(first_chunk)
  assert byte_size(first_chunk) > 0

  case SourceSession.next(session) do
    {:chunk, chunk} ->
      assert is_binary(chunk)
      assert byte_size(chunk) > 0
      assert :ok = SourceSession.cancel(session)

    :done ->
      :ok
  end
end

test "cancel halts the suspended continuation and stops the session normally" do
  register_stream_events!()
  {:ok, session} = SourceSession.start(request(opts: opts(image_module: CleanupStreamImage)))
  ref = Process.monitor(session)

  assert {:ok, %Prepared{}} = SourceSession.prepare(session)
  assert :ok = SourceSession.cancel(session)
  assert_receive {:stream_finalized, :second}
  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end
```

- [ ] **Step 2: Run the failing happy-path tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: the new tests fail because `SourceSession` doesn't exist.

- [ ] **Step 3: Add the initial SourceSession module**

Create `lib/image_plug/request/source_session.ex` with this implementation shape:

```elixir
defmodule ImagePlug.Request.SourceSession do
  @moduledoc false

  use GenServer

  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.Processor.Decoded
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.StreamError
  alias ImagePlug.Transform.State

  @call_timeout 15_000
  @cancel_timeout 2_000

  defstruct [
    :request,
    :owner,
    :owner_monitor,
    :parent,
    :suspended,
    :resolved_output,
    phase: :new,
    first_error: nil,
    exits: []
  ]

  @type server() :: GenServer.server()

  @spec start(Request.t(), keyword()) :: GenServer.on_start()
  def start(%Request{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    parent = Keyword.get(opts, :parent)
    GenServer.start(__MODULE__, {request, owner, parent})
  end

  @spec prepare(server(), timeout()) ::
          {:ok, Prepared.t()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call(server, :prepare, timeout)

  @spec next(server(), timeout()) ::
          {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call(server, :cancel, timeout)

  @impl GenServer
  def init({%Request{} = request, owner, parent}) when is_pid(owner) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       request: request,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       parent: parent
     }}
  end

  @impl GenServer
  def handle_call(:prepare, _from, %{phase: :new} = state) do
    case prepare_stream(%{state | phase: :preparing}) do
      {:ok, %Prepared{} = prepared, state} ->
        {:reply, {:ok, prepared}, %{state | phase: :prepared}}

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, mark_failed(state, reason)}
    end
  end

  def handle_call(:prepare, _from, state) do
    {:reply, {:error, {:protocol, {:invalid_phase, state.phase}}}, state}
  end

  def handle_call(:next, _from, %{phase: phase} = state) when phase in [:prepared, :streaming] do
    case next_chunk(%{state | phase: :streaming}) do
      {{:chunk, chunk}, state} -> {:reply, {:chunk, chunk}, state}
      {:done, state} -> {:stop, :normal, :done, %{state | phase: :done}}
      {{:error, reason}, state} -> {:stop, :normal, {:error, reason}, mark_failed(state, reason)}
    end
  end

  def handle_call(:next, _from, state) do
    {:reply, {:error, {:protocol, :not_prepared}}, state}
  end

  def handle_call(:cancel, _from, state) do
    case halt_stream(%{state | phase: :cancelled}) do
      {:ok, state} ->
        {:stop, :normal, :ok, state}

      {:error, reason, state} ->
        {:stop, {:shutdown, {:cancel_failed, reason}}, {:error, {:cancel, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, owner, reason}, %{owner: owner, owner_monitor: ref} = state) do
    state = shutdown_halt_stream(%{state | phase: :cancelled})
    {:stop, {:shutdown, {:owner_down, reason}}, state}
  end

  def handle_info({:EXIT, pid, :normal}, state) do
    {:noreply, %{state | exits: [{pid, :normal} | state.exits]}}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    reason = {:linked_exit, pid, reason}
    {:stop, reason, mark_failed(%{state | exits: [{pid, reason} | state.exits]}, reason)}
  end

  defp call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, {:session, :timeout}}
    :exit, {:noproc, _call} -> {:error, {:session, :noproc}}
    :exit, {{:shutdown, reason}, _call} -> {:error, {:session, {:shutdown, reason}}}
    :exit, reason -> {:error, {:session, {:exit, reason}}}
  end

  defp prepare_stream(%{request: %Request{} = request} = state) do
    with {:ok, %Decoded{} = decoded} <-
           Processor.fetch_decode_validate_source_with_source_format(
             request.plan,
             request.resolved_source,
             request.opts
           ),
         {:ok, %State{} = final_state} <-
           Processor.process_decoded_source(decoded, request.plan, request.opts),
         {:ok, %Resolved{} = resolved_output} <-
           resolve_output(request.output_policy, decoded.source_format, final_state.image),
         {:ok, stream, content_type} <-
           Encoder.stream_output(final_state.image, resolved_output, request.opts),
         {:ok, first_chunk, suspended} <- first_chunk(stream) do
      prepared = %Prepared{
        first_chunk: first_chunk,
        content_type: content_type,
        headers: resolved_output.response_headers,
        resolved_output: resolved_output
      }

      {:ok, prepared, %{state | suspended: suspended, resolved_output: resolved_output}}
    else
      {:error, reason} -> {:error, reason, shutdown_halt_stream(state)}
      :empty -> {:error, {:encode, RuntimeError.exception("image encoder produced an empty stream"), []}, state}
    end
  catch
    kind, reason -> {:error, {kind, reason}, shutdown_halt_stream(state)}
  end

  defp resolve_output(%Policy{} = policy, source_format, image) do
    case Policy.resolve(policy, source_format) do
      {:ok, %Resolved{} = resolved_output} -> {:ok, resolved_output}
      {:needs_final_image_alpha, :source} -> {:ok, Policy.resolve_final_image_alpha(policy, Image.has_alpha?(image))}
      {:needs_encoded_evaluation} -> {:error, {:output, :encoded_evaluation_not_supported}}
      {:error, reason} -> {:error, {:output, reason}}
    end
  end

  defp first_chunk(stream) do
    reduce_stream(stream)
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp next_chunk(%{suspended: {acc, continuation}} = state) do
    continuation.({:cont, acc})
    |> reduce_result(%{state | suspended: nil})
  rescue
    exception in [StreamError] -> {{:error, {:source, exception.reason}}, %{state | suspended: nil}}
    exception -> {{:error, {:encode, exception, __STACKTRACE__}}, %{state | suspended: nil}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} ->
      {{:error, {:source, reason}}, %{state | suspended: nil}}

    :exit, %StreamError{reason: reason} ->
      {{:error, {:source, reason}}, %{state | suspended: nil}}

    kind, reason ->
      {{:error, {:encode, {kind, reason}, []}}, %{state | suspended: nil}}
  end

  defp next_chunk(%{suspended: nil} = state), do: {:done, state}

  defp reduce_stream(stream) do
    stream
    |> Enumerable.reduce({:cont, []}, fn
      chunk, acc when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, [chunk | acc]}
      _chunk, acc -> {:cont, acc}
    end)
    |> case do
      {:suspended, [chunk | _rest] = acc, continuation} -> {:ok, chunk, {acc, continuation}}
      {:done, []} -> :empty
      {:done, _acc} -> :empty
      {:halted, _acc} -> :empty
    end
  end

  defp reduce_result({:suspended, [chunk | _rest] = acc, continuation}, state) do
    {{:chunk, chunk}, %{state | suspended: {acc, continuation}}}
  end

  defp reduce_result({:done, _acc}, state), do: {:done, %{state | suspended: nil}}
  defp reduce_result({:halted, _acc}, state), do: {:done, %{state | suspended: nil}}

  defp halt_stream(%{suspended: nil} = state), do: {:ok, state}

  defp halt_stream(%{suspended: {acc, continuation}} = state) do
    _result = continuation.({:halt, acc})
    {:ok, %{state | suspended: nil}}
  catch
    kind, reason -> {:error, {kind, reason}, %{state | suspended: nil}}
  end

  defp shutdown_halt_stream(state) do
    case halt_stream(state) do
      {:ok, state} -> state
      {:error, reason, state} -> mark_failed(state, {:cancel, reason})
    end
  end

  defp mark_failed(state, reason), do: %{state | phase: :failed, first_error: reason}
end
```

During implementation, keep the reducer accumulator opaque. If the implementation needs a different accumulator shape to avoid stale chunk state when a continuation finishes, change the helper and tests together. Preserve the external contract: one non-empty chunk per `prepare/1` or `next/1` reply.

Slice 2 stores `parent` only to keep the owner-vs-parent state shape explicit. Direct `GenServer.start/3` doesn't create a supervisor parent link, so real parent shutdown behavior belongs to Slice 3 supervision tests.

- [ ] **Step 4: Run the happy-path tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: the happy-path tests pass. If the reducer shape causes repeated chunks or stale final state, fix the reducer before moving on.

## Task 4: Add Protocol Errors, Call Wrapper Coverage, And Owner Cleanup

This task hardens the process protocol without adding supervision.

**Files:**
- Edit: `test/image_plug/request/source_session_test.exs`
- Edit: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Add invalid protocol and wrapper tests**

Append these tests before helper functions:

```elixir
test "next before prepare returns a tagged protocol error" do
  {:ok, session} = SourceSession.start(request())

  assert {:error, {:protocol, :not_prepared}} = SourceSession.next(session)
  assert :ok = SourceSession.cancel(session)
end

test "call wrappers return tagged errors for missing sessions" do
  dead_pid = spawn(fn -> :ok end)
  ref = Process.monitor(dead_pid)
  assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

  assert {:error, {:session, :noproc}} = SourceSession.prepare(dead_pid)
end

test "call wrappers return tagged timeout errors" do
  {:ok, session} = SourceSession.start(blocking_request(), owner: self())
  ref = Process.monitor(session)
  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:prepare_result, SourceSession.prepare(session, 100)})
    end)

  try do
    assert_receive {:fetch_started, ^session}, 1_000
    assert_receive {:prepare_result, {:error, {:session, :timeout}}}, 1_000
  after
    send(session, :release_fetch)
  end

  assert_receive {:DOWN, ^ref, :process, ^session, :normal}

  caller_ref = Process.monitor(caller)
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
end
```

Add this nested source adapter in the test file so `Source.fetch/3` blocks until the test releases the session process:

```elixir
defmodule BlockingFetchAdapter do
  @behaviour ImagePlug.Source

  alias ImagePlug.Source.Resolved

  @impl ImagePlug.Source
  def validate_options(opts), do: {:ok, opts}

  @impl ImagePlug.Source
  def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

  @impl ImagePlug.Source
  def fetch(%Resolved{fetch: {:block, test_pid}}, _opts, _runtime_opts) do
    send(test_pid, {:fetch_started, self()})

    receive do
      :release_fetch -> {:error, {:source, :released}}
    end
  end
end
```

Add a helper:

```elixir
defp blocking_request do
  request(
    resolved_source: %{resolved_source({:block, self()}) | fetch: {:block, self()}},
    opts: [sources: %{path: {BlockingFetchAdapter, []}}, image_module: MultiChunkImage]
  )
end
```

Use `blocking_request()` in the timeout test.

- [ ] **Step 2: Add owner death test**

Append this test:

```elixir
test "owner death cancels the session once the active callback yields" do
  register_stream_events!()

  owner =
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)

  {:ok, session} =
    SourceSession.start(
      request(opts: opts(image_module: CleanupStreamImage)),
      owner: owner,
      parent: self()
    )

  session_ref = Process.monitor(session)
  owner_ref = Process.monitor(owner)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

  send(owner, :stop_owner)

  assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
  assert_receive {:stream_finalized, :second}
  assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
end
```

Use the blocking adapter only for the timeout test. This owner-death test must establish a suspended continuation before the owner exits. The exact claim: the session observes owner death once the GenServer callback yields and then halts session-owned lazy work.

- [ ] **Step 3: Make wrapper errors deterministic**

Adjust `SourceSession.call/3` if needed so tests can assert exact error shapes:

```elixir
defp call(server, message, timeout) do
  GenServer.call(server, message, timeout)
catch
  :exit, {:timeout, _call} -> {:error, {:session, :timeout}}
  :exit, {:noproc, _call} -> {:error, {:session, :noproc}}
  :exit, {{:shutdown, reason}, _call} -> {:error, {:session, {:shutdown, reason}}}
  :exit, {reason, _call} -> {:error, {:session, {:exit, reason}}}
  :exit, reason -> {:error, {:session, {:exit, reason}}}
end
```

Keep all wrapper returns tagged. Don't let `GenServer.call/3` exits leak to callers.

A `prepare/1` or `next/1` timeout means the caller stopped waiting. In Slice 2, the direct-start session can still be running until the active callback yields. Tests that force timeouts must release the blocked callback and confirm session shutdown with `Process.monitor/1`. Slice 3 supervision will own forced process termination for timed-out production sessions.

- [ ] **Step 4: Run SourceSession tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: all SourceSession tests pass. The timeout test must clean up the session with `cancel/1` or a `Process.monitor/1`-confirmed process exit.

## Task 5: Add Failure Classification Tests

Cover failures before the first chunk and failures after the first chunk. Use fake `image_module` streams for deterministic encode failures. Don't use Vix internals for this task.

**Files:**
- Edit: `test/image_plug/request/source_session_test.exs`
- Edit: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Add deterministic image modules**

Add these nested modules near `MultiChunkImage`:

```elixir
defmodule EmptyStreamImage do
  def stream!(_image, suffix: ".jpg"), do: []
end

defmodule RaisingBeforeFirstChunkImage do
  def stream!(_image, suffix: ".jpg") do
    Stream.resource(
      fn -> :raise end,
      fn :raise -> raise "boom before first chunk" end,
      fn _state -> :ok end
    )
  end
end

defmodule RaisingAfterFirstChunkImage do
  @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

  def stream!(_image, suffix: ".jpg") do
    Stream.resource(
      fn -> :first end,
      fn
        :first -> {["first chunk"], :raise}
        :raise -> raise "boom after first chunk"
      end,
      fn state ->
        if target = Process.whereis(@event_target) do
          send(target, {:raising_stream_finalized, state})
        end
      end
    )
  end
end

defmodule SourceErrorAfterFirstChunkImage do
  @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

  def stream!(_image, suffix: ".jpg") do
    Stream.resource(
      fn -> :first end,
      fn
        :first ->
          {["first chunk"], :raise}

        :raise ->
          raise ImagePlug.Source.StreamError, reason: :stream_exception
      end,
      fn state ->
        if target = Process.whereis(@event_target) do
          send(target, {:source_error_stream_finalized, state})
        end
      end
    )
  end
end

defmodule StreamFetchAdapter do
  @behaviour ImagePlug.Source

  alias ImagePlug.Source.Response
  alias ImagePlug.Source.Resolved

  @impl ImagePlug.Source
  def validate_options(opts), do: {:ok, opts}

  @impl ImagePlug.Source
  def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

  @impl ImagePlug.Source
  def fetch(%Resolved{fetch: {:stream, stream}}, _opts, _runtime_opts) do
    {:ok, %Response{stream: stream}}
  end
end
```

- [ ] **Step 2: Add pre-first-chunk failure tests**

Append these tests:

```elixir
test "source stream failures before the first chunk return source errors" do
  bad_stream = Stream.map([:raise], fn _ -> raise "raw stream failure" end)
  request =
    request(
      resolved_source: %{resolved_source({:stream, bad_stream}) | fetch: {:stream, bad_stream}},
      opts: [sources: %{path: {StreamFetchAdapter, []}}, image_module: MultiChunkImage]
    )

  {:ok, session} = SourceSession.start(request)
  ref = Process.monitor(session)

  assert {:error, {:source, :stream_exception}} = SourceSession.prepare(session)
  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end

test "empty encoder streams stay pre-response encode errors" do
  {:ok, session} = SourceSession.start(request(opts: opts(image_module: EmptyStreamImage)))
  ref = Process.monitor(session)

  assert {:error, {:encode, %RuntimeError{message: "image encoder produced an empty stream"}, []}} =
           SourceSession.prepare(session)

  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end

test "encoder failures before the first chunk stay pre-response encode errors" do
  {:ok, session} =
    SourceSession.start(request(opts: opts(image_module: RaisingBeforeFirstChunkImage)))

  ref = Process.monitor(session)

  assert {:error, {:encode, %RuntimeError{message: "boom before first chunk"}, stacktrace}} =
           SourceSession.prepare(session)

  assert is_list(stacktrace)
  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end
```

If `ValidAdapter` can't return an arbitrary stream through `resolved_source(fetch)`, add a nested adapter that returns `%ImagePlug.Source.Response{stream: stream}` from `fetch/3`.

- [ ] **Step 3: Add post-first-chunk failure test**

Append this test:

```elixir
test "encoder failures after the first chunk become next errors" do
  register_stream_events!()

  {:ok, session} =
    SourceSession.start(request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

  ref = Process.monitor(session)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

  assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
           SourceSession.next(session)

  assert is_list(stacktrace)
  assert_receive {:raising_stream_finalized, :raise}
  refute_receive {:raising_stream_finalized, _state}, 100
  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end

test "source stream errors during encoder reduction keep source phase" do
  register_stream_events!()

  {:ok, session} =
    SourceSession.start(request(opts: opts(image_module: SourceErrorAfterFirstChunkImage)))

  ref = Process.monitor(session)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  assert {:error, {:source, :stream_exception}} = SourceSession.next(session)
  assert_receive {:source_error_stream_finalized, :raise}
  assert_receive {:DOWN, ^ref, :process, ^session, :normal}
end
```

This test proves SourceSession phase classification. It doesn't prove Vix post-pipe writer cleanup. Slice 1 recorded that as local engineering evidence for the pinned Vix fork.

- [ ] **Step 4: Run SourceSession tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: all SourceSession tests pass.

## Task 6: Verify Boundary Exports Stay Narrow

Keep `SourceSession`, `SourceSession.Request`, and `SourceSession.Prepared` inside the `ImagePlug.Request` boundary. Slice 2 protocol tests may use these modules directly, but other boundaries don't need them yet. `Runner` will use them later from inside the same request boundary.

**Files:**
- Edit: `test/image_plug/architecture_boundary_test.exs`

- [ ] **Step 1: Add boundary expectations first if needed**

If the new modules force a Boundary test change, update `test/image_plug/architecture_boundary_test.exs` to assert that request exports remain:

```elixir
[
  ImagePlug.Request.Options,
  ImagePlug.Request.Runner
]
```

The request boundary dependency list shouldn't change. Don't export `SourceSession`, `SourceSession.Request`, or `SourceSession.Prepared` in Slice 2.

- [ ] **Step 2: Run the architecture test**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: all architecture boundary tests pass without widening request or output exports.

## Task 7: Verification And Review Checkpoint

This is the Slice 2 stop point. Run verification, dispatch the required parallel review cycle, apply accepted feedback, rerun verification, and stop before Slice 3.

**Files:**
- All files changed by Tasks 1-6
- Update design or plan docs only when review feedback changes the decision or the accepted contract.

- [ ] **Step 1: Format changed Elixir files**

Run:

```bash
mise exec -- mix format lib/image_plug/output/encoder.ex lib/image_plug/request/source_session.ex lib/image_plug/request/source_session/request.ex lib/image_plug/request/source_session/prepared.ex test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: exit 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/request/vix_stream_continuation_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 3: Run compile with warnings as errors**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: exit 0.

- [ ] **Step 4: Run the required parallel review cycle**

Dispatch four read-only reviewers in parallel after the code passes focused verification:

1. OTP lifecycle reviewer
   - Focus: GenServer callback returns, trapped exits, owner `:DOWN` behavior, parent-vs-owner semantics, cancellation, timeout wrappers, and whether production routing avoids direct `GenServer.start/3`.
   - Ask for findings ordered by severity with file and line references.
2. Vix and Enumerable mechanics reviewer
   - Focus: `Image.stream!/2` construction through `Encoder.stream_output/3`, `Enumerable.reduce/3` suspension/resume/halt, accumulator handling, empty chunks, and whether the implementation depends on the pinned Vix fork only where intended.
   - Ask whether the tests prove one-chunk pull and cleanup.
3. Test quality reviewer
   - Focus: deterministic handshakes, no sleeps, `Process.monitor/1` usage, fake image modules, source failure tests, timeout cleanup, and whether any test asserts impossible internal misuse.
   - Ask for simpler tests only if they preserve the same behavior claim.
4. Architecture boundary reviewer
   - Focus: module direction, boundary exports, no `Response.Sender` or Runner wiring, no production `GenServer.start/3` routing, no cache teeing, and whether Slice 2 remains a protocol-only slice.
   - Ask whether to continue to Slice 3, stop, or update the design.

Don't start Slice 3 while review feedback remains open.

- [ ] **Step 5: Apply accepted review feedback**

Apply technically correct feedback that stays inside Slice 2. Reject or record feedback that would add supervision, `PreparedStream`, Runner wiring, `Response.Sender` changes, or cache teeing.

After changes, rerun:

```bash
mise exec -- mix format lib/image_plug/output/encoder.ex lib/image_plug/request/source_session.ex lib/image_plug/request/source_session/request.ex lib/image_plug/request/source_session/prepared.ex test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/architecture_boundary_test.exs
```

Then rerun:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/request/vix_stream_continuation_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: formatting exits 0 and all focused tests pass.

- [ ] **Step 6: Run Vale if docs changed**

If review feedback changes this plan or the design doc, run from the main checkout:

```bash
vale .worktrees/source-session-lifecycle/docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md .worktrees/source-session-lifecycle/docs/superpowers/plans/2026-05-22-source-session-protocol.md
```

Expected: `0 errors, 0 warnings and 0 suggestions`.

- [ ] **Step 7: Commit Slice 2 only**

Stage only Slice 2 files:

```bash
git add lib/image_plug/output/encoder.ex lib/image_plug/request/source_session.ex lib/image_plug/request/source_session/request.ex lib/image_plug/request/source_session/prepared.ex test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/architecture_boundary_test.exs
git add -f docs/superpowers/plans/2026-05-22-source-session-protocol.md
```

If docs changed, also stage those doc files intentionally with `git add -f`.

Commit:

```bash
git commit -m "Add source session protocol"
```

Expected: one commit containing only Slice 2 protocol work and related tests/docs.

## Self-Review

- Spec coverage: This plan covers `SourceSession`, direct unlinked protocol startup, `prepare/1`, `next/1`, `cancel/1`, owner monitoring, parent semantics, tagged call wrappers, bounded timeouts, suspended `{acc, continuation}` state, first-chunk preparation, invalid protocol calls, pre-first-chunk source/decode/encode errors, and deterministic post-first-chunk session errors without Vix internals.
- Scope check: The plan doesn't add supervision, `Response.PreparedStream`, Runner wiring, `Response.Sender` changes, cache teeing, or public docs.
- Placeholder scan: No task relies on unspecified follow-up work. The only branches are explicit implementation choices inside the slice.
- Type consistency: Earlier tasks define `SourceSession.Request`, `SourceSession.Prepared`, `Encoder.stream_output/3`, and the public `SourceSession` wrapper return shapes before later tests use them.
