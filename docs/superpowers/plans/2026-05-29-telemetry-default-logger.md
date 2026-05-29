# Telemetry Default Logger + Per-Operation Transform Spans — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an opt-in `ImagePipe.Telemetry.attach_default_logger/1` that bridges ImagePipe's `:telemetry` events to `Logger`, add per-operation `[:transform, :operation]` tracing spans, migrate the dev server onto the new API, and reframe the AGENTS.md telemetry guideline around sensitivity.

**Architecture:** A new private `ImagePipe.Telemetry.Logger` handler attached/detached through public functions on `ImagePipe.Telemetry` (Oban `attach_default_logger` model). `ImagePipe.Transform.Chain.execute/3` wraps each operation in a span (duration = build time, documented). The dev-only `CacheLogger` is deleted; the mix task calls the real API.

**Tech Stack:** Elixir, `:telemetry`, `Logger`, `Boundary`, ExUnit + `ExUnit.CaptureLog`, `mise exec -- mix`.

**Spec:** `docs/superpowers/specs/2026-05-29-telemetry-default-logger-design.md`

**All commands run via** `mise exec -- ...` and (for anything that compiles `image`/`vix`) prefixed with `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS`.

---

## File Structure

- Create: `lib/image_pipe/telemetry/logger.ex` — `ImagePipe.Telemetry.Logger`, the `handle_event/4` handler + message/level rendering. Belongs to the `ImagePipe.Telemetry` boundary.
- Modify: `lib/image_pipe/telemetry.ex` — add public `attach_default_logger/1` + `detach_default_logger/0` (+ `@moduledoc`); keep helpers `@doc false`.
- Modify: `lib/image_pipe/transform/chain.ex` — `execute/3` with optional `opts`; per-op span; remove `Logger.debug`; add `alias ImagePipe.Telemetry`; drop `require Logger`.
- Modify: `lib/image_pipe/transform.ex` — boundary `deps:` add `ImagePipe.Telemetry`.
- Modify: `lib/image_pipe/transform/plan_executor.ex` — thread `opts` from `execute/3` to `Chain.execute/3`.
- Modify: `lib/mix/tasks/image_pipe.server.ex` — call `attach_default_logger/1`; boundary `deps:` add `ImagePipe.Telemetry`.
- Modify: `dev/simple_server.ex` — remove `exports: [CacheLogger]`.
- Delete: `dev/cache_logger.ex`.
- Modify: `AGENTS.md` — telemetry guideline rewrite (3 edits). (`CLAUDE.md` is a symlink to it.)
- Modify: `test/image_pipe/architecture_boundary_test.exs:395` — transform deps now include `ImagePipe.Telemetry`.
- Create: `test/image_pipe/telemetry/logger_test.exs` — logger unit tests.
- Modify: `test/transform_chain_test.exs` — add per-op span test; assert old debug line gone.

---

## Task 1: Per-operation transform spans (`[:transform, :operation]`)

Emission first, so the logger (Task 2) has the event to render. This also flips the `transform → ImagePipe.Telemetry` boundary edge.

**Files:**
- Modify: `lib/image_pipe/transform/chain.ex`
- Modify: `lib/image_pipe/transform/plan_executor.ex:45,49,51,58,65,76,79`
- Modify: `lib/image_pipe/transform.ex` (boundary deps)
- Modify: `test/image_pipe/architecture_boundary_test.exs:395`
- Test: `test/transform_chain_test.exs`

- [ ] **Step 1: Write the failing test for per-op spans**

In `test/transform_chain_test.exs`, add (the file already `alias ImagePipe.Transform.Chain` and `alias ImagePipe.Transform.State`; it builds chains in existing tests — reuse the same chain shape as the test at line ~37):

```elixir
test "execute/3 emits [:transform, :operation] spans in order with operation metadata" do
  test_pid = self()
  handler = {__MODULE__, :telemetry_handler, System.unique_integer([:positive])}

  :telemetry.attach_many(
    handler,
    [
      [:image_pipe, :transform, :operation, :start],
      [:image_pipe, :transform, :operation, :stop]
    ],
    fn event, measurements, metadata, _ ->
      send(test_pid, {:telemetry, event, measurements, metadata})
    end,
    nil
  )

  on_exit(fn -> :telemetry.detach(handler) end)

  {:ok, image} = Image.new(10, 10)

  chain = [
    %ImagePipe.Transform.Operation.AutoOrient{}
  ]

  assert {:ok, %State{}} = Chain.execute(%State{image: image}, chain)

  assert_received {:telemetry, [:image_pipe, :transform, :operation, :start], _m,
                   %{operation: :auto_orient, index: 0}}

  assert_received {:telemetry, [:image_pipe, :transform, :operation, :stop], %{duration: _},
                   %{operation: :auto_orient, index: 0, result: :ok}}
end
```

