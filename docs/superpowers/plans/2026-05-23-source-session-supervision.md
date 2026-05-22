# SourceSession Supervision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans for this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add supervised temporary lifecycle ownership for `ImagePlug.Request.SourceSession` without wiring it into production request routing.

**Architecture:** This is Slice 3 only. `ImagePlug.Request.SourceSessionSupervisor` owns temporary `SourceSession` children under `ImagePlug.Application`. Callers start sessions through a narrow supervisor API, while the existing direct `SourceSession.start/2` remains protocol-test support. The slice proves parent-vs-owner semantics, supervised owner cleanup, temporary no-restart behavior, crash behavior, and caller-timeout cleanup expectations.

**Tech Stack:** Elixir, OTP `DynamicSupervisor`, OTP `GenServer`, ExUnit, Boundary, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

Slice 2 landed in `741cba3 Add source session protocol`.

`mix.exs` must keep Vix pinned to:

```elixir
{:vix,
 git: "https://github.com/hlindset/vix.git",
 ref: "3a30758d44526d3c914b2076bd0be201c972f2b7",
 override: true}
```

Run focused tests involving Vix with:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test ...
```

Don't start Slice 4 from this plan. Slice 3 ends after supervision implementation, focused verification, the required parallel review cycle, accepted fixes, Vale, commit, and a stop before `PreparedStream` wiring.

## Files

- Create: `lib/image_plug/request/source_session_supervisor.ex`
- Create: `test/image_plug/request/source_session_supervisor_test.exs`
- Edit: `lib/image_plug/request/source_session.ex`
- Edit: `lib/image_plug/request.ex`
- Edit: `lib/application.ex`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Read as needed: `test/image_plug/request/source_session_test.exs`
- Read as needed: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`
- Read as needed: `docs/superpowers/plans/2026-05-22-source-session-protocol.md`

## Non-Goals

- Don't add `ImagePlug.Response.PreparedStream`.
- Don't wire `ImagePlug.Request.Runner`.
- Don't change `ImagePlug.Response.Sender`.
- Don't add cache teeing.
- Don't remove `ImagePlug.Request.SourceStreamBoundary`.
- Don't expose `SourceSession` as public API.
- Don't add public docs.
- Don't move direct `GenServer.start/3` sessions into production routing.

## Task 1: Add Supervision Tests First

Add focused tests for the supervised lifecycle before adding the supervisor module. These tests should use supervised startup and `Process.monitor/1` assertions. Don't use `Process.sleep/1` or `Process.alive?/1`.

**Files:**
- Create: `test/image_plug/request/source_session_supervisor_test.exs`

- [ ] **Step 1: Create failing supervisor lifecycle tests**

Create `test/image_plug/request/source_session_supervisor_test.exs`:

```elixir
defmodule ImagePlug.Request.SourceSessionSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Request.SourceSessionSupervisor
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSessionSupervisorTest.StreamEvents

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

  test "start_session starts a temporary supervised source session" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request())

    assert %{active: 1, workers: 1} = DynamicSupervisor.count_children(supervisor)
    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  test "start_session defaults owner to the calling process" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    request = request(opts: opts(image_module: CleanupStreamImage))
    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} = SourceSessionSupervisor.start_session(supervisor, request)
        send(parent, {:session_started, self(), session})

        receive do
          :stop_owner -> :ok
        end
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:session_started, ^owner, session}, 1_000
    session_ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  test "explicit owner death cleans up a supervised prepared session" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    owner = idle_owner!()

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage)),
               owner: owner
             )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  test "supervisor shutdown is parent shutdown, not request owner death" do
    register_stream_events!()

    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage)),
               owner: self()
             )

    session_ref = Process.monitor(session)
    supervisor_ref = Process.monitor(supervisor)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    capture_log(fn ->
      Supervisor.stop(supervisor, :shutdown)
    end)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :shutdown}
  end

  test "supervised cancel finalizes the stream and removes the temporary child" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage))
             )

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert :ok = SourceSession.cancel(session)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  test "stop_session gracefully finalizes a prepared stream" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage))
             )

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert :ok = SourceSessionSupervisor.stop_session(supervisor, session)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  test "stop_session is idempotent for non-child pids" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    other_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(other_pid)

    assert :ok = SourceSessionSupervisor.stop_session(supervisor, other_pid)

    send(other_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^other_pid, :normal}
  end

  test "temporary sessions are not restarted after a crash before prepare" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request(), owner: self())

    ref = Process.monitor(session)

    capture_log(fn ->
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    end)

    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
    assert {:error, {:session, :noproc}} = SourceSession.prepare(session)
  end

  test "temporary sessions are not restarted after a crash after the first chunk" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request(), owner: self())

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    capture_log(fn ->
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    end)

    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
    assert {:error, {:session, :noproc}} = SourceSession.next(session)
  end

  test "request owner timeout while prepare is blocked leaves cleanup to the supervisor facade" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} = SourceSessionSupervisor.start_session(supervisor, blocking_request(parent))
        send(parent, {:session_started, self(), session})
        send(parent, {:prepare_result, SourceSession.prepare(session, 100)})
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:session_started, ^owner, session}, 1_000
    session_ref = Process.monitor(session)
    assert_receive {:fetch_started, ^session}, 1_000
    assert_receive {:prepare_result, {:error, {:session, :timeout}}}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert %{active: 1} = DynamicSupervisor.count_children(supervisor)

    assert :ok = SourceSessionSupervisor.stop_session(supervisor, session)
    assert_receive {:DOWN, ^session_ref, :process, ^session, reason}
    assert reason in [:shutdown, :killed]
    assert %{active: 0} = DynamicSupervisor.count_children(supervisor)
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

  defp opts(extra_opts \\ []) do
    Keyword.merge(
      [sources: %{path: {ValidAdapter, []}}, image_module: MultiChunkImage],
      extra_opts
    )
  end

  defp blocking_request(test_pid \\ self()) do
    request(
      resolved_source: %{resolved_source({:block, test_pid}) | fetch: {:block, test_pid}},
      opts: [sources: %{path: {BlockingFetchAdapter, []}}, image_module: MultiChunkImage]
    )
  end

  defp idle_owner! do
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)
  end

  defp register_stream_events! do
    Process.register(self(), __MODULE__.StreamEvents)
  end
end
```

