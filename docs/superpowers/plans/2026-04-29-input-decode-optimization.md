# Input Decode Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add conservative sequential input decode for proven one-pass resize pipelines while preserving origin, decode, transform, cache, and output error behavior.

**Architecture:** Transform modules expose local decode-access metadata. `ImagePlug.DecodePlanner` folds that metadata into `Image.open/2` options, and `ImagePlug` uses those options through a decode seam. Sequential requests materialize transformed pixels before cache write or response headers, then verify the origin stream reached a terminal status through an idempotent `ImagePlug.Origin` API.

**Tech Stack:** Elixir, Plug, Req guarded streams, `image`, public `Vix.Vips.Image.copy_memory/1`, ExUnit, StreamData.

---

## File Structure

- Modify `lib/image_plug/transform.ex`: add optional `metadata/1` callback.
- Modify `lib/image_plug/transform/scale.ex`: declare sequential metadata only for width-only and height-only dimension scaling.
- Modify `lib/image_plug/transform/contain.ex`: declare sequential metadata only for regular non-letterboxed dimension containment.
- Modify `lib/image_plug/transform/output.ex`: declare output metadata as access-neutral.
- Modify `lib/image_plug/transform/focus.ex`: declare random access metadata.
- Modify `lib/image_plug/transform/crop.ex`: declare random access metadata.
- Modify `lib/image_plug/transform/cover.ex`: declare random access metadata.
- Create `lib/image_plug/decode_planner.ex`: fold transform metadata into `[access: ..., fail_on: :error]`.
- Create `test/image_plug/decode_planner_test.exs`: planner metadata and folding tests.
- Create `lib/image_plug/origin/terminal_status.ex`: small status holder for idempotent terminal stream state.
- Modify `lib/image_plug/origin.ex`: attach terminal status holder to responses, add `terminal_status/1`, add `require_terminal_status/1`, keep `stream_error/1` as a compatibility wrapper.
- Modify `test/image_plug/origin_test.exs`: idempotent terminal status tests.
- Create `lib/image_plug/image_materializer.ex`: isolate direct public Vix pixel materialization.
- Create `test/image_plug/image_materializer_test.exs`: direct materializer boundary tests.
- Modify `lib/image_plug.ex`: use decode planner, open seam, materializer seam, and error precedence.
- Modify `test/image_plug_test.exs`: open-option integration and lazy stream error tests.
- Create `test/image_plug/sequential_compatibility_test.exs`: random-vs-sequential compatibility proof for each opt-in shape.
- Modify `README.md`: operational notes for sequential decode.
- Create `bench/input_decode_access.exs`: opt-in benchmark script.

## Task 0: Preflight Existing Contracts

**Files:**
- Inspect: `lib/image_plug/transform/*.ex`
- Inspect: `lib/image_plug/origin.ex`
- Inspect: `lib/image_plug.ex`

- [ ] **Step 1: Verify transform behavior declarations**

Run:

```bash
mise exec -- rg -n "@behaviour ImagePlug.Transform" lib/image_plug/transform
```

Expected: output includes `scale.ex`, `contain.ex`, `output.ex`, `focus.ex`, `crop.ex`, and `cover.ex`. If any of those modules are missing the behavior declaration, add `@behaviour ImagePlug.Transform` before adding `@impl ImagePlug.Transform` metadata functions.

- [ ] **Step 2: Check origin response typespecs**

Run:

```bash
mise exec -- rg -n "@type t|defstruct|@enforce_keys" lib/image_plug/origin.ex
```

Expected: if `ImagePlug.Origin.Response` defines a `@type t()`, update it in Task 2 to include `terminal_status: pid()`. If no response type exists, no type edit is needed.

- [ ] **Step 3: Reconfirm response error mapping**

Run:

```bash
mise exec -- rg -n "wrap_origin_decode_error|wrap_decode_error|wrap_input_limit_error|send_origin_error|send_decode_error|send_input_limit_error|send_transform_error" lib/image_plug.ex
```

Expected: origin errors still map through `send_origin_error/2`, decode errors through `send_decode_error/2`, input-limit errors through `send_input_limit_error/2`, and transform errors through `send_transform_error/2`. Use those existing wrappers in later tasks; do not add a parallel error mapping path.

- [ ] **Step 4: Record terminal-status lifecycle decision**

Before implementing Task 2, keep this lifecycle contract in mind: the terminal-status holder is intentionally readable across processes and remains alive for idempotent reads while the origin response is in scope. It is linked to the request/test process that called `Origin.fetch/2`, so its lifecycle is bounded by that process. Do not create unlinked or globally named holders, and do not store `%Origin.Response{}` in cache entries or long-lived state.

## Task 1: Transform Metadata And Decode Planner

**Files:**
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `lib/image_plug/transform/contain.ex`
- Modify: `lib/image_plug/transform/output.ex`
- Modify: `lib/image_plug/transform/focus.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/cover.ex`
- Create: `lib/image_plug/decode_planner.ex`
- Test: `test/image_plug/decode_planner_test.exs`