Add a public handler helper at the bottom of the test module (telemetry rejects local captures as anonymous in some versions; a named function is safe):

```elixir
def telemetry_handler(_event, _measurements, _metadata, _config), do: :ok
```

> Note: confirm `%ImagePipe.Transform.Operation.AutoOrient{}` is the correct struct + that `Transform.transform_name/1` returns `:auto_orient` for it by checking `lib/image_pipe/transform/operation/auto_orient.ex`. If the name differs, use the actual atom in the assertions.

- [ ] **Step 2: Run the test, verify it fails**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/transform_chain_test.exs -v`
Expected: FAIL — no `[:image_pipe, :transform, :operation, :start]` message received (`assert_received` times out / no match).

- [ ] **Step 3: Add the span in `chain.ex`**

Replace the body of `lib/image_pipe/transform/chain.ex`. Current (lines 1-53) has `require Logger`, `alias ImagePipe.Transform`, `alias ImagePipe.Transform.State`, and `execute/2`. New version:

```elixir
defmodule ImagePipe.Transform.Chain do
  @moduledoc """
  Executes ordered transform operation chains.

  A chain is the ordered list of executable transform operation structs selected
  by transform execution. Execution proceeds left to right through
  `ImagePipe.Transform` and stops at the first operation error.

  Each operation is wrapped in a `[:transform, :operation]` telemetry span for
  tracing. The span duration reflects pipeline *construction* time, not pixel
  work — libvips is lazy and defers/fuses compute to materialization/encode — so
  per-operation duration is for tracing execution structure, not timing. Honest
  aggregate timing lives on the coarse `[:transform, :execute]` stage span.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State

  @typedoc """
  A struct whose module implements `ImagePipe.Transform`.
  """
  @type item() :: Transform.operation()

  @type t() :: [item()]

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   %ImagePipe.Transform.Operation.Resize{
      ...>     mode: :fit,
      ...>     width: {:pixels, 100},
      ...>     height: :auto
      ...>   }
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePipe.Transform.State{image: empty_image}
      ...> {:ok, %ImagePipe.Transform.State{}} = ImagePipe.Transform.Chain.execute(initial_state, chain)
  """
  @spec execute(State.t(), t()) ::
          {:ok, State.t()} | {:error, {:transform_error, term()}}
  @spec execute(State.t(), t(), keyword()) ::
          {:ok, State.t()} | {:error, {:transform_error, term()}}
  def execute(state, transform_chain, opts \\ [])

  def execute(%State{} = state, transform_chain, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    transform_chain
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {operation, index}, {:ok, state} ->
      name = Transform.transform_name(operation)

      result =
        Telemetry.span(
          telemetry_opts,
          [:transform, :operation],
          %{operation: name, index: index, params: operation},
          fn ->
            res = Transform.execute(operation, state)
            {res, %{result: elem(res, 0)}}
          end
        )

      case result do
        {:ok, %State{} = next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, {:transform_error, reason}}}
      end
    end)
  end
end
```

- [ ] **Step 4: Thread `opts` through `plan_executor.ex`**

In `lib/image_pipe/transform/plan_executor.ex`:

`execute/3` (line 45) — use `opts`:
```elixir
  def execute(%Plan{pipelines: pipelines}, %State{} = state, opts) do
    execute_pipelines(pipelines, state, opts)
  end