- [ ] **Step 2: Run the failing supervisor tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_supervisor_test.exs
```

Expected: compilation fails because `ImagePlug.Request.SourceSessionSupervisor` doesn't exist.

## Task 2: Add SourceSession Supervised Startup Hooks

Add linked startup only for supervisor-owned children. Keep `SourceSession.start/2` as direct unlinked protocol-test startup.

**Files:**
- Edit: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Add `start_link/2` and `child_spec/1`**

In `lib/image_plug/request/source_session.ex`, add these functions near `start/2`:

```elixir
@shutdown_timeout 2_000

@spec start_link(Request.t(), keyword()) :: GenServer.on_start()
def start_link(%Request{} = request, opts \\ []) do
  owner = Keyword.get(opts, :owner, self())
  parent = Keyword.get(opts, :parent, self())

  GenServer.start_link(__MODULE__, {request, owner, parent})
end

@spec child_spec({Request.t(), keyword()}) :: Supervisor.child_spec()
def child_spec({%Request{} = request, opts}) do
  %{
    id: {__MODULE__, make_ref()},
    start: {__MODULE__, :start_link, [request, opts]},
    restart: :temporary,
    shutdown: @shutdown_timeout,
    type: :worker,
    modules: [__MODULE__]
  }
end
```

Keep `start/2` unchanged except for sharing any small private helper needed to avoid duplicate owner/parent option extraction.

- [ ] **Step 2: Treat parent shutdown as controlled shutdown**

Add a parent-specific `handle_info/2` clause before the generic abnormal `{:EXIT, pid, reason}` clause:

```elixir
def handle_info({:EXIT, parent, :shutdown}, %{parent: parent} = state) do
  state = shutdown_halt_stream(%{state | phase: :cancelled})
  {:stop, :shutdown, state}
end
```

If a later test proves parent exits can use `{:shutdown, term()}`, add this adjacent clause:

```elixir
def handle_info({:EXIT, parent, {:shutdown, _reason} = shutdown}, %{parent: parent} = state) do
  state = shutdown_halt_stream(%{state | phase: :cancelled})
  {:stop, shutdown, state}