- [ ] **Step 1: Write the failing planner tests**

Create `test/image_plug/decode_planner_test.exs`:

```elixir
defmodule ImagePlug.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.DecodePlanner
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Contain.ContainParams
  alias ImagePlug.Transform.Cover
  alias ImagePlug.Transform.Cover.CoverParams
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.Crop.CropParams
  alias ImagePlug.Transform.Focus
  alias ImagePlug.Transform.Focus.FocusParams
  alias ImagePlug.Transform.Output
  alias ImagePlug.Transform.Output.OutputParams
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams

  defmodule UnknownTransform do
    defstruct []
  end

  defmodule BogusMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}) do
      %{access: :bogus}
    end
  end

  defmodule MissingAccessMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}) do
      %{other: :metadata}
    end
  end

  test "empty chains open randomly with fail_on error" do
    assert DecodePlanner.open_options([]) == [access: :random, fail_on: :error]
  end

  test "output-only chains stay random" do
    chain = [{Output, %OutputParams{format: :webp}}]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "width-only scale opens sequentially" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "height-only scale opens sequentially" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 120}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "two-dimensional scale stays random" do
    chain = [
      {Scale,
       %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: {:pixels, 90}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "ratio scale stays random" do
    chain = [
      {Scale, %ScaleParams{type: :ratio, ratio: {4, 3}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "regular non-letterboxed dimension contain opens sequentially" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "ratio contain stays random" do
    chain = [
      {Contain, %ContainParams{type: :ratio, ratio: {4, 3}, letterbox: false}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "min contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :min,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "max contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :max,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "letterboxed contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: true
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "focus crop and cover stay random" do
    assert DecodePlanner.open_options([
             {Focus, %FocusParams{type: {:anchor, :left, :top}}},
             {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {Crop, %CropParams{width: {:pixels, 80}, height: {:pixels, 80}, crop_from: :focus}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {Cover,
              %CoverParams{
                type: :dimensions,
                width: {:pixels, 80},
                height: {:pixels, 80},
                constraint: :none
              }}
           ]) == [access: :random, fail_on: :error]
  end

  test "unknown transform modules stay random" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}},
      {UnknownTransform, %UnknownTransform{}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "malformed transform metadata stays random" do
    assert DecodePlanner.open_options([
             {BogusMetadataTransform, %BogusMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {MissingAccessMetadataTransform, %MissingAccessMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]
  end

  test "output transform does not downgrade an otherwise sequential chain" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}},
      {Output, %OutputParams{format: :jpeg}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "planned options include only access and fail_on" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
    ]

    assert Keyword.keys(DecodePlanner.open_options(chain)) == [:access, :fail_on]
  end
end
```

- [ ] **Step 2: Run the planner tests and verify the expected failure**

Run:

```bash
mise exec -- mix test test/image_plug/decode_planner_test.exs
```

Expected: FAIL because `ImagePlug.DecodePlanner` is not defined.

- [ ] **Step 3: Add the optional transform metadata callback**

Modify `lib/image_plug/transform.ex` to this complete module:

```elixir
defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState

  @callback execute(TransformState.t(), struct()) :: TransformState.t()
  @callback metadata(params :: term()) :: map()

  @optional_callbacks metadata: 1
end
```

- [ ] **Step 4: Add metadata implementations to transform modules**

Add this to `lib/image_plug/transform/scale.ex` after the `ScaleParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%ScaleParams{type: :dimensions, width: :auto, height: height})
      when height != :auto do
    %{access: :sequential}
  end

  def metadata(%ScaleParams{type: :dimensions, width: width, height: :auto})
      when width != :auto do
    %{access: :sequential}
  end

  def metadata(%ScaleParams{}) do
    %{access: :random}
  end
```

Add this to `lib/image_plug/transform/contain.ex` after the `ContainParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%ContainParams{
        type: :dimensions,
        constraint: :regular,
        letterbox: false
      }) do
    %{access: :sequential}
  end

  def metadata(%ContainParams{}) do
    %{access: :random}
  end
```

Add this to `lib/image_plug/transform/output.ex` after the `OutputParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%OutputParams{}) do
    %{access: :neutral}
  end
```

Add this to `lib/image_plug/transform/focus.ex` after the `FocusParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%FocusParams{}) do
    %{access: :random}
  end
```

Add this to `lib/image_plug/transform/crop.ex` after the `CropParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%CropParams{}) do
    %{access: :random}
  end
```

Add this to `lib/image_plug/transform/cover.ex` after the `CoverParams` module:

```elixir
  @impl ImagePlug.Transform
  def metadata(%CoverParams{}) do
    %{access: :random}
  end
```

- [ ] **Step 5: Add the decode planner**

Create `lib/image_plug/decode_planner.ex`:

```elixir
defmodule ImagePlug.DecodePlanner do
  @moduledoc false

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(ImagePlug.TransformChain.t()) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.TransformChain.t()) :: :sequential | :random
  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> fold_access()
  end

  defp access_requirement({module, params}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 1) do
      params
      |> module.metadata()
      |> Map.get(:access, :random)
      |> normalize_access()
    else
      :random
    end
  end

  defp access_requirement(_operation), do: :random

  defp normalize_access(access) when access in [:sequential, :random, :neutral], do: access
  defp normalize_access(_access), do: :random

  defp fold_access([]), do: :random

  defp fold_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
```

- [ ] **Step 6: Run planner tests and format**

Run:

```bash
mise exec -- mix test test/image_plug/decode_planner_test.exs
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/scale.ex lib/image_plug/transform/contain.ex lib/image_plug/transform/output.ex lib/image_plug/transform/focus.ex lib/image_plug/transform/crop.ex lib/image_plug/transform/cover.ex lib/image_plug/decode_planner.ex test/image_plug/decode_planner_test.exs
```

Expected: planner tests PASS. Formatting exits 0.

- [ ] **Step 7: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/transform.ex lib/image_plug/transform/scale.ex lib/image_plug/transform/contain.ex lib/image_plug/transform/output.ex lib/image_plug/transform/focus.ex lib/image_plug/transform/crop.ex lib/image_plug/transform/cover.ex lib/image_plug/decode_planner.ex test/image_plug/decode_planner_test.exs
mise exec -- git commit -m "feat: add decode planner"
```

## Task 2: Idempotent Origin Terminal-Status API

**Files:**
- Create: `lib/image_plug/origin/terminal_status.ex`
- Modify: `lib/image_plug/origin.ex`
- Test: `test/image_plug/origin_test.exs`

The terminal-status holder is intentionally idempotent and readable across processes. Its lifecycle is bounded by the process that calls `Origin.fetch/2`: `TerminalStatus.start_link/0` links the holder to that request/test process, and the response must not be retained beyond that process. This preserves repeated terminal reads without leaving unlinked long-lived holder processes per origin response.

- [ ] **Step 1: Add failing terminal-status tests**

Add these tests to `test/image_plug/origin_test.exs` after `"fetch validates status and image content type and exposes a guarded stream"`:

```elixir
  test "terminal_status reports done idempotently after stream completion" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Origin.terminal_status(response) == :pending
    assert Enum.join(response.stream) == "image bytes"
    assert Origin.terminal_status(response) == :done
    assert Origin.terminal_status(response) == :done
    assert Origin.stream_error(response) == nil
    assert Origin.stream_error(response) == nil
  end

  test "terminal_status is visible from another process after stream completion" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Enum.join(response.stream) == "image bytes"

    test_pid = self()
    spawn(fn -> send(test_pid, {:terminal_status, Origin.terminal_status(response)}) end)

    assert_receive {:terminal_status, :done}
  end

  test "terminal_status reports stream errors idempotently" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.png",
               plug: plug,
               max_body_bytes: 5
             )

    assert Enum.to_list(response.stream) == []
    assert Origin.terminal_status(response) == {:error, {:body_too_large, 5}}
    assert Origin.terminal_status(response) == {:error, {:body_too_large, 5}}
    assert Origin.stream_error(response) == {:body_too_large, 5}
    assert Origin.stream_error(response) == {:body_too_large, 5}
  end

  test "require_terminal_status fails pending streams before delivery" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Origin.terminal_status(response) == :pending
    assert Origin.require_terminal_status(response) == {:error, :not_terminal_after_materialization}
    assert Origin.terminal_status(response) == {:error, :not_terminal_after_materialization}
    assert Origin.require_terminal_status(response) == {:error, :not_terminal_after_materialization}
  end
```

Update the existing `"fetch validates status and image content type and exposes a guarded stream"` test assertion:

```elixir
    assert Origin.stream_error(response) == nil
```

Keep it as-is; the wrapper must still pass.

- [ ] **Step 2: Run the origin tests and verify the expected failure**

Run:

```bash
mise exec -- mix test test/image_plug/origin_test.exs
```

Expected: FAIL because `Origin.terminal_status/1` and `Origin.require_terminal_status/1` are undefined.

- [ ] **Step 3: Add the terminal status holder**

Create `lib/image_plug/origin/terminal_status.ex`:

```elixir
defmodule ImagePlug.Origin.TerminalStatus do
  @moduledoc false

  @type status() :: :pending | :done | {:error, term()}

  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> :pending end)
  end

  @spec get(pid()) :: status()
  def get(pid) when is_pid(pid) do
    Agent.get(pid, & &1)
  end

  @spec put(pid(), status()) :: status()
  def put(pid, status) when is_pid(pid) do
    Agent.get_and_update(pid, fn
      :pending -> {status, status}
      terminal -> {terminal, terminal}
    end)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Agent.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end
