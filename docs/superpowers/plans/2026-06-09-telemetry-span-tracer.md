# Telemetry Span Tracer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in layer that consumes ImagePipe's existing `:telemetry.span/3` events, reconstructs correctly-nested distributed-trace-shaped spans, and hands each finished span to a pluggable exporter.

**Architecture:** A per-process active-span stack (process dictionary) reconstructs nesting within a process; `Trace.Context` is threaded as data across the request→SourceSession and request→Producer hops; a new `[:transform, :materialize]` span gives honest libvips flush timing; an opt-in plug edge extracts inbound W3C `traceparent`; Req/Finch get logical + physical client spans. Everything lives under `ImagePipe.Telemetry.Trace.*` (telemetry boundary), attaches only on `ImagePipe.Telemetry.attach_tracer/1`, and ships a stdlib `LogExporter`.

**Tech Stack:** Elixir, `:telemetry` 1.x, Req 0.5 / Finch 0.22, Plug, NimbleOptions, Boundary, ExUnit + StreamData.

**Design spec:** `docs/superpowers/specs/2026-06-09-telemetry-span-tracer-design.md` — read it before starting; this plan implements it.

**Run commands with `mise exec -- …`** (project rule). Focused test: `mise exec -- mix test test/path_test.exs:LINE`. Gate before finishing a phase: `mise run precommit`.

---

## File structure

**New (telemetry boundary, `lib/image_pipe/telemetry/trace/`):**
- `context.ex` — `Trace.Context` immutable serializable context struct
- `span.ex` — `Trace.Span` captured-span struct
- `id.ex` — `Trace.Id` random id generation
- `w3c.ex` — `Trace.W3C` traceparent encode/decode
- `stack.ex` — `Trace.Stack` process-dictionary active-span stack
- `capture.ex` — `Trace.Capture` attach_many handler for `[:image_pipe, …]`
- `finch_capture.ex` — `Trace.FinchCapture` attach_many handler for `[:finch, …]`
- `req_step.ex` — `Trace.ReqStep` Req request/response/error steps
- `exporter.ex` — `Trace.Exporter` behaviour
- `log_exporter.ex` — `Trace.LogExporter` stdlib default

**Modified:**
- `lib/image_pipe/telemetry.ex` — add `attach_tracer/1` / `detach_tracer/0`; boundary `exports:`
- `lib/image_pipe/transform/materializer.ex` — wrap flush in `[:transform, :materialize]` span
- `lib/image_pipe/telemetry/logger.ex` — subscribe + level-escalate the materialize event
- `lib/image_pipe/plug.ex` — opt-in inbound `traceparent` extraction before the `[:request]` span
- `lib/image_pipe/request/runner.ex` — capture `Trace.Stack.context()` at `start_session`
- `lib/image_pipe/request/source_session_supervisor.ex` + `source_session.ex` — thread + adopt context (hop A)
- `lib/image_pipe/request/source_session/producer.ex` — adopt context (hop B)
- `lib/image_pipe/source/req_stream.ex` (or the Req-client build site) — attach `Trace.ReqStep`
- `docs/telemetry.md` — materialize subsection + `## Tracing (opt-in)` section

**New test files:** mirror under `test/image_pipe/telemetry/trace/` plus a shared `test/support/trace_test_exporter.ex`.

---

# Phase 1 — Core capture + materialize barrier + Logger/doc sync

Self-contained: produces a working in-process tracer (single-process subtree) plus the honest materialize span and its full Logger/doc sync. Reviewable and committable on its own.

## Task 1: `Trace.Id` — random trace/span ids

**Files:**
- Create: `lib/image_pipe/telemetry/trace/id.ex`
- Test: `test/image_pipe/telemetry/trace/id_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/id_test.exs
defmodule ImagePipe.Telemetry.Trace.IdTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.Id

  test "trace_id is 32 lowercase hex chars and unique" do
    a = Id.trace_id()
    b = Id.trace_id()
    assert a =~ ~r/\A[0-9a-f]{32}\z/
    assert a != b
  end

  test "span_id is 16 lowercase hex chars and unique" do
    a = Id.span_id()
    assert a =~ ~r/\A[0-9a-f]{16}\z/
    assert a != Id.span_id()
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/id_test.exs`
Expected: FAIL — `ImagePipe.Telemetry.Trace.Id is undefined`.

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe/telemetry/trace/id.ex
defmodule ImagePipe.Telemetry.Trace.Id do
  @moduledoc false

  @spec trace_id() :: String.t()
  def trace_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  @spec span_id() :: String.t()
  def span_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/id_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/id.ex test/image_pipe/telemetry/trace/id_test.exs
git commit -m "feat(telemetry): Trace.Id random trace/span ids"
```

## Task 2: `Trace.Context` struct

**Files:**
- Create: `lib/image_pipe/telemetry/trace/context.ex`
- Test: covered via `W3C` round-trip (Task 3) — no standalone test (a bare struct has no behavior to assert; testing it alone would be a no-value test per CLAUDE.md).

- [ ] **Step 1: Implement the struct**

```elixir
# lib/image_pipe/telemetry/trace/context.ex
defmodule ImagePipe.Telemetry.Trace.Context do
  @moduledoc """
  Immutable, serializable trace context that crosses process/node/HTTP seams.

  Carries the current span identity so a far-side process (or downstream service)
  can attach children under it. `span_id` becomes the child's `parent_span_id`.
  """

  @enforce_keys [:trace_id, :span_id]
  defstruct [:trace_id, :span_id, trace_flags: 1, baggage: %{}]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          trace_flags: non_neg_integer(),
          baggage: %{optional(String.t()) => String.t()}
        }
end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/telemetry/trace/context.ex
git commit -m "feat(telemetry): Trace.Context serializable trace context"
```

## Task 3: `Trace.W3C` — traceparent encode/decode

**Files:**
- Create: `lib/image_pipe/telemetry/trace/w3c.ex`
- Test: `test/image_pipe/telemetry/trace/w3c_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/w3c_test.exs
defmodule ImagePipe.Telemetry.Trace.W3CTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.{Context, Id, W3C}

  test "encode produces a valid W3C traceparent" do
    tp = W3C.encode("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331", 1)
    assert tp == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  end

  test "round-trips a freshly generated context" do
    tid = Id.trace_id()
    sid = Id.span_id()
    assert {:ok, %Context{trace_id: ^tid, span_id: ^sid, trace_flags: 1}} =
             tid |> W3C.encode(sid, 1) |> W3C.decode()
  end

  test "decode rejects malformed input" do
    assert W3C.decode("garbage") == :error
    assert W3C.decode("00-short-b7ad6b7169203331-01") == :error
    assert W3C.decode("00-" <> String.duplicate("0", 32) <> "-b7ad6b7169203331-01") == :error
    assert W3C.decode("") == :error
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/w3c_test.exs`
Expected: FAIL — `W3C is undefined`.

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe/telemetry/trace/w3c.ex
defmodule ImagePipe.Telemetry.Trace.W3C do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Context

  @all_zero_trace String.duplicate("0", 32)
  @all_zero_span String.duplicate("0", 16)

  @spec encode(String.t(), String.t(), non_neg_integer()) :: String.t()
  def encode(trace_id, span_id, flags \\ 1) do
    "00-" <> trace_id <> "-" <> span_id <> "-" <> flags_hex(flags)
  end

  @spec decode(String.t()) :: {:ok, Context.t()} | :error
  def decode("00-" <> rest) do
    with [t, s, f] <- String.split(rest, "-"),
         true <- valid_trace?(t),
         true <- valid_span?(s),
         {:ok, flags} <- parse_flags(f) do
      {:ok, %Context{trace_id: String.downcase(t), span_id: String.downcase(s), trace_flags: flags}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp valid_trace?(t), do: byte_size(t) == 32 and hex?(t) and String.downcase(t) != @all_zero_trace
  defp valid_span?(s), do: byte_size(s) == 16 and hex?(s) and String.downcase(s) != @all_zero_span

  defp parse_flags(f) when byte_size(f) == 2 do
    case Integer.parse(f, 16) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_flags(_), do: :error

  defp flags_hex(flags) do
    flags |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  end

  defp hex?(s), do: String.match?(s, ~r/\A[0-9a-fA-F]+\z/)
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/w3c_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/w3c.ex test/image_pipe/telemetry/trace/w3c_test.exs
git commit -m "feat(telemetry): Trace.W3C traceparent encode/decode"
```

## Task 4: `Trace.Span` struct

**Files:**
- Create: `lib/image_pipe/telemetry/trace/span.ex`
- Test: none standalone (struct exercised by `Capture` tests in Task 6).

- [ ] **Step 1: Implement**