end
```

Don't classify supervisor shutdown as `{:linked_exit, parent, :shutdown}`.

- [ ] **Step 3: Run focused SourceSession tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: existing Slice 2 tests still pass.

## Task 3: Add SourceSessionSupervisor

Add a request-boundary supervisor API. The supervisor module is the only module outside `SourceSession` tests that should start session children in later slices.

**Files:**
- Create: `lib/image_plug/request/source_session_supervisor.ex`

- [ ] **Step 1: Create the supervisor module**

Create `lib/image_plug/request/source_session_supervisor.ex`:

```elixir
defmodule ImagePlug.Request.SourceSessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias ImagePlug.Request.SourceSession
  alias ImagePlug.Request.SourceSession.Request

  @type supervisor() :: DynamicSupervisor.supervisor()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])

    DynamicSupervisor.start_link(__MODULE__, init_opts, start_link_opts(start_opts))
  end

  @spec start_session(Request.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(%Request{} = request, opts \\ []) do
    start_session(__MODULE__, request, opts)
  end

  @spec start_session(supervisor(), Request.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(supervisor, %Request{} = request, opts) do
    opts = Keyword.put_new(opts, :owner, self())

    DynamicSupervisor.start_child(supervisor, {SourceSession, {request, opts}})
  end

  @spec stop_session(supervisor(), pid()) :: :ok
  def stop_session(supervisor, pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  defp start_link_opts([]), do: [name: __MODULE__]
  defp start_link_opts(name: nil), do: []
  defp start_link_opts(opts), do: opts
end
```

Keep the API narrow: `start_link/1`, `start_session/2`, `start_session/3`, and `stop_session/2`.

The supervisor API, not `SourceSession.start_link/2`, owns the default owner decision. `start_session/3` must set `owner: self()` before handing the child spec to `DynamicSupervisor.start_child/2`, because `SourceSession.start_link/2` runs from the supervisor start path and `self()` there is the supervisor process.

`stop_session/2` is intentionally idempotent. It's cleanup support for timeout and pre-commit failure paths, so callers shouldn't have to distinguish an active child from a child that already stopped normally.

- [ ] **Step 2: Run the supervisor tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_supervisor_test.exs
```

Expected: tests pass except for application and Boundary checks that haven't landed yet.

## Task 4: Wire Application And Boundary Declarations

Start the named session supervisor under the application and make the Boundary dependency explicit.

**Files:**
- Edit: `lib/application.ex`
- Edit: `lib/image_plug/request.ex`
- Edit: `test/image_plug/architecture_boundary_test.exs`

- [ ] **Step 1: Add application and boundary tests**

In `test/image_plug/architecture_boundary_test.exs`, update `@boundary_files`:

```elixir
@boundary_files %{
  ImagePlug.Application => "lib/application.ex",
  ImagePlug.Cache => "lib/image_plug/cache.ex",
  ...
}
```

Add this test near the existing boundary declaration tests:

```elixir
test "application boundary owns OTP startup and depends on request lifecycle infrastructure" do
  application = boundary_declaration(ImagePlug.Application)

  assert_boundary_deps(application, [ImagePlug.Request])
  assert_boundary_exports(application, [])
end
```

Add this architecture test near the request/response boundary tests:

```elixir
test "slice 3 keeps source sessions out of runner and response sender" do
  forbidden_terms = ["PreparedStream", "prepared_stream", "SourceSessionSupervisor", "SourceSession"]

  violations =
    for file <- ["lib/image_plug/request/runner.ex", "lib/image_plug/response/sender.ex"],
        {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        term <- forbidden_terms,
        String.contains?(line, term) do
      "#{file}:#{number} must not wire #{term} before Slice 4"
    end

  assert violations == []
end
```

Update the request boundary expectation:

```elixir
assert_boundary_exports(request, [
  ImagePlug.Request.Options,
  ImagePlug.Request.Runner,
  ImagePlug.Request.SourceSessionSupervisor
])
```

Add this test to `test/image_plug/request/source_session_supervisor_test.exs`:

```elixir
test "application starts the named source session supervisor" do
  assert {SourceSessionSupervisor, pid, :supervisor, [SourceSessionSupervisor]} =
           ImagePlug.Supervisor
           |> Supervisor.which_children()
           |> List.keyfind(SourceSessionSupervisor, 0)

  assert pid == Process.whereis(SourceSessionSupervisor)
end
```

- [ ] **Step 2: Run the failing architecture and supervisor tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/architecture_boundary_test.exs test/image_plug/request/source_session_supervisor_test.exs
```

Expected: tests fail because `ImagePlug.Application` still has no request dependency, `ImagePlug.Request` doesn't export `SourceSessionSupervisor`, and the application child isn't started.

- [ ] **Step 3: Wire application startup**

Change `lib/application.ex` to:

```elixir
defmodule ImagePlug.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Request
    ]

  use Application

  require Logger

  def start(_type, _args) do
    children = [
      ImagePlug.Request.SourceSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ImagePlug.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 4: Export the supervisor API from the request boundary**

Change `lib/image_plug/request.ex` exports to:

```elixir
exports: [
  Options,
  Runner,
  SourceSessionSupervisor
]
```

Don't export `SourceSession`, `SourceSession.Request`, or `SourceSession.Prepared`.

Don't edit `lib/image_plug/response.ex`. The response boundary must keep refuting `ImagePlug.Request` and exporting only `ImagePlug.Response.Sender` in this slice.

- [ ] **Step 5: Run architecture and supervisor tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/architecture_boundary_test.exs test/image_plug/request/source_session_supervisor_test.exs
```

Expected: all tests pass.

## Task 5: Verify Slice 3 Scope

Run the focused verification set and confirm this slice didn't start production routing.

**Files:**
- Read: `lib/image_plug/request/runner.ex`
- Read: `lib/image_plug/response/sender.ex`
- Read: `lib/image_plug/request/source_session_supervisor.ex`
- Read: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Run focused request/session tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/output_encoder_test.exs test/image_plug/request/source_session_test.exs test/image_plug/request/source_session_supervisor_test.exs test/image_plug/request/vix_stream_continuation_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: all tests pass.

- [ ] **Step 2: Run warnings-as-errors compilation**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: compilation succeeds with no warnings.

- [ ] **Step 3: Confirm architecture tests enforce no Slice 4 wiring**

The architecture test added in Task 4 must fail if `Runner` or `Response.Sender` references `PreparedStream`, `prepared_stream`, `SourceSessionSupervisor`, or `SourceSession`.

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: all architecture tests pass. If the new Slice 3 routing guard fails, remove the production routing from this slice.

- [ ] **Step 4: Run Vale on the plan**

Run:

```bash
mise exec -- vale docs/superpowers/plans/2026-05-23-source-session-supervision.md
```

Expected: no errors. Address suggestions that conflict with `AGENTS.md` documentation style.

## Review Checkpoint

After Task 5, run the required parallel subagent review cycle before committing implementation changes.

Use four reviewers with these focuses:

- OTP lifecycle: `DynamicSupervisor`, temporary restart semantics, `SourceSession.start_link/2`, parent shutdown, trapped exits, owner monitors, and timeout cleanup.
- Supervision/application wiring: application child startup, child specs, named vs anonymous supervisors in tests, `stop_session/2`, and no accidental direct production starts.
- Test quality: deterministic handshakes, monitors instead of sleeps, no brittle `Process.alive?/1`, no source-text policing outside architecture tests, and exact claims proven by tests.
- Architecture boundaries: request boundary exports, application boundary dependency direction, no response-to-request dependency, no Runner/Sender wiring, and `SourceSession` remaining private.

Apply accepted feedback, rerun the focused tests and compile command, rerun Vale if this plan changes, then commit.

## Stop Criteria

Stop after Slice 3 when these are true:

- `ImagePlug.Request.SourceSessionSupervisor` exists and starts temporary session children.
- `ImagePlug.Application` starts the named supervisor.
- `ImagePlug.Application` explicitly depends on `ImagePlug.Request` through Boundary.
- `ImagePlug.Request` exports `SourceSessionSupervisor` but not `SourceSession`.
- Supervised owner death halts a prepared stream and stops the session.
- Parent shutdown exits as controlled shutdown, not an image-processing error.
- Temporary sessions aren't restarted after normal completion, cancellation, or crash.
- `stop_session/2` is idempotent and finalizes a prepared stream when the child can process supervisor shutdown.
- Tests document caller timeout behavior: the owner call returns a tagged timeout error while blocked work remains active until explicit supervisor cleanup stops the child.
- `Runner` and `Response.Sender` remain untouched by SourceSession supervision.
- Verification commands pass.
- Resolve parallel plan/implementation review feedback.
- Commit the reviewed Slice 3 changes.

## Implementation Notes

`SourceSessionSupervisor.stop_session/2` is intentionally a lifecycle cleanup helper, not a response protocol. Slice 4 can use it when a pre-commit caller timeout leaves a session still active. Post-commit delivery should still prefer `SourceSession.cancel/2` through the future `PreparedStream.cancel` callback, because cancellation halts the suspended enumerable before the child exits.

The supervised child spec should use `restart: :temporary`. A request session is single-use request state. Restarting it after completion, cancellation, or crash would recreate source fetch and encoder state without an HTTP caller that can consume it.

The direct `SourceSession.start/2` function remains because Slice 2 protocol tests intentionally avoid supervisor coupling. Production routing must use `SourceSessionSupervisor.start_session/2` after Slice 4 begins.

## Self-Review

- Spec coverage: The plan covers a dynamic supervisor, temporary children, supervised `start_session/2`, caller-owned default ownership, `SourceSession` child spec changes, parent-vs-owner semantics, owner death cleanup, supervised cancellation, graceful and idempotent `stop_session/2`, crash before and after first chunk, caller timeout cleanup expectations, Boundary declarations, and no production routing.
- Placeholder scan: No task uses placeholder language or unspecified "add tests" steps. Code snippets and commands are concrete.
- Type consistency: The plan defines `SourceSessionSupervisor.start_session/2`, `start_session/3`, and `stop_session/2` before tests rely on them. `SourceSession.start_link/2` and `child_spec/1` match the child spec passed to `DynamicSupervisor.start_child/2`.