end
```

- [ ] **Step 4: Attach the holder to origin responses**

Modify the `Response` struct in `lib/image_plug/origin.ex`:

```elixir
  defmodule Response do
    @enforce_keys [:content_type, :headers, :ref, :stream, :terminal_status, :url, :worker]
    defstruct [:content_type, :headers, :ref, :stream, :terminal_status, :url, :worker]
  end
```

Add this alias near the top of `ImagePlug.Origin`:

```elixir
  alias ImagePlug.Origin.TerminalStatus
```

Modify `start_stream/4` to start and attach the holder:

```elixir
  defp start_stream(url, request_options, max_body_bytes, receive_timeout) do
    caller = self()
    ref = make_ref()
    {:ok, terminal_status} = TerminalStatus.start_link()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        stream_worker(
          caller,
          ref,
          url,
          request_options,
          max_body_bytes,
          receive_timeout,
          terminal_status
        )
      end)

    receive do
      {^ref, {:ok, %Response{} = response}} ->
        Process.demonitor(monitor_ref, [:flush])

        {:ok,
         %Response{
           response
           | ref: ref,
             worker: worker,
             terminal_status: terminal_status,
             stream: response_stream(worker, ref)
         }}

      {^ref, {:error, reason}} ->
        TerminalStatus.stop(terminal_status)
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        TerminalStatus.stop(terminal_status)
        {:error, {:transport, reason}}
    after
      receive_timeout ->
        Process.exit(worker, :kill)
        TerminalStatus.stop(terminal_status)
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:timeout, receive_timeout}}
    end
  end
```

Modify the temporary response built in `stream_worker/7` so it includes the new key:

```elixir
             %Response{
               content_type: content_type,
               headers: response_headers(response),
               ref: nil,
               stream: nil,
               terminal_status: nil,
               url: url,
               worker: nil
             }}
```

Modify the private `stream_worker` signature from arity 6 to arity 7 and put the holder into stream state:

```elixir
  defp stream_worker(
         caller,
         ref,
         url,
         request_options,
         max_body_bytes,
         receive_timeout,
         terminal_status
       ) do
    caller_monitor_ref = Process.monitor(caller)

    case Req.get(request_options) do
      {:ok, %Req.Response{} = response} ->
        with :ok <- validate_status(response),
             {:ok, content_type} <- validate_content_type(response) do
          send(caller, {
            ref,
            {:ok,
             %Response{
               content_type: content_type,
               headers: response_headers(response),
               ref: nil,
               stream: nil,
               terminal_status: nil,
               url: url,
               worker: nil
             }}
          })

          stream_loop(%{
            caller: caller,
            caller_monitor_ref: caller_monitor_ref,
            max_body_bytes: max_body_bytes,
            pending: [],
            receive_timeout: receive_timeout,
            ref: ref,
            response: response,
            size: 0,
            terminal_status: terminal_status
          })
        else
          {:error, reason} ->
            cancel_response(response)
            send(caller, {ref, {:error, reason}})
        end

      {:error, exception} ->
        send(caller, {ref, {:error, {:transport, exception}}})
    end
  end
```

- [ ] **Step 5: Add the idempotent API and keep the old wrapper**

Replace `stream_error/1` in `lib/image_plug/origin.ex` with:

```elixir
  @doc """
  Returns the terminal status of a guarded origin stream without consuming it more than once.
  """
  @spec terminal_status(Response.t()) :: :pending | :done | {:error, term()}
  def terminal_status(%Response{terminal_status: terminal_status})
      when is_pid(terminal_status) do
    TerminalStatus.get(terminal_status)
  end

  @doc """
  Forces a pre-delivery terminal decision for sequential pipelines.
  """
  @spec require_terminal_status(Response.t()) :: :done | {:error, term()}
  def require_terminal_status(%Response{terminal_status: terminal_status} = response) do
    case terminal_status(response) do
      :pending ->
        status = TerminalStatus.put(terminal_status, {:error, :not_terminal_after_materialization})
        close(response)
        status

      terminal ->
        terminal
    end
  end

  @doc """
  Compatibility wrapper for callers that only distinguish stream errors from non-errors.
  """
  def stream_error(%Response{} = response) do
    case terminal_status(response) do
      {:error, reason} -> reason
      :done -> nil
      :pending -> nil
    end
  end
```

Replace the terminal updates in `deliver_pending/3`, `fail_stream/3`, and `fail_idle_stream/2` so the worker writes directly to the holder instead of relying on caller mailbox ownership:

```elixir
  defp deliver_pending(:done, from, state) do
    TerminalStatus.put(state.terminal_status, :done)
    send(from, {state.ref, :done})
  end

  defp fail_stream(from, state, reason) do
    reason = normalize_stream_error(reason, state.receive_timeout)

    TerminalStatus.put(state.terminal_status, {:error, reason})
    cancel_response(state.response)
    send(from, {state.ref, {:error, reason}})
  end

  defp fail_idle_stream(state, reason) do
    reason = normalize_stream_error(reason, state.receive_timeout)

    TerminalStatus.put(state.terminal_status, {:error, reason})
    cancel_response(state.response)
  end