```

`execute_pipelines/2` → `/3` (line 49):
```elixir
  defp execute_pipelines(pipelines, %State{} = state, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
```

`execute_pipeline/2` → `/3` (line 58):
```elixir
  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
    initial_context = %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

    Enum.reduce_while(operations, {:ok, state, initial_context}, fn operation,
                                                                    {:ok, state, context} ->
      context = update_execution_context(operation, state, context)

      case execute_operation(operation, state, context, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state, context}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, _context} -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end
```

`execute_operation/3` → `/4` (line 76):
```elixir
  defp execute_operation(operation, %State{} = state, context, opts) do
    operation
    |> executable_operations(state, context)
    |> then(&Chain.execute(state, &1, opts))
  end
```

- [ ] **Step 5: Add the boundary edge in `transform.ex`**

In `lib/image_pipe/transform.ex`, change the boundary deps:
```elixir
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
```
(Keep all other existing `use Boundary` options, e.g. `exports:`, exactly as they are.)

- [ ] **Step 6: Update the architecture boundary test**

In `test/image_pipe/architecture_boundary_test.exs:395`, change:
```elixir
    assert_boundary_deps(transform, [ImagePipe.Plan])
```
to:
```elixir
    assert_boundary_deps(transform, [ImagePipe.Plan, ImagePipe.Telemetry])
```

- [ ] **Step 7: Run the per-op span test + arch test + the transform chain suite**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/transform_chain_test.exs test/image_pipe/architecture_boundary_test.exs -v`
Expected: PASS (including the doctest in `chain.ex` and the existing `Chain.execute(state, chain)` 2-arity calls, which still work via the default `opts \\ []`).

- [ ] **Step 8: Confirm the old debug line is gone**

Run: `grep -rn "executing transform" lib/`
Expected: no output (the `Logger.debug` was removed).

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/transform/chain.ex lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform.ex test/image_pipe/architecture_boundary_test.exs test/transform_chain_test.exs
git commit -m "Add per-operation [:transform, :operation] tracing spans"
```

---

## Task 2: `ImagePipe.Telemetry.Logger` handler + `attach_default_logger/1`

Build the consumer covering all groups (request/parse/source/transform/cache), at base level with error/exception escalation. Filtering + debug come in Task 3.

**Files:**
- Create: `lib/image_pipe/telemetry/logger.ex`
- Modify: `lib/image_pipe/telemetry.ex`
- Test: `test/image_pipe/telemetry/logger_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/telemetry/logger_test.exs`:

```elixir
defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry

  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "logs a cache lookup hit at the configured level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "escalates error outcomes to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :write, :stop],
          %{duration: 1000},
          %{result: :cache_error, cache: :write_error, error: :boom}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "cache write"
  end

  test "renders a transform operation with name and index" do
    Telemetry.attach_default_logger(level: :debug)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 500},
          %{operation: :resize, index: 0, params: %{}, result: :ok}
        )
      end)

    assert log =~ "transform: resize (#1)"
  end