```elixir
# lib/image_pipe/telemetry/trace/span.ex
defmodule ImagePipe.Telemetry.Trace.Span do
  @moduledoc """
  A captured span handed to a `ImagePipe.Telemetry.Trace.Exporter`.

  OTel-shaped so a Jaeger/Tempo/OTLP mapping is mechanical. `duration_native` is the
  honest timing source (raw monotonic units from `:telemetry.span/3`); `start_time`/
  `end_time` are wall-clock (`system_time`) for export.
  """

  @enforce_keys [:trace_id, :span_id, :name, :start_time]
  defstruct [
    :trace_id,
    :span_id,
    :parent_span_id,
    :name,
    :kind,
    :start_time,
    :end_time,
    :duration_native,
    :status,
    :status_message,
    :pid,
    :node,
    attributes: %{},
    events: [],
    links: []
  ]

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil,
          name: String.t(),
          kind: :internal | :server | :client | nil,
          start_time: integer() | nil,
          end_time: integer() | nil,
          duration_native: integer() | nil,
          status: :unset | :ok | :error | nil,
          status_message: String.t() | nil,
          pid: pid() | nil,
          node: node() | nil,
          attributes: map(),
          events: [map()],
          links: [map()]
        }
end
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/telemetry/trace/span.ex
git commit -m "feat(telemetry): Trace.Span captured-span struct"
```

## Task 5: `Trace.Stack` — process-dictionary active-span stack

**Files:**
- Create: `lib/image_pipe/telemetry/trace/stack.ex`
- Test: `test/image_pipe/telemetry/trace/stack_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/stack_test.exs
defmodule ImagePipe.Telemetry.Trace.StackTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.{Context, Span, Stack}

  defp span(name), do: %Span{trace_id: "t", span_id: name, name: name, start_time: 0}

  setup do
    on_exit(fn -> Stack.clear() end)
    Stack.clear()
    :ok
  end

  test "push/current/pop are LIFO" do
    assert Stack.current() == nil
    Stack.push(span("a"))
    Stack.push(span("b"))
    assert Stack.current().span_id == "b"
    assert Stack.pop().span_id == "b"
    assert Stack.current().span_id == "a"
    assert Stack.pop().span_id == "a"
    assert Stack.pop() == nil
  end

  test "nested-then-sibling preserves parentage order" do
    Stack.push(span("root"))
    Stack.push(span("child1"))
    assert Stack.pop().span_id == "child1"
    # sibling: parent is root again
    assert Stack.current().span_id == "root"
    Stack.push(span("child2"))
    assert Stack.current().span_id == "child2"
  end

  test "context/0 snapshots the current span identity" do
    assert Stack.context() == nil
    Stack.push(%Span{trace_id: "abc", span_id: "def", name: "x", start_time: 0})
    assert %Context{trace_id: "abc", span_id: "def"} = Stack.context()
  end

  test "adopt/1 seeds a remote-parent frame; next span inherits it" do
    Stack.adopt(%Context{trace_id: "rt", span_id: "rs", trace_flags: 1})
    assert %Context{trace_id: "rt", span_id: "rs"} = Stack.context()
    # a child pushed now would read current() as its parent
    assert Stack.current().span_id == "rs"
  end

  test "adopt(nil) is a no-op" do
    Stack.adopt(nil)
    assert Stack.current() == nil
  end
end
```

- [ ] **Step 2: Run it, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/stack_test.exs`
Expected: FAIL — `Stack is undefined`.

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe/telemetry/trace/stack.ex
defmodule ImagePipe.Telemetry.Trace.Stack do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.{Context, Span}

  @key :"$image_pipe_trace_stack"

  @spec current() :: Span.t() | nil
  def current, do: List.first(stack())

  @spec push(Span.t()) :: :ok
  def push(%Span{} = span), do: put([span | stack()])

  @spec pop() :: Span.t() | nil
  def pop do
    case stack() do
      [top | rest] ->
        put(rest)
        top

      [] ->
        nil
    end
  end

  @spec context() :: Context.t() | nil
  def context do
    case current() do
      nil -> nil
      %Span{trace_id: t, span_id: s} -> %Context{trace_id: t, span_id: s}
    end
  end

  @doc "Seed the far side of a process hop with a synthetic remote-parent frame."
  @spec adopt(Context.t() | nil) :: :ok
  def adopt(nil), do: :ok

  def adopt(%Context{trace_id: t, span_id: s}) do
    push(%Span{trace_id: t, span_id: s, name: "remote_parent", start_time: nil})
  end

  @doc false
  @spec clear() :: :ok
  def clear, do: put([])

  defp stack, do: Process.get(@key, [])
  defp put(stack), do: (Process.put(@key, stack); :ok)
end
```

- [ ] **Step 4: Run it, verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/stack_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/stack.ex test/image_pipe/telemetry/trace/stack_test.exs
git commit -m "feat(telemetry): Trace.Stack per-process active-span stack"
```

## Task 6: `Trace.Exporter` behaviour + `Trace.Capture` handler + `TestExporter`

This is the heart of Phase 1: subscribe to `[:image_pipe, …]` span events, reconstruct nesting via the stack, fold one-shots, finalize status, export. Inbound-context read (Task in Phase 2) is stubbed to `nil` here.

**Files:**
- Create: `lib/image_pipe/telemetry/trace/exporter.ex`
- Create: `lib/image_pipe/telemetry/trace/capture.ex`
- Create: `test/support/trace_test_exporter.ex`
- Test: `test/image_pipe/telemetry/trace/capture_test.exs`

- [ ] **Step 1: Define the Exporter behaviour**

```elixir
# lib/image_pipe/telemetry/trace/exporter.ex
defmodule ImagePipe.Telemetry.Trace.Exporter do
  @moduledoc """
  Behaviour a host implements to receive captured spans, one per completed span.

  `export/1` is called synchronously in the process that emitted the span's `:stop`/
  `:exception`. Keep it cheap and non-blocking — hand off to a batch processor for any
  real I/O. It must return `:ok` and should not raise. Attributes are pre-filtered for
  sensitivity (`ImagePipe.Telemetry.Trace.Capture` allowlists them), but exporters that
  fan out to third parties remain responsible for their own egress policy.
  """
  alias ImagePipe.Telemetry.Trace.Span

  @callback export(Span.t()) :: :ok