```

- [ ] **Step 6: Run origin tests and format**

Run:

```bash
mise exec -- mix test test/image_plug/origin_test.exs
mise exec -- mix format lib/image_plug/origin.ex lib/image_plug/origin/terminal_status.ex test/image_plug/origin_test.exs
```

Expected: origin tests PASS. Formatting exits 0.

- [ ] **Step 7: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/origin.ex lib/image_plug/origin/terminal_status.ex test/image_plug/origin_test.exs
mise exec -- git commit -m "feat: track origin stream terminal status"
```

## Task 3: Materializer Boundary

**Files:**
- Create: `lib/image_plug/image_materializer.ex`
- Create: `test/image_plug/image_materializer_test.exs`
- Modify: `lib/image_plug.ex`
- Test: `test/image_plug_test.exs`

- [ ] **Step 1: Add failing materializer unit test**

Create `test/image_plug/image_materializer_test.exs`:

```elixir
defmodule ImagePlug.ImageMaterializerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ImageMaterializer

  test "materialize returns a memory-resident image with the same dimensions" do
    {:ok, image} = Image.new(32, 24, color: :white)

    assert {:ok, %Vix.Vips.Image{} = materialized} = ImageMaterializer.materialize(image)
    assert Image.width(materialized) == 32
    assert Image.height(materialized) == 24
  end
end
```

- [ ] **Step 2: Run the materializer test and verify the expected failure**

Run:

```bash
mise exec -- mix test test/image_plug/image_materializer_test.exs
```

Expected: FAIL because `ImagePlug.ImageMaterializer` is not defined.

- [ ] **Step 3: Add the materializer module**

Create `lib/image_plug/image_materializer.ex`:

```elixir
defmodule ImagePlug.ImageMaterializer do
  @moduledoc false

  @spec materialize(Vix.Vips.Image.t()) :: {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def materialize(%Vix.Vips.Image{} = image) do
    Vix.Vips.Image.copy_memory(image)
  end
end
```

- [ ] **Step 4: Run the materializer test and format**

Run:

```bash
mise exec -- mix test test/image_plug/image_materializer_test.exs
mise exec -- mix format lib/image_plug/image_materializer.ex test/image_plug/image_materializer_test.exs
```

Expected: materializer test PASS. Formatting exits 0.

- [ ] **Step 5: Commit the isolated materializer boundary**

Run:

```bash
mise exec -- git add lib/image_plug/image_materializer.ex test/image_plug/image_materializer_test.exs
mise exec -- git commit -m "feat: add image materializer"
```

## Task 4: ImagePlug Integration And Error Mapping

**Files:**
- Modify: `lib/image_plug.ex`
- Test: `test/image_plug_test.exs`

For sequential access, successful materialization is treated as the point where libvips must have consumed all bytes needed to prove the transformed image for opt-in shapes. Before any response headers or cache writes, `ImagePlug` checks `Origin.require_terminal_status/1`. If the stream is still pending after successful materialization, that is an internal safety failure for the sequential path and maps as an origin error before delivery.

- [ ] **Step 1: Add failing open-option integration tests**

Add this support module inside `ImagePlug.ImagePlugTest` near the other image test modules:

```elixir
  defmodule RecordingImageOpen do
    # ImagePlug decodes in the caller process, so self() is the test process here.
    def open(stream, opts) do
      send(self(), {:image_open_options, opts})
      Image.open(stream, opts)
    end
  end

  defmodule FailingMaterializer do
    def materialize(_image), do: {:error, :forced_materialization_failure}
  end
```

Add these tests to `test/image_plug_test.exs` near the existing successful response tests:

```elixir
  test "safe one-pass resize opens origin with sequential access" do
    conn =
      conn(:get, "/_/w:100/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert_received {:image_open_options, [access: :sequential, fail_on: :error]}
  end

  test "cover opens origin with random access" do
    conn =
      conn(:get, "/_/fit:cover/w:100/h:100/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert_received {:image_open_options, [access: :random, fail_on: :error]}
  end

  test "sequential materialization failure without origin error returns decode error" do
    conn =
      conn(:get, "/_/w:100/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        image_materializer_module: FailingMaterializer,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "origin response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
```

- [ ] **Step 2: Run integration tests and verify expected failures**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: FAIL because `RecordingImageOpen.open/2` is not called and the materialization-failure test returns `200`.

- [ ] **Step 3: Wire planned decode options into `ImagePlug`**

Add aliases near the top of `lib/image_plug.ex`:

```elixir
  alias ImagePlug.DecodePlanner
  alias ImagePlug.ImageMaterializer
```