end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_pipe/telemetry/logger_test.exs -v`
Expected: FAIL — `Telemetry.attach_default_logger/1` is undefined.

- [ ] **Step 3: Create `lib/image_pipe/telemetry/logger.ex`**

```elixir
defmodule ImagePipe.Telemetry.Logger do
  @moduledoc false
  # Default :telemetry -> Logger handler for ImagePipe. Attached opt-in via
  # ImagePipe.Telemetry.attach_default_logger/1. Reads event maps and calls
  # Logger only; no other dependencies.

  require Logger

  @handler_id "image-pipe-default-logger"

  # group => span event suffixes (each gets :stop + :exception)
  @group_span_events %{
    request: [[:request], [:send]],
    parse: [[:parse]],
    source: [[:source, :resolve], [:source, :fetch], [:source, :fetch_decode]],
    transform: [[:transform, :execute], [:transform, :operation]],
    cache: [[:cache, :lookup], [:cache, :write], [:cache, :admission], [:cache, :warm_start]]
  }

  # cache one-shot events (already terminal; not spans)
  @cache_oneshot [
    [:cache, :eviction, :stop],
    [:cache, :flush, :stop],
    [:cache, :cleanup, :stop],
    [:cache, :stage]
  ]

  @all_groups Map.keys(@group_span_events)

  def handler_id, do: @handler_id
  def all_groups, do: @all_groups

  def attach(opts) do
    groups = Keyword.get(opts, :events, :all) |> expand_groups()
    prefix = Keyword.get(opts, :prefix, ImagePipe.Telemetry.default_prefix())
    level = Keyword.get(opts, :level, :info)
    debug? = Keyword.get(opts, :debug, false)

    config = %{prefix: prefix, level: level, debug?: debug?, plen: length(prefix)}

    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      event_names(groups, prefix),
      &__MODULE__.handle_event/4,
      config
    )
  end

  def detach, do: :telemetry.detach(@handler_id)

  defp expand_groups(:all), do: @all_groups
  defp expand_groups(groups) when is_list(groups), do: groups

  defp event_names(groups, prefix) do
    spans =
      groups
      |> Enum.flat_map(&Map.get(@group_span_events, &1, []))
      |> Enum.flat_map(fn e -> [e ++ [:stop], e ++ [:exception]] end)

    oneshots = if :cache in groups, do: @cache_oneshot, else: []

    Enum.map(spans ++ oneshots, fn e -> prefix ++ e end)
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    suffix = Enum.drop(event, config.plen)
    level = level_for(suffix, metadata, config.level)
    Logger.log(level, fn -> message(suffix, measurements, metadata) end, log_metadata(event, measurements, metadata))

    if config.debug? do
      Logger.debug(fn ->
        "image_pipe #{label(suffix)} raw: measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
      end)
    end

    :ok
  end

  # --- level ---
  defp level_for(suffix, metadata, base) do
    cond do
      List.last(suffix) == :exception -> :warning
      metadata[:result] == :cache_error -> :warning
      true -> base
    end
  end

  # --- message ---
  defp message([:transform, :operation | _], _m, meta) do
    "image_pipe transform: #{meta[:operation]} (##{(meta[:index] || 0) + 1})"
  end

  defp message([:cache, :lookup | _], _m, meta), do: "image_pipe cache lookup: #{meta[:cache]}"

  defp message([:cache, :write | _], _m, meta) do
    detail =
      case meta[:cache] do
        :write -> "stored"
        :admission_rejected -> "rejected by admission"
        :write_error -> "error"
        other -> inspect(other)
      end

    "image_pipe cache write: #{detail}"
  end

  defp message([:cache, :admission | _], _m, meta) do
    "image_pipe cache admission: #{meta[:result]}"
  end

  defp message([:cache, :eviction | _], measurements, meta) do
    "image_pipe cache eviction: #{measurements[:count]} entries (#{meta[:trigger]})"
  end

  defp message(suffix, _m, meta) do
    "image_pipe #{label(suffix)}: #{outcome(meta)}"
  end

  defp outcome(meta), do: meta[:cache] || meta[:result] || :ok

  defp label(suffix) do
    suffix
    |> Enum.reject(&(&1 in [:stop, :exception]))
    |> Enum.map_join(" ", &Atom.to_string/1)
  end

  # --- logger metadata ---
  defp log_metadata(event, measurements, metadata) do
    base = [event: event]

    base =
      case measurements[:duration] do
        nil -> base
        native -> [{:duration_us, System.convert_time_unit(native, :native, :microsecond)} | base]
      end

    Keyword.merge(base, Map.to_list(metadata))
  end
end
```

- [ ] **Step 4: Add public functions to `lib/image_pipe/telemetry.ex`**

Change the `@moduledoc false` to a real doc and add the two functions (place near the top, after `default_prefix/0`):

```elixir
  @moduledoc """
  Telemetry helpers and an opt-in default Logger handler for ImagePipe.

  ImagePipe emits `:telemetry` events only. Hosts attach their own handlers
  (metrics, OpenTelemetry, APM). For convenience, `attach_default_logger/1`
  attaches a stdlib `Logger` handler covering ImagePipe's events.
  """

  alias ImagePipe.Telemetry.Logger, as: DefaultLogger

  @logger_groups [:request, :parse, :source, :transform, :cache]

  @doc """
  Attach the default `Logger` handler for ImagePipe telemetry. Opt-in and
  idempotent.

  Options:
    * `:level` — base log level (default `:info`); errors/exceptions escalate to `:warning`.
    * `:events` — `:all` (default) or a list of `#{inspect(@logger_groups)}`.
    * `:prefix` — telemetry event prefix (default `#{inspect(@default_prefix)}`).
    * `:debug` — when `true`, also log the full raw measurements/metadata (default `false`).
  """
  @spec attach_default_logger(keyword()) :: :ok
  def attach_default_logger(opts \\ []) when is_list(opts) do
    :ok = validate_logger_opts(opts)

    case DefaultLogger.attach(opts) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the default Logger handler."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: DefaultLogger.detach()

  defp validate_logger_opts(opts) do
    known = [:level, :events, :prefix, :debug]

    case Keyword.keys(opts) -- known do
      [] -> validate_events(Keyword.get(opts, :events, :all))
      unknown -> raise ArgumentError, "unknown attach_default_logger options: #{inspect(unknown)}"
    end
  end

  defp validate_events(:all), do: :ok

  defp validate_events(groups) when is_list(groups) do
    case groups -- @logger_groups do
      [] -> :ok
      bad -> raise ArgumentError, "unknown telemetry logger event groups: #{inspect(bad)}"
    end
  end

  defp validate_events(other),
    do: raise(ArgumentError, ":events must be :all or a list, got: #{inspect(other)}")