end
```

- [ ] **Step 2: Add the TestExporter support module**

```elixir
# test/support/trace_test_exporter.ex
defmodule ImagePipe.Telemetry.Trace.TestExporter do
  @moduledoc """
  Test-only exporter. Spans are exported from MULTIPLE processes (Producer,
  SourceSession), so the receiver pid must be reachable globally — we use
  :persistent_term. REQUIREMENT: every test module using this must be `async: false`
  (ExUnit runs async:false modules with no concurrent test), and must clear the
  receiver in on_exit to keep the global key from leaking across modules.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  @key {__MODULE__, :receiver}

  @doc "Attach the tracer with this exporter and route spans to `test_pid`."
  def attach(test_pid, opts \\ []) do
    set_receiver(test_pid)
    ImagePipe.Telemetry.attach_tracer(Keyword.merge([exporter: __MODULE__], opts))
  end

  def set_receiver(pid), do: :persistent_term.put(@key, pid)
  def clear_receiver, do: :persistent_term.put(@key, nil)

  @impl true
  def export(span) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      pid -> send(pid, {:span, span})
    end

    :ok
  end
end
```

Ensure `test/support` is compiled: confirm `elixirc_paths(:test)` includes `"test/support"` in `mix.exs` (it commonly does; if not, add it in this step).

**Every trace test setup must be symmetric** — clear the receiver and detach on exit:

```elixir
  setup do
    ImagePipe.Telemetry.Trace.TestExporter.set_receiver(self())
    :ok = ImagePipe.Telemetry.Trace.TestExporter.attach(self())

    on_exit(fn ->
      ImagePipe.Telemetry.detach_tracer()
      ImagePipe.Telemetry.Trace.TestExporter.clear_receiver()
    end)

    :ok
  end
```

Use this exact `on_exit` shape in **all** trace test modules below (replacing the shorter `on_exit(fn -> Telemetry.detach_tracer() end)` shown in individual tasks).

- [ ] **Step 3: Write the failing capture test (single-process tree)**

```elixir
# test/image_pipe/telemetry/trace/capture_test.exs
defmodule ImagePipe.Telemetry.Trace.CaptureTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  defp emit_nested do
    Telemetry.span([], [:request], %{}, fn ->
      Telemetry.span([], [:transform, :execute], %{operation_count: 1}, fn ->
        {:ok, %{result: :ok}}
      end)

      {:ok, %{result: :ok, status: 200}}
    end)
  end

  test "captures a nested tree with one trace_id and correct parentage" do
    emit_nested()

    assert_receive {:span, %Span{name: "image_pipe.transform.execute"} = child}
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}

    assert root.parent_span_id == nil
    assert child.parent_span_id == root.span_id
    assert child.trace_id == root.trace_id
    assert root.status == :ok
    assert is_integer(child.duration_native)
  end

  test "maps an error result to :error status" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :processing_error}} end)
    assert_receive {:span, %Span{name: "image_pipe.request", status: :error}}
  end

  test "captures an exception as :error with a folded exception event" do
    assert_raise RuntimeError, fn ->
      Telemetry.span([], [:request], %{}, fn -> raise "boom" end)
    end

    assert_receive {:span, %Span{name: "image_pipe.request", status: :error} = s}
    assert Enum.any?(s.events, &(&1.name == "exception"))
  end
end
```

- [ ] **Step 4: Run it, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs`
Expected: FAIL — `attach_tracer/1 undefined` / `Capture undefined`. (Task 6 Step 5 adds `Capture`; the `attach_tracer` glue minimal form is added here too so the test can run; the full validated version lands in Phase 3 Task 12 — keep them consistent.)

- [ ] **Step 5: Implement `Trace.Capture`**

```elixir
# lib/image_pipe/telemetry/trace/capture.ex
defmodule ImagePipe.Telemetry.Trace.Capture do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.{Id, Span, Stack}

  @handler_id {__MODULE__, :spans}

  # Span stages emitted under the image_pipe prefix.
  @span_stages [
    [:request], [:parse], [:send],
    [:source, :resolve], [:source, :fetch], [:source, :fetch_decode],
    [:output, :negotiate],
    [:transform, :execute], [:transform, :operation], [:transform, :materialize],
    [:transform, :detect], [:transform, :detect, :model],
    [:cache, :lookup], [:cache, :write], [:cache, :admission], [:cache, :warm_start]
  ]

  # One-shot (terminal) events — folded as annotations onto the current span.
  @oneshot_stages [
    [:cache, :stage], [:cache, :eviction, :stop], [:cache, :flush, :stop],
    [:cache, :cleanup, :stop], [:output, :clamp],
    [:transform, :detect, :skipped], [:transform, :detect, :blend],
    [:http_cache, :prepare], [:http_cache, :conditional, :match],
    [:http_cache, :fallback, :no_store], [:http_cache, :cache_hit, :headers]
  ]

  # Keys safe to copy into span attributes (allowlist; everything else dropped).
  @safe_keys [
    :operation, :index, :operation_count, :operations, :result, :cache,
    :output_mode, :source_kind, :source_adapter_kind, :detector, :model,
    :classes, :regions, :scale, :width, :height, :format, :params
  ]

  @spec attach(map()) :: :ok
  def attach(%{prefix: prefix, exporter: exporter} = config) do
    events =
      (for stage <- @span_stages, suffix <- [:start, :stop, :exception], do: prefix ++ stage ++ [suffix]) ++
        (for stage <- @oneshot_stages, do: prefix ++ stage)

    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      events,
      &__MODULE__.handle_event/4,
      Map.put(config, :plen, length(prefix))
    )
  end

  @spec detach() :: :ok
  def detach, do: (_ = :telemetry.detach(@handler_id); :ok)

  def handle_event(event, measurements, meta, config) do
    case classify(event, config.plen) do
      {:start, name} -> on_start(name, meta, config)
      {:stop, _name} -> on_stop(measurements, meta, config)
      {:exception, _name} -> on_exception(measurements, meta, config)
      {:oneshot, name} -> on_oneshot(name, meta)
    end
  rescue
    # A tracer must never crash the request path; drop the event on any internal error.
    _ -> :ok
  end

  # ---- classification --------------------------------------------------------

  defp classify(event, plen) do
    stage = Enum.drop(event, plen)

    # CRITICAL: one-shots whose last atom is :stop (e.g. [:cache, :flush, :stop],
    # [:cache, :eviction, :stop], [:cache, :cleanup, :stop]) are terminal events, NOT
    # span stops. Check membership in @oneshot_stages BEFORE the suffix dispatch, or
    # they would wrongly pop and export an unrelated span.
    if stage in @oneshot_stages do
      {:oneshot, name(stage)}
    else
      case List.last(stage) do
        :start -> {:start, name(stage_without_suffix(stage))}
        :stop -> {:stop, name(stage_without_suffix(stage))}
        :exception -> {:exception, name(stage_without_suffix(stage))}
        _ -> {:oneshot, name(stage)}
      end
    end
  end

  defp stage_without_suffix(stage), do: Enum.drop(stage, -1)

  defp name(stage), do: "image_pipe." <> Enum.map_join(stage, ".", &Atom.to_string/1)

  # ---- handlers --------------------------------------------------------------

  defp on_start(name, meta, config) do
    {trace_id, parent_id, flags} =
      case Stack.current() do
        nil -> root_ids(config)
        %Span{trace_id: t, span_id: s} -> {t, s, nil}
      end

    Stack.push(%Span{
      trace_id: trace_id,
      span_id: Id.span_id(),
      parent_span_id: parent_id,
      name: name,
      kind: :internal,
      start_time: meta[:system_time],
      attributes: safe_attrs(meta) |> maybe_flags(flags),
      pid: self(),
      node: node()
    })
  end

  defp on_stop(measurements, meta, %{exporter: exporter}) do
    case Stack.pop() do
      nil -> :ok
      span -> span |> finalize(measurements, status_from(meta)) |> export(exporter)
    end
  end

  defp on_exception(measurements, meta, %{exporter: exporter}) do
    case Stack.pop() do
      nil ->
        :ok

      span ->
        span
        |> Map.update!(:events, &[exception_event(meta) | &1])
        |> finalize(measurements, :error)
        |> Map.put(:status_message, exception_message(meta))
        |> export(exporter)
    end
  end

  defp on_oneshot(name, meta) do
    case Stack.current() do
      nil ->
        :ok

      span ->
        event = %{name: name, time: meta[:monotonic_time], attributes: safe_attrs(meta)}
        Stack.pop()
        Stack.push(%{span | events: [event | span.events]})
    end
  end

  # ---- helpers ---------------------------------------------------------------

  # Inbound root context is read here in Phase 2 (Trace.Inbound.take/0); for now mint.
  defp root_ids(_config), do: {Id.trace_id(), nil, 1}

  defp finalize(span, measurements, status) do
    %{
      span
      | duration_native: measurements[:duration],
        end_time: end_time(span.start_time, measurements),
        status: status
    }
  end

  # start_time is native system_time (wall-clock); duration is a native monotonic
  # delta. Both native → the sum is a valid native end_time. Exporters convert to
  # ms/µs as needed; we keep native here (and duration_native) as the source of truth.
  defp end_time(nil, _), do: nil
  defp end_time(start, %{duration: d}) when is_integer(d), do: start + d
  defp end_time(start, _), do: start

  defp status_from(meta) do
    case meta[:result] do
      :ok -> :ok
      nil -> :ok
      _other -> :error
    end
  end

  defp exception_event(meta) do
    %{name: "exception", attributes: %{kind: meta[:kind], reason: inspect(meta[:reason])}}
  end

  defp exception_message(meta), do: inspect(meta[:reason])

  defp safe_attrs(meta) do
    meta
    |> Map.take(@safe_keys)
    |> Map.new(fn {k, v} -> {k, v} end)
  end

  defp maybe_flags(attrs, nil), do: attrs
  defp maybe_flags(attrs, flags), do: Map.put(attrs, :trace_flags, flags)

  defp export(span, exporter), do: exporter.export(span)
end
```

- [ ] **Step 6: Add the `Trace` facade + minimal `attach_tracer`/`detach_tracer` glue**

Create the facade now (it gains `maybe_extract_inbound/1` in Phase 2 Task 12 and is the boundary-exported public entry); it owns the active-exporter persistent_term that `ReqStep`/`FinchCapture` read later:

```elixir
# lib/image_pipe/telemetry/trace.ex
defmodule ImagePipe.Telemetry.Trace do
  @moduledoc "Public facade for the opt-in span tracer."

  @exporter_key {__MODULE__, :exporter}

  @doc false
  def set_exporter(mod), do: :persistent_term.put(@exporter_key, mod)

  @doc "The active exporter module, or nil when no tracer is attached."
  def exporter, do: :persistent_term.get(@exporter_key, nil)
end
```

Add to `lib/image_pipe/telemetry.ex` (full validation lands in Phase 3 Task 17; this minimal form must stay signature-compatible and **must set the active exporter** so later HTTP steps resolve it):

```elixir
  @doc "Attach the opt-in span tracer. See `ImagePipe.Telemetry.Trace`."
  @spec attach_tracer(keyword()) :: :ok
  def attach_tracer(opts) do
    exporter = Keyword.fetch!(opts, :exporter)
    prefix = Keyword.get(opts, :prefix, default_prefix())

    ImagePipe.Telemetry.Trace.set_exporter(exporter)
    ImagePipe.Telemetry.Trace.Capture.attach(%{prefix: prefix, exporter: exporter})
  end

  @spec detach_tracer() :: :ok
  def detach_tracer do
    ImagePipe.Telemetry.Trace.Capture.detach()
    ImagePipe.Telemetry.Trace.set_exporter(nil)
    :ok
  end
```

- [ ] **Step 7: Run the capture test, verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs`
Expected: PASS (all three tests).

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/telemetry/trace/exporter.ex lib/image_pipe/telemetry/trace/capture.ex \
        lib/image_pipe/telemetry.ex test/support/trace_test_exporter.ex \
        test/image_pipe/telemetry/trace/capture_test.exs
git commit -m "feat(telemetry): Trace.Capture nesting reconstruction + Exporter behaviour"
```

## Task 7: Attribute safety — drop URLs/paths/secrets, store structs opaque

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/capture.ex` (already allowlist-based; add the regression test and confirm uniform application)
- Test: `test/image_pipe/telemetry/trace/attr_safety_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/attr_safety_test.exs
defmodule ImagePipe.Telemetry.Trace.AttrSafetyTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "a signed source URL in metadata never reaches span attributes" do
    signed = "https://cdn.example.com/img.jpg?sig=SECRET123&exp=999"

    Telemetry.span([], [:source, :fetch], %{source_url: signed, source_path: "/img.jpg?sig=SECRET123", source_kind: :http}, fn ->
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.source.fetch"} = span}
    flat = inspect(span.attributes)
    refute flat =~ "SECRET123"
    refute flat =~ "cdn.example.com"
    # product-neutral key is allowed through
    assert span.attributes[:source_kind] == :http
  end

  property "no secret-bearing key ever reaches attributes, for any value" do
    check all secret <- StreamData.string(:alphanumeric, min_length: 1),
              key <- StreamData.member_of([:source_url, :source_path, :signature, :token, :authorization]) do
      Telemetry.span([], [:source, :fetch], %{key => secret, :source_kind => :http}, fn -> {:ok, %{result: :ok}} end)
      assert_receive {:span, %Span{name: "image_pipe.source.fetch"} = span}
      refute inspect(span.attributes) =~ secret
    end
  end
end
```

Add `use ExUnitProperties` to the test module for the `property`/`check all` macros.

- [ ] **Step 2: Run it, verify it fails or passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/attr_safety_test.exs`
Expected: PASS already (allowlist drops `:source_url`/`:source_path` since they are not in `@safe_keys`). If it FAILS, a non-allowlisted key leaked — fix `safe_attrs/1`. The test exists to lock the guarantee against future `@safe_keys` edits.

- [ ] **Step 3: Add a module doc note pinning the contract**

In `capture.ex`, above `@safe_keys`, add:

```elixir
  # SENSITIVITY: allowlist only. Never add :source_url, :source_path, request paths,
  # signatures, tokens, or any secret-bearing key. Operation structs (:params) are
  # stored opaque (inspected by exporters) and MUST NOT be pattern-matched against
  # ImagePipe.Transform.Operation.* here — that would invert the telemetry boundary.
```

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/telemetry/trace/capture.ex test/image_pipe/telemetry/trace/attr_safety_test.exs
git commit -m "test(telemetry): lock attribute allowlist against URL/secret leakage"
```

## Task 8: `[:transform, :materialize]` barrier span

**Files:**
- Modify: `lib/image_pipe/transform/materializer.ex` (wrap the flush in a span using `state.telemetry_opts`)
- Test: `test/image_pipe/telemetry/trace/materialize_span_test.exs`

First **read** `lib/image_pipe/transform/materializer.ex`, `lib/image_pipe/transform/state.ex` (confirm `telemetry_opts` field), and `lib/image_pipe/transform/orientation_flush.ex` to see the exact `materialize/1` body and return contract before editing.

- [ ] **Step 1: Write the failing wire-level test (three nesting cases)**

```elixir
# test/image_pipe/telemetry/trace/materialize_span_test.exs
defmodule ImagePipe.Telemetry.Trace.MaterializeSpanTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  # NOTE: replace `build_opts/0` and the request paths with the project's
  # established imgproxy wire-test fixtures (see test/image_pipe/imgproxy_wire_conformance_test.exs).
  # The materializing request must trigger a right-angle rotate / vertical flip / smart-crop;
  # the negative request must be resize-only on an orientation-1 source.

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  defp collect_spans(timeout \\ 200) do
    receive do
      {:span, %Span{} = s} -> [s | collect_spans(timeout)]
    after
      timeout -> []
    end
  end

  test "mid-chain materializing op yields a materialize span nested under an operation" do
    conn = conn(:get, materializing_request_path()) |> ImagePipe.call(build_opts())
    assert conn.status == 200

    spans = collect_spans()
    mat = Enum.find(spans, &(&1.name == "image_pipe.transform.materialize"))
    op = Enum.find(spans, &(&1.name == "image_pipe.transform.operation"))

    assert mat, "expected a materialize span"
    assert is_integer(mat.duration_native) and mat.duration_native >= 0
    assert mat.parent_span_id == op.span_id
  end

  test "delivery-only EXIF-3-8 flush yields a materialize span under the request root" do
    # No-geometry request on an orientation-6 source: the only flush is the delivery
    # backstop (materialize_for_delivery/2), AFTER [:transform, :execute] closes — so
    # the span parents to the request root, not an operation span. (Spec §7/§12.)
    conn = conn(:get, exif_oriented_no_geometry_path()) |> ImagePipe.call(exif_oriented_opts())
    assert conn.status == 200

    spans = collect_spans()
    mat = Enum.find(spans, &(&1.name == "image_pipe.transform.materialize"))
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))

    assert mat && root
    assert mat.parent_span_id == root.span_id
  end

  test "pure-lazy orientation-1 request yields no materialize span" do
    conn = conn(:get, resize_only_orientation1_path()) |> ImagePipe.call(build_opts())
    assert conn.status == 200

    spans = collect_spans()
    refute Enum.any?(spans, &(&1.name == "image_pipe.transform.materialize"))
  end

  # Fixtures — fill from test/image_pipe/imgproxy_wire_conformance_test.exs (these
  # helpers EXIST there; this is wiring, not logic):
  #   build_opts / exif_oriented_opts  -> @default_opts / sharp_oriented_opts(6)
  #   materializing_request_path       -> a g:sm smart-crop or rt:force rotate URL
  #   exif_oriented_no_geometry_path   -> a /_/plain/... no-geometry URL on SharpOrientedOrigin (orientation 6)
  #   resize_only_orientation1_path    -> a resize-only URL on an orientation-1 source
  defp build_opts, do: raise("TODO: @default_opts from the wire test")
  defp exif_oriented_opts, do: raise("TODO: sharp_oriented_opts(6) from the wire test")
  defp materializing_request_path, do: raise("TODO: g:sm or rt:force request path")
  defp exif_oriented_no_geometry_path, do: raise("TODO: no-geometry path on orientation-6 source")
  defp resize_only_orientation1_path, do: raise("TODO: resize-only orientation-1 path")
end
```

> Implementer note: the `raise("TODO …")` helpers are wiring placeholders for real fixtures that already exist in `test/image_pipe/imgproxy_wire_conformance_test.exs` (`@default_opts`, `sharp_oriented_opts/1`, `SharpOrientedOrigin`, `g:sm`/`rt:force` URLs). Lift them into a shared `test/support` helper if convenient. The test is not done until all resolve to real requests.

- [ ] **Step 2: Run it, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/materialize_span_test.exs`
Expected: FAIL — no `image_pipe.transform.materialize` span emitted yet.

- [ ] **Step 3: Wrap the flush in a span**

In `lib/image_pipe/transform/materializer.ex`, wrap the existing flush body. **Read the real file first** — there are TWO arities: `materialize/1` (used by `chain.ex`) and the `@callback materialize/2` delivery-backstop (used by `processor.ex`), and the arity-2 currently delegates to arity-1. Wrap the **shared inner body once** so a single span covers both entry points (do not wrap each arity independently — that would double-emit).

```elixir
  alias ImagePipe.Telemetry

  # Arity-1 (chain) and arity-2 (delivery backstop) both route through here.
  def materialize(%ImagePipe.Transform.State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case do_materialize(state) do
        {:ok, new_state} -> {{:ok, new_state}, %{result: :ok}}
        {:error, reason} -> {{:error, reason}, %{result: :materialize_error}}
      end
    end)
  end

  # Keep arity-2 delegating to the wrapped arity-1 (it currently ignores opts) — do
  # not add a second span here.
  def materialize(state, _opts), do: materialize(state)

  # do_materialize/1 is the EXISTING arity-1 body, renamed — OrientationFlush.flush.
  # Do not change its behavior.
  defp do_materialize(state), do: ImagePipe.Transform.OrientationFlush.flush(state)
```

**Return contract (corrected):** `materialize/1` returns a **bare** `{:ok, state} | {:error, reason}` — `OrientationFlush.flush/1` does NOT wrap `:materialize_error`; the `{:materialize_error, reason}` wrapping is done by the **callers** (`chain.ex:82`, `plan_executor.ex:133`). The wrapper above preserves the bare return (`{:error, reason}` passes through unchanged) and only tags the *span's* stop metadata `result: :materialize_error`. **Do NOT** return `{:error, {:materialize_error, reason}}` from the Materializer — that would double-wrap at the callers. A raise inside `do_materialize` surfaces as a `[:transform, :materialize, :exception]` event (telemetry re-raises); a tagged `{:error, _}` surfaces as a `:stop` carrying `result: :materialize_error`.

- [ ] **Step 4: Run materialize + full transform suites, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/materialize_span_test.exs test/image_pipe/transform`
Expected: PASS, and no transform regressions.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/materializer.ex test/image_pipe/telemetry/trace/materialize_span_test.exs
git commit -m "feat(transform): [:transform, :materialize] barrier span for honest flush timing"
```

## Task 9: Logger sync for the materialize event (all four points)

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Test: `test/image_pipe/telemetry/logger_test.exs` (extend)

First **read** `logger.ex:12-19` (`@group_span_events`), `logger.ex:106-125` (`level_for/3`), `logger.ex:175-186` (generic `message/3` + `outcome/1`), and the existing detect/clamp assertions in `logger_test.exs`.

- [ ] **Step 1: Write failing logger tests**

```elixir
# add to test/image_pipe/telemetry/logger_test.exs
  describe "materialize event" do
    setup do
      :ok = ImagePipe.Telemetry.Logger.attach(level: :info)
      on_exit(fn -> ImagePipe.Telemetry.Logger.detach() end)
      :ok
    end

    test "successful flush logs at base level, no warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute([:image_pipe, :transform, :materialize, :stop], %{duration: 10}, %{result: :ok})
        end)

      assert log =~ "materialize"
      refute log =~ "[warning]"
    end

    test "stop carrying materialize_error escalates to warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute([:image_pipe, :transform, :materialize, :stop], %{duration: 10}, %{result: :materialize_error})
        end)

      assert log =~ "[warning]"
    end

    test "exception escalates to warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :telemetry.execute(
            [:image_pipe, :transform, :materialize, :exception],
            %{duration: 5},
            %{kind: :error, reason: %RuntimeError{message: "x"}, stacktrace: []}
          )
        end)

      assert log =~ "[warning]"
    end
  end
```

(Match the project's actual `Logger.attach/detach` test setup — copy the existing describe-block setup verbatim if it differs.)

- [ ] **Step 2: Run, verify the stop-error test fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: the success + exception tests pass (exception auto-escalates via the generic `:exception` arm at `logger.ex:111`); the **stop-error** test FAILS (materialize_error logs at base level).

- [ ] **Step 3: Implement the three sync points**

In `logger.ex`:

1. **Subscription** — add `[:transform, :materialize]` to the `transform` list in `@group_span_events` (`logger.ex:16`).
2. **Levels** — escalate a materialize stop-error. **Read `logger.ex:106-115` first**: the generic `level_for/3` is a `cond` (the `[:output, :clamp]`-style heads come before it). Add a branch **inside that `cond`**, beside the existing `:cache_error` branch (~`logger.ex:111`) — do NOT add a new wildcard function head (it would swallow clamp/exception cases):

```elixir
      # inside the existing cond in level_for/3, next to the :cache_error branch:
      metadata[:result] == :materialize_error -> :warning
```

The materialize `:exception` path needs no new code — the generic `:exception` arm (`logger.ex:111`-ish, `List.last(suffix) == :exception -> :warning`) already escalates it. Confirm this by reading the clause; the test in Step 1 asserts it.

3. **Rendering** — none; the generic `message/3` fallback (`logger.ex:175`) prints `label` + `outcome/1`. Confirm no specific clause is added.

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(telemetry): Logger subscribe + escalate [:transform, :materialize]"
```

## Task 10: `telemetry.md` — materialize subsection (Phase 1 doc sync)

**Files:**
- Modify: `docs/telemetry.md`

- [ ] **Step 1: Add the subsection**

Add `### Materialization barrier span (`[:transform, :materialize]`)` near the per-operation-spans section. Document: emitted from `Materializer.materialize/1`; `:stop` metadata `result: :ok | :materialize_error`; duration is the real flush cost (the honest per-barrier timing the per-op spans deliberately lack); parenting nuance (mid-chain under `[:transform, :operation]`, boundary flush under `[:transform, :execute]`, delivery flush under the request root). Update the result-atoms list to include `:materialize_error`.

- [ ] **Step 2: Verify prose builds / no broken references**

Run: `mise exec -- mix docs` (if configured) or visually confirm Markdown.

- [ ] **Step 3: Commit**

```bash
git add docs/telemetry.md
git commit -m "docs(telemetry): document [:transform, :materialize] barrier span"
```

## Phase 1 gate

- [ ] Run the full gate: `mise run precommit`
- [ ] Expected: format clean, `--warnings-as-errors` clean, credo strict clean, all tests pass.

---

# Phase 2 — Cross-process propagation + inbound edge

Threads `Trace.Context` across hop A (request→SourceSession, for `[:cache, :write]`) and hop B (SourceSession→Producer, for the bulk), keeps Admission spans as separate roots (§8.1), and adds opt-in inbound `traceparent` extraction. Depends on Phase 1.

## Task 11: Inbound context plumbing (`Trace.Inbound`) wired into Capture root

**Files:**
- Create: `lib/image_pipe/telemetry/trace/inbound.ex`
- Modify: `lib/image_pipe/telemetry/trace/capture.ex` (`root_ids/1` reads inbound)
- Test: `test/image_pipe/telemetry/trace/inbound_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/inbound_test.exs
defmodule ImagePipe.Telemetry.Trace.InboundTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Context, Inbound, Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "root span adopts an inbound context when present" do
    Inbound.put(%Context{trace_id: "0af7651916cd43dd8448eb211c80319c", span_id: "b7ad6b7169203331", trace_flags: 1})
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == "0af7651916cd43dd8448eb211c80319c"
    assert root.parent_span_id == "b7ad6b7169203331"
  end

  test "root mints fresh when no inbound context" do
    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id =~ ~r/\A[0-9a-f]{32}\z/
    assert root.parent_span_id == nil
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/inbound_test.exs`
Expected: FAIL — `Inbound` undefined.

- [ ] **Step 3: Implement `Trace.Inbound` + wire `root_ids/1`**

```elixir
# lib/image_pipe/telemetry/trace/inbound.ex
defmodule ImagePipe.Telemetry.Trace.Inbound do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Context

  @key :"$image_pipe_trace_inbound"

  @spec put(Context.t()) :: :ok
  def put(%Context{} = ctx), do: (Process.put(@key, ctx); :ok)

  @doc "Read and clear the inbound context (consumed once by the root span)."
  @spec take() :: Context.t() | nil
  def take, do: Process.delete(@key)
end
```

Update `capture.ex` `root_ids/1`:

```elixir
  defp root_ids(_config) do
    case ImagePipe.Telemetry.Trace.Inbound.take() do
      %ImagePipe.Telemetry.Trace.Context{trace_id: t, span_id: s, trace_flags: f} -> {t, s, f}
      nil -> {Id.trace_id(), nil, 1}
    end
  end
```

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/inbound_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/inbound.ex lib/image_pipe/telemetry/trace/capture.ex \
        test/image_pipe/telemetry/trace/inbound_test.exs
git commit -m "feat(telemetry): inbound trace context adopted by the root span"
```

## Task 12: Plug edge — extract `traceparent` when `extract_inbound: true`

**Files:**
- Modify: `lib/image_pipe/plug.ex` (before the `[:request]` span at `plug.ex:43`)
- Modify: `lib/image_pipe/telemetry.ex` (`attach_tracer` records `extract_inbound`; expose it to the plug via the request opts or application env — see Step 3)
- Test: `test/image_pipe/telemetry/trace/inbound_plug_test.exs`

First **read** `plug.ex:40-115` to see how `opts`/`telemetry_opts` flow and where request options live.

- [ ] **Step 1: Write the failing wire test**

```elixir
# test/image_pipe/telemetry/trace/inbound_plug_test.exs
defmodule ImagePipe.Telemetry.Trace.InboundPlugTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  @tp "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

  setup do
    TestExporter.set_receiver(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "adopts inbound traceparent when extract_inbound: true" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn(:get, valid_request_path()) |> put_req_header("traceparent", @tp) |> ImagePipe.call(build_opts())

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id == "0af7651916cd43dd8448eb211c80319c"
  end

  test "ignores traceparent by default (opt-in)" do
    :ok = TestExporter.attach(self())
    conn(:get, valid_request_path()) |> put_req_header("traceparent", @tp) |> ImagePipe.call(build_opts())

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id != "0af7651916cd43dd8448eb211c80319c"
  end

  test "malformed traceparent falls back to a fresh root" do
    :ok = TestExporter.attach(self(), extract_inbound: true)
    conn(:get, valid_request_path()) |> put_req_header("traceparent", "garbage") |> ImagePipe.call(build_opts())

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.trace_id =~ ~r/\A[0-9a-f]{32}\z/
  end

  defp build_opts, do: raise("TODO: project ImagePipe.call/2 opts")
  defp valid_request_path, do: raise("TODO: a 200-status request path")
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/inbound_plug_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement extraction in the plug**

The plug must know whether extraction is enabled. Simplest: `attach_tracer` stores `extract_inbound` in `:persistent_term` keyed `{ImagePipe.Telemetry.Trace, :extract_inbound}`; `plug.call` reads it. In `plug.ex`, before the `[:request]` span:

```elixir
  def call(%Plug.Conn{} = conn, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    ImagePipe.Telemetry.Trace.maybe_extract_inbound(conn)

    Telemetry.span(telemetry_opts, [:request], request_metadata(conn, opts), fn ->
      {conn, metadata} = do_call(conn, opts)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end
```

Extend the existing facade `lib/image_pipe/telemetry/trace.ex` (created in Task 6) with `maybe_extract_inbound/1` + the `extract_inbound` flag:

```elixir
  alias ImagePipe.Telemetry.Trace.{Inbound, W3C}

  @extract_key {__MODULE__, :extract_inbound}

  @doc false
  def set_extract_inbound(flag), do: :persistent_term.put(@extract_key, flag == true)

  @doc false
  def maybe_extract_inbound(conn) do
    if :persistent_term.get(@extract_key, false) do
      case Plug.Conn.get_req_header(conn, "traceparent") do
        [tp | _] ->
          case W3C.decode(tp) do
            {:ok, ctx} -> Inbound.put(ctx)
            :error -> :ok
          end

        [] ->
          :ok
      end
    end

    :ok
  end
```

Wire the flag into the (still-minimal) `attach_tracer` in `lib/image_pipe/telemetry.ex` now — add `ImagePipe.Telemetry.Trace.set_extract_inbound(Keyword.get(opts, :extract_inbound, false))` to its body, and `ImagePipe.Telemetry.Trace.set_extract_inbound(false)` to `detach_tracer`. (Task 17 replaces this with the validated version that keeps the same wiring.) Without this, the minimal `attach_tracer` ignores `extract_inbound: true` and this task's test fails.

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/inbound_plug_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug.ex lib/image_pipe/telemetry.ex lib/image_pipe/telemetry/trace.ex \
        test/image_pipe/telemetry/trace/inbound_plug_test.exs
git commit -m "feat(telemetry): opt-in inbound traceparent extraction at the plug edge"
```

## Task 13: Hop B — request context → Producer

**Files:**
- Modify: `lib/image_pipe/request/runner.ex` (capture `Trace.Stack.context()` at `start_session`)
- Modify: `lib/image_pipe/request/source_session_supervisor.ex` (pass context through `start_child` opts)
- Modify: `lib/image_pipe/request/source_session.ex` (stash + forward to `Producer.start_link`)
- Modify: `lib/image_pipe/request/source_session/producer.ex` (`Trace.Stack.adopt/1` in the spawn)
- Test: `test/image_pipe/telemetry/trace/cross_process_test.exs`

First **read** `runner.ex:30-40,128-160`, `source_session_supervisor.ex:31-37`, `source_session.ex:80-90,244-250`, `producer.ex:26-36`.

- [ ] **Step 1: Write the failing cross-process test**

```elixir
# test/image_pipe/telemetry/trace/cross_process_test.exs
defmodule ImagePipe.Telemetry.Trace.CrossProcessTest do
  use ExUnit.Case, async: false
  import Plug.Test
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  defp collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  test "producer-process spans share the request trace_id and parent under it" do
    conn(:get, valid_request_path()) |> ImagePipe.call(build_opts())

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    fetch = Enum.find(spans, &(&1.name == "image_pipe.source.fetch_decode"))

    assert root && fetch
    assert fetch.trace_id == root.trace_id
    refute fetch.parent_span_id == nil
  end

  defp build_opts, do: raise("TODO: project ImagePipe.call/2 opts (cache miss, decodes a real image)")
  defp valid_request_path, do: raise("TODO: a request that fetches+decodes a source")
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/cross_process_test.exs`
Expected: FAIL — `fetch.trace_id != root.trace_id` (producer orphans without threading).

- [ ] **Step 3: Thread the context (data, not process-local)**

1. In `runner.ex` at the `start_session` call: capture `ctx = ImagePipe.Telemetry.Trace.Stack.context()` and pass it as an option/field alongside `owner`.
2. In `source_session_supervisor.ex` `start_session/…`: forward the `trace_context` into the child spec args (the same path `owner` travels at `:35`).
3. In `source_session.ex` `init/1` (~`:84`): stash `trace_context` in state; in `start_producer/1` (~`:244`) pass `trace_context: state.trace_context` to `Producer.start_link`.
4. In `producer.ex` `start_link/2` spawn body (~`:31`), beside `Process.put(:"$callers", caller_chain)`:

```elixir
      Process.put(:"$callers", caller_chain)
      ImagePipe.Telemetry.Trace.Stack.adopt(trace_context)
```

(`trace_context` read from opts: `trace_context = Keyword.get(opts, :trace_context)`.)

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/cross_process_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/request/source_session_supervisor.ex \
        lib/image_pipe/request/source_session.ex lib/image_pipe/request/source_session/producer.ex \
        test/image_pipe/telemetry/trace/cross_process_test.exs
git commit -m "feat(telemetry): thread trace context request->producer (hop B)"
```

## Task 14: Hop A — request context → SourceSession for `[:cache, :write]`

**Files:**
- Modify: `lib/image_pipe/request/source_session.ex` (`Trace.Stack.adopt/1` in `init/1`, beside the `$callers` put at `:84`)
- Test: extend `test/image_pipe/telemetry/trace/cross_process_test.exs`

- [ ] **Step 1: Add the failing assertion**

Add to `cross_process_test.exs`:

```elixir
  test "cache write parents under the request (hop A)" do
    conn(:get, cache_miss_request_path()) |> ImagePipe.call(build_opts())

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    write = Enum.find(spans, &(&1.name == "image_pipe.cache.write"))

    assert root && write, "expected request + cache.write spans"
    assert write.trace_id == root.trace_id
  end

  test "cache admission is a separate root, not under the request (§8.1)" do
    conn(:get, cache_miss_request_path()) |> ImagePipe.call(build_opts())

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    admission = Enum.find(spans, &(&1.name == "image_pipe.cache.admission"))

    # Admission runs in the shared Admission GenServer with no request context
    # threaded (spec §8.1): it must NOT share the request trace.
    if admission do
      assert admission.parent_span_id == nil
      assert admission.trace_id != root.trace_id
    end
  end

  defp cache_miss_request_path, do: raise("TODO: request path that writes to cache on miss")
```

- [ ] **Step 2: Run, verify the new test fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/cross_process_test.exs`
Expected: the cache-write test FAILS (`[:cache, :write]` emitted from SourceSession with an empty stack → different trace_id).

- [ ] **Step 3: Adopt the context in SourceSession.init**

The context already travels to SourceSession for hop B (Task 13). In `init/1` (~`source_session.ex:84`), beside the `$callers` put:

```elixir
    Process.put(:"$callers", [owner | Process.get(:"$callers", [])])
    ImagePipe.Telemetry.Trace.Stack.adopt(state.trace_context)
```

(Read `trace_context` from the init args/state as threaded in Task 13.)

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/cross_process_test.exs`
Expected: PASS (both producer and cache-write assertions).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/source_session.ex test/image_pipe/telemetry/trace/cross_process_test.exs
git commit -m "feat(telemetry): thread trace context request->SourceSession for cache.write (hop A)"
```

## Phase 2 gate

- [ ] `mise run precommit` — all green.

---

# Phase 3 — Outbound HTTP + public glue + docs

Adds logical + physical Finch client spans, the validated public `attach_tracer/1`, the `LogExporter`, and the boundary/architecture enforcement + remaining docs. Depends on Phases 1–2.

## Task 15: `Trace.ReqStep` — logical client span + traceparent inject + finch_private stamp

**Files:**
- Create: `lib/image_pipe/telemetry/trace/req_step.ex`
- Modify: the source Req-client build site (find via `grep -rl "Req.new\|Req.Request" lib/image_pipe/source`)
- Test: `test/image_pipe/telemetry/trace/req_step_test.exs`

First **read** the source Req-client construction to see where to attach steps and how `source` already uses Req.

- [ ] **Step 1: Write the failing test (a logical client span is emitted with status)**

```elixir
# test/image_pipe/telemetry/trace/req_step_test.exs
defmodule ImagePipe.Telemetry.Trace.ReqStepTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{ReqStep, Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "injects traceparent and emits a logical client span with status" do
    # Open a parent span so the client span has a trace to attach to.
    Telemetry.span([], [:request], %{}, fn ->
      req =
        Req.new(adapter: fn req ->
          assert [tp] = Req.Request.get_header(req, "traceparent")
          assert tp =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/
          {req, Req.Response.new(status: 200, body: "ok")}
        end)
        |> ReqStep.attach()

      {:ok, _} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.attributes[:"http.status_code"] == 200
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/req_step_test.exs`
Expected: FAIL — `ReqStep` undefined.

- [ ] **Step 3: Implement `Trace.ReqStep`**

```elixir
# lib/image_pipe/telemetry/trace/req_step.ex
defmodule ImagePipe.Telemetry.Trace.ReqStep do
  @moduledoc """
  Req steps that trace an outbound HTTP call as a logical client span, inject a W3C
  `traceparent` header, and stamp `finch_private` so `Trace.FinchCapture` can attach
  wire spans. Apply where the source builds its Req client.
  """
  alias ImagePipe.Telemetry.Trace.{Id, Span, Stack, W3C}

  @priv :image_pipe_trace

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = req) do
    req
    |> Req.Request.append_request_steps(image_pipe_trace_start: &start/1)
    |> Req.Request.prepend_response_steps(image_pipe_trace_stop: &stop/1)
    |> Req.Request.append_error_steps(image_pipe_trace_error: &error/1)
  end

  defp start(req) do
    span_id = Id.span_id()
    {trace_id, flags} =
      case Stack.context() do
        %{trace_id: t, trace_flags: f} -> {t, f || 1}
        _ -> {Id.trace_id(), 1}
      end

    req
    |> Req.Request.put_header("traceparent", W3C.encode(trace_id, span_id, flags))
    |> Req.Request.put_private(@priv, {trace_id, span_id, System.system_time(), Stack.context()})
    |> Req.merge(finch_private: %{@priv => {trace_id, span_id}})
  end

  defp stop({req, %Req.Response{status: status} = resp}) do
    emit(req, %{"http.status_code" => status}, :ok)
    {req, resp}
  end

  defp error({req, exception}) do
    emit(req, %{"http.error" => inspect(exception)}, :error)
    {req, exception}
  end

  defp emit(req, attrs, status) do
    case Req.Request.get_private(req, @priv) do
      {trace_id, span_id, start_time, parent_ctx} ->
        exporter().export(%Span{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: parent_ctx && parent_ctx.span_id,
          name: "image_pipe.http.client",
          kind: :client,
          start_time: start_time,
          end_time: System.system_time(),
          status: status,
          attributes: attrs,
          pid: self(),
          node: node()
        })

      _ ->
        :ok
    end
  end

  defp exporter, do: ImagePipe.Telemetry.Trace.exporter() || NoopExporter
end
```

Add `ImagePipe.Telemetry.Trace.exporter/0` returning the active exporter module (store it in `:persistent_term` in `attach_tracer`); `ReqStep` uses it directly because the response/error steps may run in a process boundary where the active span stack differs. Define a private `NoopExporter` or guard `nil` to skip emission when no tracer is attached.

- [ ] **Step 4: Attach `ReqStep` at the source Req-client build site (NON-TRIVIAL — read first)**

`lib/image_pipe/source/req_stream.ex` currently calls `Req.get(keyword_opts, …)` — it never builds a `%Req.Request{}` struct, so there is nothing to pipe through `attach/1`. You must restructure the call to build a request, attach the steps, then run it:

```elixir
# before (conceptually): Req.get(request_options(req_options), url: url, into: :self)
# after:
Req.new(request_options(req_options))
|> ImagePipe.Telemetry.Trace.ReqStep.attach()
|> Req.request(url: url, into: :self)
```

This touches the redirect-follow loop (`follow/5` / `request_and_route/6` in `req_stream.ex`). Keep the existing redirect/timeout/limit options intact; only the build-and-run shape changes. Gate cheaply: `ReqStep.attach/1` is a no-op-at-runtime when `ImagePipe.Telemetry.Trace.exporter()` is nil (the steps emit nothing), so it's safe to always attach.

**Timing caveat (document in the `ReqStep` `@moduledoc`):** `req_stream.ex` uses `into: :self`, so the response step (and the logical client span `:stop`) fires when **status + headers** arrive, not when the body finishes downloading. The span duration covers connect + TTFB, not full transfer. Status is captured correctly.

- [ ] **Step 5: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/req_step_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/trace/req_step.ex lib/image_pipe/source/ test/image_pipe/telemetry/trace/req_step_test.exs
git commit -m "feat(telemetry): Trace.ReqStep logical client span + traceparent injection"
```

## Task 16: `Trace.FinchCapture` — physical wire spans via finch_private

**Files:**
- Create: `lib/image_pipe/telemetry/trace/finch_capture.ex`
- Modify: `lib/image_pipe/telemetry.ex` (`attach_tracer` attaches FinchCapture when `finch_spans: true`)
- Test: `test/image_pipe/telemetry/trace/finch_capture_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/telemetry/trace/finch_capture_test.exs
defmodule ImagePipe.Telemetry.Trace.FinchCaptureTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry.Trace.{FinchCapture, Span}

  test "builds a wire span parented from finch_private" do
    FinchCapture.set_exporter(fn s -> send(self(), {:span, s}) end)

    request = %{private: %{image_pipe_trace: {"trace123", "parentspan"}}}
    FinchCapture.handle_event(
      [:finch, :request, :stop],
      %{duration: 10, system_time: 1},
      %{name: TestFinch, request: request, result: {:ok, %{status: 200}}},
      %{exporter_ref: self()}
    )

    assert_receive {:span, %Span{name: "finch.request", trace_id: "trace123", parent_span_id: "parentspan"}}
  end
end
```

(Adapt to the real FinchCapture API you implement; the contract: read `meta.request.private[:image_pipe_trace]`, build a `finch.*` span parented to that span_id.)

- [ ] **Step 2: Run, verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/finch_capture_test.exs`
Expected: FAIL — `FinchCapture` undefined.

- [ ] **Step 3: Implement `Trace.FinchCapture`**

```elixir
# lib/image_pipe/telemetry/trace/finch_capture.ex
defmodule ImagePipe.Telemetry.Trace.FinchCapture do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Span

  @handler_id {__MODULE__, :finch}
  @events [
    [:finch, :request, :stop], [:finch, :request, :exception],
    [:finch, :queue, :stop], [:finch, :connect, :stop],
    [:finch, :send, :stop], [:finch, :recv, :stop], [:finch, :recv, :exception]
  ]

  def attach(%{exporter: exporter}) do
    _ = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{exporter: exporter})
  end

  def detach, do: (_ = :telemetry.detach(@handler_id); :ok)

  def handle_event([:finch | rest] = _event, measurements, meta, config) do
    with %{} = request <- Map.get(meta, :request),
         %{image_pipe_trace: {trace_id, parent_span_id}} <- Map.get(request, :private, %{}) do
      config.exporter.export(%Span{
        trace_id: trace_id,
        span_id: ImagePipe.Telemetry.Trace.Id.span_id(),
        parent_span_id: parent_span_id,
        name: "finch." <> Enum.map_join(Enum.drop(rest, -1), ".", &Atom.to_string/1),
        kind: :client,
        start_time: meta[:system_time],
        duration_native: measurements[:duration],
        status: finch_status(meta),
        attributes: finch_attrs(meta),
        pid: self(),
        node: node()
      })
    else
      _ -> :ok
    end
  end

  defp finch_status(%{result: {:error, _}}), do: :error
  defp finch_status(%{kind: _}), do: :error
  defp finch_status(_), do: :ok

  defp finch_attrs(meta), do: Map.take(meta, [:status]) |> Map.new(fn {_k, v} -> {:"http.status_code", v} end)
end
```

(The test's `set_exporter` shim: expose a test seam, or rewrite the test to call `handle_event/4` with a `%{exporter: SomeMod}` config that sends to `self()`. Keep the production path config-driven.)

In `attach_tracer`, when `finch_spans` is true, call `FinchCapture.attach(%{exporter: exporter})`; in `detach_tracer`, `FinchCapture.detach()`.

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/finch_capture_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/finch_capture.ex lib/image_pipe/telemetry.ex \
        test/image_pipe/telemetry/trace/finch_capture_test.exs
git commit -m "feat(telemetry): Trace.FinchCapture physical wire spans via finch_private"
```

## Task 17: `Trace.LogExporter` + validated `attach_tracer/1`

**Files:**
- Create: `lib/image_pipe/telemetry/trace/log_exporter.ex`
- Modify: `lib/image_pipe/telemetry.ex` (replace the minimal `attach_tracer` with a NimbleOptions-validated, raising version that wires Capture + FinchCapture + extract_inbound + exporter persistent_term)
- Test: `test/image_pipe/telemetry/trace/log_exporter_test.exs`, extend an attach validation test

- [ ] **Step 1: Write the failing tests**

```elixir
# test/image_pipe/telemetry/trace/log_exporter_test.exs
defmodule ImagePipe.Telemetry.Trace.LogExporterTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias ImagePipe.Telemetry.Trace.{LogExporter, Span}

  test "logs one flat line with ids, name, duration, status" do
    span = %Span{
      trace_id: "t", span_id: "s", parent_span_id: "p", name: "image_pipe.request",
      start_time: 0, duration_native: 1234, status: :ok
    }

    log = capture_log(fn -> LogExporter.export(span) end)
    assert log =~ "image_pipe.request"
    assert log =~ "t"
    assert log =~ "status=ok"
  end
end
```

```elixir
# add to test/image_pipe/telemetry/trace/capture_test.exs (or a new attach_test.exs)
  test "attach_tracer raises on unknown option" do
    assert_raise ArgumentError, fn ->
      ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter, bogus: 1)
    end
  end

  test "attach_tracer raises when exporter is missing or not loadable" do
    assert_raise ArgumentError, fn -> ImagePipe.Telemetry.attach_tracer([]) end
    assert_raise ArgumentError, fn -> ImagePipe.Telemetry.attach_tracer(exporter: NotARealModule) end
  end
```

- [ ] **Step 2: Run, verify they fail**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/log_exporter_test.exs test/image_pipe/telemetry/trace/capture_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement `LogExporter` + validated `attach_tracer`**

```elixir
# lib/image_pipe/telemetry/trace/log_exporter.ex
defmodule ImagePipe.Telemetry.Trace.LogExporter do
  @moduledoc "Stdlib Logger exporter: one flat structured line per span. No buffering."
  @behaviour ImagePipe.Telemetry.Trace.Exporter
  require Logger
  alias ImagePipe.Telemetry.Trace.Span

  @impl true
  def export(%Span{} = s) do
    Logger.info(fn ->
      "image_pipe.trace " <>
        "trace=#{s.trace_id} span=#{s.span_id} parent=#{s.parent_span_id || "-"} " <>
        "#{s.name} dur=#{s.duration_native || "-"} status=#{s.status || "unset"}"
    end)

    :ok
  end
end
```

```elixir
# lib/image_pipe/telemetry.ex — replace the minimal attach_tracer
  @tracer_schema NimbleOptions.new!(
    exporter: [type: :atom, required: true],
    prefix: [type: {:list, :atom}, default: ImagePipe.Telemetry.default_prefix()],
    extract_inbound: [type: :boolean, default: false],
    finch_spans: [type: :boolean, default: true]
  )

  @spec attach_tracer(keyword()) :: :ok
  def attach_tracer(opts) do
    opts = NimbleOptions.validate!(opts, @tracer_schema)
    exporter = opts[:exporter]

    unless Code.ensure_loaded?(exporter) and function_exported?(exporter, :export, 1) do
      raise ArgumentError, "exporter #{inspect(exporter)} must export export/1"
    end

    ImagePipe.Telemetry.Trace.set_exporter(exporter)
    ImagePipe.Telemetry.Trace.set_extract_inbound(opts[:extract_inbound])
    ImagePipe.Telemetry.Trace.Capture.attach(%{prefix: opts[:prefix], exporter: exporter})
    if opts[:finch_spans], do: ImagePipe.Telemetry.Trace.FinchCapture.attach(%{exporter: exporter})
    :ok
  end

  @spec detach_tracer() :: :ok
  def detach_tracer do
    ImagePipe.Telemetry.Trace.Capture.detach()
    ImagePipe.Telemetry.Trace.FinchCapture.detach()
    ImagePipe.Telemetry.Trace.set_extract_inbound(false)
    ImagePipe.Telemetry.Trace.set_exporter(nil)
    :ok
  end
```

Note: `NimbleOptions.validate!` raises on unknown/invalid options (satisfies the raising contract). Add `set_exporter/1` + `exporter/0` to `ImagePipe.Telemetry.Trace` (persistent_term), used by `ReqStep`/`FinchCapture` default-exporter lookups.

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/log_exporter_test.exs test/image_pipe/telemetry/trace/capture_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/log_exporter.ex lib/image_pipe/telemetry.ex lib/image_pipe/telemetry/trace.ex \
        test/image_pipe/telemetry/trace/log_exporter_test.exs test/image_pipe/telemetry/trace/capture_test.exs
git commit -m "feat(telemetry): LogExporter + validated raising attach_tracer/1"
```

## Task 18: Boundary exports + architecture test + `## Tracing (opt-in)` docs

**Files:**
- Modify: `lib/image_pipe/telemetry.ex` (Boundary `exports:`)
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Modify: `docs/telemetry.md`

- [ ] **Step 1: Set the boundary exports**

In the telemetry boundary declaration, add `exports:` for exactly: `ImagePipe.Telemetry.Trace.Context`, `…Trace.Stack`, `…Trace.Span`, `…Trace.Exporter`, `…Trace.ReqStep`, and `…Trace` (the facade with `maybe_extract_inbound/1`). Do **not** export `Capture`, `FinchCapture`, `Id`, `W3C`, `LogExporter`, `Inbound`.

- [ ] **Step 2: Add the architecture test**

```elixir
# add to test/image_pipe/architecture_boundary_test.exs
  test "telemetry trace capture does not reference concrete transform/source modules" do
    source = File.read!("lib/image_pipe/telemetry/trace/capture.ex")
    refute source =~ "ImagePipe.Transform.Operation"
    refute source =~ "ImagePipe.Source."
    refute source =~ "ImagePipe.Request."
  end
```

(Follow the existing architecture-test style; source-text scanning is permitted only in this file per CLAUDE.md.)

- [ ] **Step 3: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS. If Boundary reports a violation at compile, fix the `deps:`/`exports:` per the spec §11.

- [ ] **Step 4: Add the `## Tracing (opt-in)` docs section**

In `docs/telemetry.md`, add a section parallel to `## Attaching handlers` documenting `attach_tracer/1`/`detach_tracer/0`, all four options (`exporter`, `prefix`, `extract_inbound`, `finch_spans`), the `Trace.Exporter` `export/1` contract, and a `LogExporter` example. Note inbound extraction is opt-in and sampling is deferred to the host.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry.ex test/image_pipe/architecture_boundary_test.exs docs/telemetry.md
git commit -m "feat(telemetry): boundary exports, architecture test, tracing docs"
```

## Phase 3 gate

- [ ] `mise run precommit` — all green.
- [ ] Manual smoke: attach `LogExporter`, issue one `ImagePipe.call/2`, confirm a flat trace tree in the log; detach.

---

## Self-review checklist (run before handing off to execution)

- Spec coverage: every spec section (§3 layout, §4 model, §5 capture, §6 attr safety, §7 materialize, §8/§8.1 hops + Admission roots, §9 Finch, §10 inbound + sampling-deferred, §11 docs/boundary, §12 tests) maps to a task above.
- The `raise("TODO …")` fixtures in Tasks 8/12/13/14 are **wiring placeholders for real project test fixtures**, called out explicitly for the implementer to fill from `imgproxy_wire_conformance_test.exs`; they are not logic gaps.
- Type consistency: `Trace.Span` field names (`duration_native`, `parent_span_id`, `attributes`, `events`) are used identically across Capture/ReqStep/FinchCapture/LogExporter.
- Sampling: no sampling code anywhere (deferred); `trace_flags` only propagated.