Replace `process_origin/4` with:

```elixir
  defp process_origin(request, chain, origin_identity, opts) do
    decode_options = DecodePlanner.open_options(chain)

    with {:ok, origin_response} <-
           fetch_origin(request, origin_identity, opts) |> wrap_origin_error(),
         {:ok, image} <-
           decode_origin_response(origin_response, decode_options, opts)
           |> wrap_origin_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain),
         {:ok, final_state} <-
           materialize_before_delivery(final_state, origin_response, decode_options, opts) do
      {:ok, final_state}
    end
  end
```

Replace `decode_origin_response/1` with:

```elixir
  defp decode_origin_response(%Origin.Response{} = origin_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    case image_open_module.open(origin_response.stream, decode_options) do
      {:ok, image} ->
        case Origin.terminal_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:ok, image}
          :pending -> {:ok, image}
        end

      {:error, decode_error} ->
        case Origin.terminal_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:error, decode_error}
          :pending -> {:error, decode_error}
        end
    end
  end
```

Add this helper below `decode_origin_response/3`:

```elixir
  defp materialize_before_delivery(
         %TransformState{} = state,
         %Origin.Response{} = origin_response,
         decode_options,
         opts
       ) do
    if Keyword.fetch!(decode_options, :access) == :sequential do
      materializer = Keyword.get(opts, :image_materializer_module, ImageMaterializer)

      case materializer.materialize(state.image) do
        {:ok, materialized_image} ->
          case Origin.require_terminal_status(origin_response) do
            :done ->
              {:ok, TransformState.set_image(state, materialized_image)}

            {:error, reason} ->
              {:error, {:origin, reason}}
          end

        {:error, materialize_error} ->
          case Origin.terminal_status(origin_response) do
            {:error, reason} ->
              {:error, {:origin, reason}}

            :done ->
              {:error, {:decode, materialize_error}}

            :pending ->
              Origin.close(origin_response)
              {:error, {:decode, materialize_error}}
          end
      end
    else
      {:ok, state}
    end
  end
```

- [ ] **Step 4: Run integration tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: integration tests PASS, including sequential open-option assertions and the materialization-failure `415`.

- [ ] **Step 5: Run focused planner and origin tests**

Run:

```bash
mise exec -- mix test test/image_plug/decode_planner_test.exs test/image_plug/origin_test.exs test/image_plug/image_materializer_test.exs
mise exec -- mix format lib/image_plug.ex test/image_plug_test.exs
```

Expected: focused tests PASS. Formatting exits 0.

- [ ] **Step 6: Commit**

Run:

```bash
mise exec -- git add lib/image_plug.ex test/image_plug_test.exs
mise exec -- git commit -m "feat: use planned decode access"
```

## Task 5: Sequential Compatibility Tests

**Files:**
- Create: `test/image_plug/sequential_compatibility_test.exs`

- [ ] **Step 1: Write the compatibility proof tests**

Create `test/image_plug/sequential_compatibility_test.exs`:

```elixir
defmodule ImagePlug.SequentialCompatibilityTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Origin
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Contain.ContainParams
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  @cat_path "priv/static/images/cat-300.jpg"
  @dog_path "priv/static/images/dog.jpg"

  test "width-only scale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 100}, height: :auto}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only scale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 100}}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "width-only upscale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 400}, height: :auto}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only upscale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 400}}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "regular non-letterboxed contain matches random access after materialization" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 80},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "regular non-letterboxed contain matches random access for progressive non-square jpeg" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@dog_path))
  end

  test "regular non-letterboxed contain matches random access for alpha png" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 400},
         height: {:pixels, 400},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, alpha_png_body(), "image/png")
  end

  test "successful sequential materialization drains origin stream before delivery" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 100}, height: :auto}}
    ]

    {:ok, _sequential_image, sequential_response} =
      run_chain(chain, :sequential, jpeg_body(@cat_path), "image/jpeg")

    assert Origin.terminal_status(sequential_response) == :done
    assert Origin.terminal_status(sequential_response) == :done
  end

  defp assert_sequential_matches_random(chain, body, content_type \\ "image/jpeg") do
    {:ok, random_image, _random_response} = run_chain(chain, :random, body, content_type)
    {:ok, sequential_image, sequential_response} = run_chain(chain, :sequential, body, content_type)

    assert Origin.terminal_status(sequential_response) == :done
    assert Origin.terminal_status(sequential_response) == :done
    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp run_chain(chain, access, body, content_type) when access in [:random, :sequential] do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, body)
    end

    with {:ok, response} <-
           Origin.fetch("https://img.example/fixture", plug: plug),
         {:ok, image} <- Image.open(response.stream, access: access, fail_on: :error),
         {:ok, state} <- TransformChain.execute(%TransformState{image: image}, chain),
         {:ok, materialized_image} <- ImageMaterializer.materialize(state.image) do
      {:ok, materialized_image, response}
    end
  end

  defp assert_sampled_pixels_match(left, right) do
    width = Image.width(left)
    height = Image.height(left)

    for x <- sample_positions(width),
        y <- sample_positions(height) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)

    [0, div(last, 4), div(last, 2), div(last * 3, 4), last]
    |> Enum.uniq()
  end

  defp jpeg_body(path), do: File.read!(path)

  defp alpha_png_body do
    {:ok, image} = Image.new(320, 180, color: [0, 255, 0, 255], bands: 4)
    Image.write!(image, :memory, suffix: ".png")
  end
end
```