```

- [ ] **Step 5: Run the logger test, verify it passes**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_pipe/telemetry/logger_test.exs -v`
Expected: PASS (4 tests).

- [ ] **Step 6: Compile clean**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors`
Expected: compiles with no warnings/errors.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex lib/image_pipe/telemetry.ex test/image_pipe/telemetry/logger_test.exs
git commit -m "Add opt-in ImagePipe.Telemetry.attach_default_logger/1"
```

---

## Task 3: `:events` filter + `:debug` raw dump

**Files:**
- Test: `test/image_pipe/telemetry/logger_test.exs`
- (Implementation already present from Task 2 — this task verifies it via tests; add code only if a test fails.)

- [ ] **Step 1: Write the failing tests**

Append to `test/image_pipe/telemetry/logger_test.exs`:

```elixir
  test ":events filter excludes other groups" do
    Telemetry.attach_default_logger(level: :info, events: [:cache])

    log =
      capture_log(fn ->
        # transform group not attached -> nothing logged
        :telemetry.execute([:image_pipe, :transform, :execute, :stop], %{duration: 1}, %{result: :ok})
      end)

    refute log =~ "transform"
  end

  test ":debug true logs the raw payload including high-cardinality fields" do
    Telemetry.attach_default_logger(level: :debug, debug: true)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 1},
          %{operation: :resize, index: 0, params: %{magic: 12_345}, result: :ok}
        )
      end)

    assert log =~ "raw:"
    assert log =~ "12345"
  end

  test "rejects unknown options and bad event groups" do
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(bogus: true) end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(events: [:nope]) end
  end
```

- [ ] **Step 2: Run, verify they pass (implementation already exists)**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_pipe/telemetry/logger_test.exs -v`
Expected: PASS. If `:events`/`:debug`/validation behave wrong, fix `logger.ex`/`telemetry.ex` per Task 2 code, then re-run.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/telemetry/logger_test.exs
git commit -m "Test telemetry logger :events filter, :debug dump, option validation"
```

---

## Task 4: Dev server migration

**Files:**
- Modify: `lib/mix/tasks/image_pipe.server.ex` (boundary deps + `maybe_attach_cache_logger/1` body)
- Modify: `dev/simple_server.ex` (remove `exports: [CacheLogger]`)
- Delete: `dev/cache_logger.ex`

- [ ] **Step 1: Replace the dev attach call**

In `lib/mix/tasks/image_pipe.server.ex`, change the boundary deps line to add `ImagePipe.Telemetry`:
```elixir
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache, ImagePipe.SimpleServer, ImagePipe.Telemetry]
```

Replace `maybe_attach_cache_logger/1` body:
```elixir
  # Dev ergonomics: attach ImagePipe's default Logger handler so the server
  # shows cache + per-operation transform activity. Only when a cache is
  # configured (the main reason to want this in dev).
  defp maybe_attach_cache_logger(nil), do: :ok

  defp maybe_attach_cache_logger(_cache) do
    ImagePipe.Telemetry.attach_default_logger(
      events: [:cache, :transform],
      level: :debug,
      debug: true
    )

    :ok
  end
```

- [ ] **Step 2: Remove the `CacheLogger` export from the dev server**

In `dev/simple_server.ex`, change:
```elixir
  use Boundary,
    top_level?: true,
    exports: [CacheLogger],
    deps: [
      ImagePipe,
      ImagePipe.Parser
    ]
```
to:
```elixir
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe,
      ImagePipe.Parser
    ]
```

- [ ] **Step 3: Delete the dev-only logger**

```bash
git rm dev/cache_logger.ex
```

- [ ] **Step 4: Compile dev/test env clean**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors`
Expected: compiles with no warnings. (Confirms nothing still references `ImagePipe.SimpleServer.CacheLogger`.)

- [ ] **Step 5: Confirm no dangling references**

Run: `grep -rn "CacheLogger" lib/ dev/ test/`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/mix/tasks/image_pipe.server.ex dev/simple_server.ex
git commit -m "Migrate dev server to ImagePipe.Telemetry.attach_default_logger/1"
```

---

## Task 5: AGENTS.md telemetry guideline rewrite

**Files:**
- Modify: `AGENTS.md` (lines 32-42; `CLAUDE.md` is a symlink, updated automatically)