- [ ] **Step 2: Run compatibility tests**

Run:

```bash
mise exec -- mix test test/image_plug/sequential_compatibility_test.exs
```

Expected: PASS. These tests compare dimensions, alpha mode, terminal origin status, and a deterministic 5-by-5 pixel grid instead of encoded output bytes.

- [ ] **Step 3: Format and commit**

Run:

```bash
mise exec -- mix format test/image_plug/sequential_compatibility_test.exs
mise exec -- git add test/image_plug/sequential_compatibility_test.exs
mise exec -- git commit -m "test: prove sequential transform compatibility"
```

## Task 6: Lazy Stream Error Tests

**Files:**
- Modify: `test/image_plug_test.exs`
- Modify: `lib/image_plug.ex` only if these tests expose an error-precedence bug.

- [ ] **Step 1: Add lazy sequential stream test support**

Add these support modules inside `ImagePlug.ImagePlugTest` near the existing origin fixtures:

```elixir
  defmodule CorruptTailOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")
      prefix_size = max(byte_size(body) - 64, 1)
      body = binary_part(body, 0, prefix_size) <> :binary.copy(<<0>>, 64)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule ChunkedOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_chunked(200)

      midpoint = div(byte_size(body), 2)
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, 0, midpoint))
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, midpoint, byte_size(body) - midpoint))
      conn
    end
  end
```

- [ ] **Step 2: Add lazy sequential error tests**

Add these tests to `test/image_plug_test.exs` near the existing origin/decode error tests:

```elixir
  test "sequential body limit after initial valid bytes remains an origin error before image headers" do
    body = File.read!("priv/static/images/cat-300.jpg")

    conn =
      conn(:get, "/_/w:100/plain/images/large-body.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: ChunkedOriginImage]
      )

    assert conn.status == 502
    assert conn.state == :sent
    assert conn.resp_body == "error fetching origin image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "sequential timeout after initial valid bytes remains an origin error before image headers" do
    conn =
      conn(:get, "/_/w:100/plain/images/slow.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_receive_timeout: 50,
        origin_req_options: [plug: SlowPartialOriginImage]
      )

    assert conn.status == 502
    assert conn.state == :sent
    assert conn.resp_body == "error fetching origin image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "sequential corrupt image tail without origin error remains a decode error" do
    conn =
      conn(:get, "/_/w:100/plain/images/corrupt-tail.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CorruptTailOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "origin response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
```

The materialization-failure `415` test was added in Task 4 and should remain in this file.

- [ ] **Step 3: Run lazy stream tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: PASS. If any test returns `200` or `500`, inspect whether `materialize_before_delivery/4` checks `Origin.require_terminal_status/1` after successful materialization and whether materializer failures are wrapped as `{:error, {:decode, reason}}` when no origin stream error exists.

- [ ] **Step 4: Format and commit**

Run:

```bash
mise exec -- mix format test/image_plug_test.exs lib/image_plug.ex
mise exec -- git add test/image_plug_test.exs lib/image_plug.ex
mise exec -- git commit -m "test: preserve lazy stream error semantics"
```

## Task 7: Docs And Opt-In Benchmark

**Files:**
- Modify: `README.md`
- Create: `bench/input_decode_access.exs`

- [ ] **Step 1: Update README operational notes**

Add this paragraph to `README.md` under `## Operational Notes`, after the origin fetch paragraph:

```markdown
For transform chains that are proven to be safe for one-pass reads, ImagePlug may open the origin image with libvips sequential access before resizing. The first supported shapes are width-only scale, height-only scale, and regular non-letterboxed contain; these shapes may use sequential access whether the result downscales or upscales. Chains involving crop, focus, cover, letterboxing, unknown transforms, output-only requests, or no geometry transform continue to use random access.

Sequential decode does not use JPEG shrink-on-load or WebP scale hints in this pass. Origin byte limits, receive timeouts, decoded pixel limits, and decode error responses still apply. Cache hits serve stored response bodies directly and do not participate in origin decode optimization.
```

- [ ] **Step 2: Add the opt-in benchmark script**

Create `bench/input_decode_access.exs`:

```elixir
defmodule ImagePlug.InputDecodeAccessBenchmark do
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  @scale_chain [
    {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 200}, height: :auto}}
  ]

  def run(argv) do
    {:ok, _apps} = Application.ensure_all_started(:image)

    access = parse_access(argv)
    body = large_jpeg_body()

    {microseconds, {:ok, image}} =
      :timer.tc(fn ->
        with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
             {:ok, state} <- TransformChain.execute(%TransformState{image: image}, @scale_chain),
             {:ok, materialized} <- ImageMaterializer.materialize(state.image) do
          {:ok, materialized}
        end
      end)

    IO.puts("access=#{access}")
    IO.puts("width=#{Image.width(image)}")
    IO.puts("height=#{Image.height(image)}")
    IO.puts("wall_ms=#{System.convert_time_unit(microseconds, :microsecond, :millisecond)}")
    IO.puts("beam_memory_bytes=#{:erlang.memory(:total)}")
    IO.puts("vips_tracked_memory_bytes=#{Vix.Vips.tracked_get_mem()}")
    IO.puts("vips_highwater_memory_bytes=#{Vix.Vips.tracked_get_mem_highwater()}")
  end

  defp parse_access(["random"]), do: :random
  defp parse_access(["sequential"]), do: :sequential

  defp parse_access(other) do
    raise ArgumentError, "expected one argument: random or sequential, got #{inspect(other)}"
  end

  defp large_jpeg_body do
    {:ok, source} = Image.open("priv/static/images/cat-300.jpg", access: :random, fail_on: :error)
    {:ok, large} = Image.resize(source, 16.0)
    Image.write!(large, :memory, suffix: ".jpg")
  end
end

ImagePlug.InputDecodeAccessBenchmark.run(System.argv())
```

- [ ] **Step 3: Run docs/benchmark checks**

Run:

```bash
mise exec -- mix run --no-start bench/input_decode_access.exs -- random
mise exec -- mix run --no-start bench/input_decode_access.exs -- sequential
mise exec -- mix format bench/input_decode_access.exs
```

Expected: both benchmark runs print `access=...`, dimensions, wall time, BEAM memory, and Vix tracked memory. Treat the numbers as directional because large fixture generation happens in the same BEAM process and can affect high-water memory before the timed operation. No pass/fail threshold is required. Formatting exits 0.

- [ ] **Step 4: Commit**

Run:

```bash
mise exec -- git add README.md bench/input_decode_access.exs
mise exec -- git commit -m "docs: describe sequential decode"
```

## Task 8: Full Verification

**Files:**
- All changed files.

- [ ] **Step 1: Run full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests PASS.

- [ ] **Step 2: Run compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: compilation succeeds with no warnings.

- [ ] **Step 3: Run formatter check**

Run:

```bash
mise exec -- mix format --check-formatted
```

Expected: formatter check exits 0.

- [ ] **Step 4: Review direct Vix usage isolation**

Run:

```bash
mise exec -- rg -n "Vix\\.Vips\\.Image\\.copy_memory|copy_memory\\(" lib test bench
```

Expected: direct `Vix.Vips.Image.copy_memory/1` appears only in `lib/image_plug/image_materializer.ex`. Tests and benchmark may call `ImagePlug.ImageMaterializer.materialize/1`, not Vix directly.

- [ ] **Step 5: Commit any verification fixes**

If verification required fixes, run:

```bash
mise exec -- git add lib test README.md bench
mise exec -- git commit -m "fix: stabilize sequential decode"
```

If no fixes were needed, do not create an empty commit.

- [ ] **Step 6: Summarize representative benchmark output**

Run:

```bash
mise exec -- mix run --no-start bench/input_decode_access.exs -- random
mise exec -- mix run --no-start bench/input_decode_access.exs -- sequential
```

Expected: capture the printed `wall_ms`, `vips_tracked_memory_bytes`, and `vips_highwater_memory_bytes` values in the implementation summary as representative directional data. Do not treat benchmark numbers as test assertions.

## Self-Review Checklist

- [x] Spec coverage: planner metadata, idempotent origin terminal status, materializer boundary, `ImagePlug` integration, compatibility tests, lazy stream error tests, docs, and benchmark are each mapped to a task.
- [x] Placeholder scan: plan contains no open-ended implementation placeholders.
- [x] Type consistency: `ImagePlug.DecodePlanner.open_options/1`, `ImagePlug.Origin.terminal_status/1`, `ImagePlug.Origin.require_terminal_status/1`, and `ImagePlug.ImageMaterializer.materialize/1` are named consistently across tasks.
- [x] Error precedence: origin terminal errors win over decode/materialization errors; input limit remains before transform; transform errors remain `422`; output negotiation and encoder behavior remain outside the materialization boundary.
- [x] First-pass scope: no JPEG `shrink`, no WebP `scale`, no thumbnail fusion for cover/crop, and no public documentation for test seams.
- [x] Review hardening: preflight checks, access-neutral naming, terminal holder lifecycle, materialization drain contract, robust compatibility sampling, and directional benchmark wording are represented in the plan.