- [ ] **Step 1: Reframe the metadata bullet (sensitivity, not cardinality)**

Replace this block:
```markdown
- Keep telemetry metadata low-cardinality, product-neutral, and safe by default. Don't emit (unless explicit opt-in is designed and documented):
  - Full request paths or source URLs
  - Signatures, tokens, credentials
  - Filenames or other path-derived identifiers
  - Parser-specific structs (dialect paths, parser-internal shapes)
  - Transform internals (operation params, libvips state)
  - Cache adapter internals (cache keys, storage paths)
```
with:
```markdown
- Keep telemetry metadata safe by default. The real constraint is *sensitivity*, not cardinality: metadata fans out to every attached handler (including third-party exporters), so high-cardinality or product-specific data (operation structs, parser structs, decoded dimensions) is fine, but genuinely sensitive data must not be emitted unless an explicit opt-in is designed and documented. Never emit by default:
  - Full request paths or source URLs
  - Signatures, tokens, credentials
  - Filenames or other path-derived identifiers (including filesystem/storage paths and cache keys)
- Cardinality is a consumer concern, not an emission concern: `Telemetry.Metrics` requires the metrics author to choose tags, and nothing forwards the raw metadata map to storage. Emit the data; let handlers project it.
```

- [ ] **Step 2: Reframe the backend-integrations bullet**

Replace:
```markdown
- Keep backend integrations out of the library. Emit telemetry events only; host applications should attach AppSignal, OpenTelemetry, metrics, or logging handlers themselves.
```
with:
```markdown
- Keep third-party backend integrations out of the library: hosts attach AppSignal, OpenTelemetry, and metrics handlers themselves. ImagePipe may ship an opt-in default handler that uses only the stdlib `Logger` (`ImagePipe.Telemetry.attach_default_logger/1`); it is never attached automatically.
```

- [ ] **Step 3: Reframe the per-operation transform span bullet**

Replace:
```markdown
- Do not add per-operation transform spans unless the timing semantics are explicitly designed; libvips operations may be lazy, so stage spans are usually more honest than operation-level timings.
```
with:
```markdown
- Per-operation transform spans (`[:transform, :operation]`) are allowed for tracing execution structure (which operations ran, in what order). Their duration reflects pipeline *construction*, not pixel work — libvips is lazy — so never present per-operation duration as compute timing; keep honest aggregate timing on the coarse `[:transform, :execute]` stage span. Per-operation metadata may include the operation struct (it is derived from the public request, not sensitive).
```

- [ ] **Step 4: Sanity-check the edits**

Run: `grep -n "sensitivity\|per-operation transform spans (\|opt-in default handler" AGENTS.md`
Expected: the three new phrasings appear; the old "low-cardinality" / "Do not add per-operation" lines are gone (`grep -n "low-cardinality\|Do not add per-operation" AGENTS.md` → no output).

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md
git commit -m "Reframe telemetry guidelines: sensitivity over cardinality; allow per-op spans + opt-in logger"
```

---

## Task 6: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test`
Expected: all pass. Pay attention to `test/image_pipe/telemetry_test.exs`, `test/transform_chain_test.exs`, `test/image_pipe/sequential_compatibility_test.exs` (uses `Chain.execute/2`), and the architecture boundary test.

- [ ] **Step 2: Warnings-as-errors compile**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 3: Credo**

Run: `mise exec -- mix credo --strict`
Expected: no new issues from the changed files.

- [ ] **Step 4: Manual dev-server smoke (optional, requires libvips + node)**

Run: `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix image_pipe.server --cache --no-vite`
Then request an image twice. Expected log: `image_pipe cache lookup: miss` → `image_pipe transform: <name> (#n)` lines → `image_pipe cache write: stored`; second request `image_pipe cache lookup: hit`.

- [ ] **Step 5: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "Verification fixups for telemetry default logger"
```

---

## Notes for the implementer

- **Run everything via `mise exec -- ...`**, and prefix libvips-compiling commands with `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS`.
- **`Chain.execute` stays backward-compatible** via `opts \\ []`; do not change the 2-arity call sites in `test/transform_chain_test.exs` / `test/image_pipe/sequential_compatibility_test.exs` / the doctest.
- **`assert_boundary_deps` asserts the exact dep set** — Task 1 Step 6 is required or the arch test fails.
- If `Transform.transform_name/1` returns a different atom than assumed (`:auto_orient`, `:resize`), use the real value in test assertions — verify against `lib/image_pipe/transform/operation/*.ex`.
