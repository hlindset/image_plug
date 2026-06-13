# IIIF Phase 2A — Native Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the product-neutral native primitives the IIIF parser (Phase 2B) will consume — a shared display-dimension helper, a true-grayscale transform op, a `Resize` `:reject` enlargement mode, a transform-emitted `400` mapping, a `{:redirect, …}` parse outcome, and an Accept-negotiation hook on the rendered-delivery path.

**Architecture:** Each primitive is a small, isolated change to an existing layer (plan / transform / output / response / request), independently testable, with no dependency on the IIIF dialect. Built and committed one at a time, TDD-first.

**Tech Stack:** Elixir, `Plug`, `Vix`/`Image` (libvips), `ExUnit` + `StreamData`, `Boundary`. Run everything via `mise exec -- mix …`.

**Spec:** `docs/superpowers/specs/2026-06-13-iiif-phase-2-design.md` (primitives §1–§6).

**Conventions for every task:** run focused tests with `mise exec -- mix test <file>`; before each commit run `mise exec -- mix compile --warnings-as-errors` and `mise exec -- mix format`. If this is a fresh worktree, first run `mise trust` and `mise exec -- mix deps.get`.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/image_pipe/plan/source_info.ex` | + `display_dimensions/1` (orientation→display swap) | A1 |
| `lib/image_pipe/parser/imgproxy/info_renderer.ex` | refactor to call the shared helper | A1 |
| `lib/image_pipe/plan/operation/gray.ex` | **new** semantic gray op | A2 |
| `lib/image_pipe/transform/operation/gray.ex` | **new** executable gray op | A2 |
| `lib/image_pipe/plan/operation.ex` | + `semantic?(%Gray{})` clause | A2 |
| `lib/image_pipe/plan.ex` | + `Operation.Gray` export | A2 |
| `lib/image_pipe/transform.ex` | + `Operation.Gray` export | A2 |
| `lib/image_pipe/transform/plan_executor.ex` | + Gray dispatch; + Resize `:reject` threading | A2, A3 |
| `lib/image_pipe/plan/operation.ex` | `@enlargements` += `:reject` | A3 |
| `lib/image_pipe/transform/operation/resize.ex` | + `reject_enlargement`; upscale-reject in `execute/2` | A3 |
| `lib/image_pipe/response/sender.ex` | + `{:bad_request, _}` → 400; + `send_redirect/3`; + offers negotiation on `{:rendered,…}` | A4, A5, A6 |
| `lib/image_pipe/parser.ex` | widen `@callback parse/2` return | A5 |
| `lib/image_pipe/plug.ex` | redirect short-circuit + `result_metadata` head | A5 |
| `lib/image_pipe/response/json.ex` | `send/4` (response-headers arg) | A6 |
| `lib/image_pipe/request/runner.ex` | widen `{:rendered,…}` to carry `offers` | A6 |

---

## Task A1: Extract `SourceInfo.display_dimensions/1`

**Files:**
- Modify: `lib/image_pipe/plan/source_info.ex`
- Modify: `lib/image_pipe/parser/imgproxy/info_renderer.ex:34,52-54`
- Test: `test/image_pipe/plan/source_info_test.exs` (**already exists** — add to it, don't recreate)

- [ ] **Step 1: Add the failing tests to the existing module**

`test/image_pipe/plan/source_info_test.exs` already exists with struct tests. Add (inside the existing `ImagePipe.Plan.SourceInfoTest` module — do **not** redefine the module) a small helper and two tests:

```elixir
  defp dims_info(orientation),
    do: %ImagePipe.Plan.SourceInfo{format: :jpeg, width: 4000, height: 3000, orientation: orientation}

  test "display_dimensions/1 keeps stored dims for orientations 1-4" do
    for o <- [1, 2, 3, 4] do
      assert ImagePipe.Plan.SourceInfo.display_dimensions(dims_info(o)) == {4000, 3000}
    end
  end

  test "display_dimensions/1 swaps width/height for orientations 5-8" do
    for o <- [5, 6, 7, 8] do
      assert ImagePipe.Plan.SourceInfo.display_dimensions(dims_info(o)) == {3000, 4000}
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/source_info_test.exs`
Expected: FAIL — `function SourceInfo.display_dimensions/1 is undefined`.

- [ ] **Step 3: Add the public function**

In `lib/image_pipe/plan/source_info.ex`, add before the final `end`:

```elixir
  @doc """
  Display (post-EXIF-orientation) dimensions. EXIF orientations 5–8 are
  quarter-turns, so the stored width/height are swapped; all others (and the
  no-rotation case) keep stored order. Pure derivation over this struct's fields.
  """
  @spec display_dimensions(t()) :: {pos_integer(), pos_integer()}
  def display_dimensions(%__MODULE__{width: w, height: h, orientation: o})
      when o in [5, 6, 7, 8],
      do: {h, w}

  def display_dimensions(%__MODULE__{width: w, height: h}), do: {w, h}
```

- [ ] **Step 4: Refactor the imgproxy InfoRenderer to use it**

In `lib/image_pipe/parser/imgproxy/info_renderer.ex`, change the dimension line (currently `info_renderer.ex:34`):

```elixir
    {w, h} = SourceInfo.display_dimensions(info)
```

and delete the now-unused private clauses (`info_renderer.ex:52-54`):

```elixir
  # EXIF orientations 5-8 are quarter-turns: reported width/height are swapped.
  defp display_dimensions(w, h, orientation) when orientation in [5, 6, 7, 8], do: {h, w}
  defp display_dimensions(w, h, _orientation), do: {w, h}
```

- [ ] **Step 5: Run tests to verify both pass**

Run: `mise exec -- mix test test/image_pipe/plan/source_info_test.exs test/image_pipe/parser/imgproxy/info_renderer_test.exs test/image_pipe/parser/imgproxy/info_dispatch_test.exs`
(the imgproxy info tests are the real regression surface for the refactor — they assert the orientation swap via the public `/info` render.)
Expected: PASS. Then `mise exec -- mix compile --warnings-as-errors` (catches the removed-private-fn warning if a reference was missed).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/source_info.ex lib/image_pipe/parser/imgproxy/info_renderer.ex test/image_pipe/plan/source_info_test.exs
git commit -m "feat(plan): extract SourceInfo.display_dimensions/1 shared by info renderers"
```

---

## Task A2: `gray` true-desaturation transform op

**Files:**
- Create: `lib/image_pipe/plan/operation/gray.ex`
- Create: `lib/image_pipe/transform/operation/gray.ex`
- Modify: `lib/image_pipe/plan/operation.ex:405` (add `semantic?` clause before the fallthrough)
- Modify: `lib/image_pipe/plan.ex` (exports), `lib/image_pipe/transform.ex` (exports)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (alias + dispatch clause)
- Modify: `test/image_pipe/architecture_boundary_test.exs` (Plan exports list)
- Test: `test/image_pipe/transform/operation/gray_test.exs` (create); `test/image_pipe/transform/sequential_access_test.exs` (add cases)

- [ ] **Step 1: Write the failing transform-unit test**

Create `test/image_pipe/transform/operation/gray_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.GrayTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Gray
  alias ImagePipe.Transform.State

  @rgb "priv/static/images/beach.jpg"

  defp state_from(path) do
    {:ok, image} = Image.open(path, access: :random)
    %State{image: image}
  end

  test "name/1 is :gray" do
    assert Gray.name(%Gray{}) == :gray
  end

  test "requires_materialization?/1 is false (point op)" do
    assert Gray.requires_materialization?(%Gray{}) == false
  end

  test "desaturates: R, G, B bands are equal at sampled points" do
    {:ok, %State{image: out}} = Gray.execute(%Gray{}, state_from(@rgb))
    {:ok, srgb} = Image.to_colorspace(out, :srgb)

    for {x, y} <- [{0, 0}, {10, 10}, {50, 40}] do
      {:ok, [r, g, b | _]} = Image.get_pixel(srgb, x, y)
      assert r == g and g == b
    end
  end
end
```

> `priv/static/images/beach.jpg` is a real fixture (same one `sequential_access_test.exs` uses as `@beach`). `Image.get_pixel/3` returns `{:ok, [bands…]}`.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/operation/gray_test.exs`
Expected: FAIL — `ImagePipe.Transform.Operation.Gray is undefined`.

- [ ] **Step 3: Create the executable transform op**

Create `lib/image_pipe/transform/operation/gray.ex` (mirrors `operation/saturation.ex`):

```elixir
defmodule ImagePipe.Transform.Operation.Gray do
  @moduledoc """
  Executable true grayscale (desaturation) operation. Converts to the `:bw`
  colourspace, discarding hue/saturation — luminance only. NOT `Monochrome`
  (which tints to a color). Preserves an alpha band when present (libvips
  `colourspace` carries alpha into B_W, giving a 2-band B_W+alpha result).
  Per-pixel point op: sequential-safe (`requires_materialization?/1` is false).
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gray

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.to_colorspace(state.image, :bw) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
```

- [ ] **Step 4: Run the transform-unit test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/operation/gray_test.exs`
Expected: PASS.

- [ ] **Step 5: Create the semantic plan op + wire it**

Create `lib/image_pipe/plan/operation/gray.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Gray do
  @moduledoc """
  Semantic true grayscale (desaturation) quality op. No parameters. Translated
  to `ImagePipe.Transform.Operation.Gray` at execution.
  """

  defstruct []

  @type t :: %__MODULE__{}
end
```

In `lib/image_pipe/plan/operation.ex`, add a `semantic?` clause immediately **before** the fallthrough `def semantic?(_operation), do: false` (`operation.ex:405`):

```elixir
  def semantic?(%Gray{}), do: true
```

and add the alias near the other `Operation.*` aliases at the top of that module:

```elixir
  alias ImagePipe.Plan.Operation.Gray
```

In `lib/image_pipe/transform/plan_executor.ex`, add the alias (with the other `Plan.Operation` aliases, ~line 22) and the dispatch clause (with the other point-op clauses, ~line 604):

```elixir
  alias ImagePipe.Plan.Operation.Gray, as: PlanGray
  alias ImagePipe.Transform.Operation.Gray
```
```elixir
  defp executable_operations(%PlanGray{}, %State{}, _context), do: [%Gray{}]
```

In `lib/image_pipe/plan.ex` `exports:`, add `Operation.Gray` (keep alphabetical — after `Operation.Flip`, before `Operation.Monochrome`).
In `lib/image_pipe/transform.ex` `exports:`, add `Operation.Gray` (after `Operation.Duotone`, before `Operation.Monochrome`).

- [ ] **Step 6: Update the Plan exports architecture-test expectation**

In `test/image_pipe/architecture_boundary_test.exs`, find the **exact-match** Plan `assert_boundary_exports(plan, [...])` list and add `ImagePipe.Plan.Operation.Gray` in alphabetical position. (The Transform list uses `assert_boundary_exports_include` — a subset — so it is **not** test-forced, but add `ImagePipe.Transform.Operation.Gray` there too for hygiene.)

- [ ] **Step 7: Add the AGENTS.md sequential-safety gate**

In `test/image_pipe/transform/sequential_access_test.exs`, add the alias `alias ImagePipe.Transform.Operation.Gray` and, alongside the existing per-op cases (mirror the `Saturation` case), add:

```elixir
  test "gray streams (sequential == random)" do
    assert_sequential_matches_random([%Gray{}], File.read!(@beach))
  end
```

> Match the file's conventions: point ops in `sequential_access_test.exs` (saturation/brightness/contrast) get a single **example** test via `assert_sequential_matches_random/2` over `@beach` — there is **no** body-varying property generator in this file, so do **not** add a `property` block. The file's existing self-check (a raw transpose must raise under the streamed open) already guards against a tautological pass — do not duplicate it.

- [ ] **Step 8: Add an alpha-preservation transform test**

Append to `test/image_pipe/transform/operation/gray_test.exs`:

```elixir
  @rgba "test/support/image_pipe/test/imgproxy_differential/sources/alpha.png"

  test "preserves an alpha band (RGBA -> 2-band B_W + alpha)" do
    {:ok, image} = Image.open(@rgba, access: :random)
    assert Image.has_alpha?(image)
    {:ok, %State{image: out}} = Gray.execute(%Gray{}, %State{image: image})
    assert Image.has_alpha?(out)
  end
```

> `…/imgproxy_differential/sources/alpha.png` is a committed RGBA fixture — confirm it has an alpha band (`Image.has_alpha?/1`); if not, pick another `*.png` from that dir that does. No new fixture needs to be created.

- [ ] **Step 9: Run all gray + boundary tests**

Run:
```
mise exec -- mix test test/image_pipe/transform/operation/gray_test.exs test/image_pipe/transform/sequential_access_test.exs test/image_pipe/architecture_boundary_test.exs
mise exec -- mix compile --warnings-as-errors
```
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/plan/operation/gray.ex lib/image_pipe/transform/operation/gray.ex \
        lib/image_pipe/plan/operation.ex lib/image_pipe/plan.ex lib/image_pipe/transform.ex \
        lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform/operation/gray_test.exs \
        test/image_pipe/transform/sequential_access_test.exs test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(transform): add gray (true desaturation) operation"
```

---

## Task A3: `Resize` `enlargement: :reject`

**Files:**
- Modify: `lib/image_pipe/plan/operation.ex:25` (`@enlargements`)
- Modify: `lib/image_pipe/transform/operation/resize.ex` (struct/type + `execute/2` reject check + `resolve_dimensions` field)
- Modify: `lib/image_pipe/transform/plan_executor.ex:794` (`resize_from/2`)
- Test: `test/image_pipe/transform/operation/resize_reject_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/transform/operation/resize_reject_test.exs`:

```elixir
defmodule ImagePipe.Transform.Operation.ResizeRejectTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  # 100x100 source
  defp state do
    {:ok, image} = Image.new(100, 100, color: [10, 20, 30])
    %State{image: image}
  end

  test ":reject errors when the requested box exceeds the source" do
    op = %Resize{mode: :force, width: {:pixels, 200}, height: {:pixels, 200}, reject_enlargement: true}
    assert {:error, {:bad_request, :upscale_required}} = Resize.execute(op, state())
  end

  test ":reject passes through (200) when the target fits within the source" do
    op = %Resize{mode: :fit, width: {:pixels, 50}, height: {:pixels, 50}, reject_enlargement: true}
    assert {:ok, %State{image: out}} = Resize.execute(op, state())
    assert Image.width(out) == 50
  end

  test ":deny (default) clamps an oversized request without erroring" do
    op = %Resize{mode: :fit, width: {:pixels, 200}, height: {:pixels, 200}}
    assert {:ok, %State{image: out}} = Resize.execute(op, state())
    assert Image.width(out) == 100
  end

  test ":reject also fires when a min dimension forces upscaling past the source" do
    op = %Resize{mode: :fit, width: {:pixels, 50}, height: {:pixels, 50}, min_width: {:pixels, 200}, reject_enlargement: true}
    assert {:error, {:bad_request, :upscale_required}} = Resize.execute(op, state())
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/operation/resize_reject_test.exs`
Expected: FAIL — `key :reject_enlargement not found` (struct has no such field).

- [ ] **Step 3: Add the executable field + reject check**

In `lib/image_pipe/transform/operation/resize.ex`:

Add `reject_enlargement: boolean()` to the `@type t` map (after `enlarge:`) and `reject_enlargement: false` to `defstruct` (after `enlarge: false`).

Replace `execute/2` (`resize.ex:63-87`) so it checks for a rejected upscale first:

```elixir
  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    {src_w, src_h} = State.effective_source_dims(state)

    dimensions =
      resolve_dimensions(operation,
        source_width: src_w,
        source_height: src_h
      )

    cond do
      operation.reject_enlargement and dimensions.upscale_required ->
        {:error, {:bad_request, :upscale_required}}

      true ->
        case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
          {:ok, image} ->
            {:ok, %State{set_image(state, image) | source_dimensions: nil, decode_shrink: nil}}

          {:error, reason} ->
            {:error, {__MODULE__, reason}}
        end
    end
  end
```

Add `upscale_required` to the `resolved_dimensions` type map and compute it in `resolve_dimensions/2`. Insert, just before the returned map is built (after `result_box = result_crop_box(...)`):

```elixir
    unclamped =
      target_dimensions(operation.mode, requested, min_dimensions, source, true)

    upscale_required =
      axis_exceeds?(unclamped.width, source.width) or
        axis_exceeds?(unclamped.height, source.height)
```

and add `upscale_required: upscale_required` to the returned `%{…}`. Then add the helper near the other private dimension helpers:

```elixir
  defp axis_exceeds?(:auto, _source), do: false
  defp axis_exceeds?(value, source) when is_integer(value), do: value > source
```

Add `upscale_required: boolean()` to the `@type resolved_dimensions()` map.

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/operation/resize_reject_test.exs`
Expected: PASS (all three).

- [ ] **Step 5: Thread `:reject` through the plan layer**

In `lib/image_pipe/plan/operation.ex:25`, widen the list:

```elixir
  @enlargements [:allow, :deny, :reject]
```

And widen the plan op's `@type enlargement` in `lib/image_pipe/plan/operation/resize.ex:20` to match:

```elixir
  @type enlargement :: :allow | :deny | :reject
```

In `lib/image_pipe/transform/plan_executor.ex:794`, set the new field in `resize_from/2` (after the `enlarge:` line):

```elixir
      enlarge: operation.enlargement == :allow,
      reject_enlargement: operation.enlargement == :reject
```

- [ ] **Step 6: Verify the full transform + plan suites still pass**

Run: `mise exec -- mix test test/image_pipe/transform/ && mise exec -- mix compile --warnings-as-errors`
Expected: PASS (existing resize tests unaffected: `:allow`/`:deny` behavior is unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/transform/operation/resize.ex lib/image_pipe/plan/operation.ex \
        lib/image_pipe/plan/operation/resize.ex \
        lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform/operation/resize_reject_test.exs
git commit -m "feat(transform): add Resize enlargement: :reject (errors on genuine upscale)"
```

---

## Task A4: `{:bad_request, _}` transform error → HTTP 400

**Files:**
- Modify: `lib/image_pipe/response/sender.ex` (new dispatch head + helper)
- Test: `test/image_pipe/response/sender_bad_request_test.exs` (create)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/response/sender_bad_request_test.exs`:

```elixir
defmodule ImagePipe.Response.SenderBadRequestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Response.Sender

  test "a {:bad_request, _} transform error sends 400" do
    result = {:error, {:processing, {:transform_error, {:bad_request, :upscale_required}}, []}}
    conn = Sender.send_result(conn(:get, "/"), result, [])
    assert conn.status == 400
  end

  test "any other transform error still sends 422" do
    result = {:error, {:processing, {:transform_error, {:some_op, :boom}}, []}}
    conn = Sender.send_result(conn(:get, "/"), result, [])
    assert conn.status == 422
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/response/sender_bad_request_test.exs`
Expected: FAIL — the bad_request case returns 422 (not yet 400).

- [ ] **Step 3: Add the dispatch head + helper**

In `lib/image_pipe/response/sender.ex`, add a new clause **immediately before** the existing generic `{:transform_error, reason}` head at `sender.ex:112`:

```elixir
  defp handle_processing_error(conn, {:transform_error, {:bad_request, _detail}} = reason, response_headers) do
    Logger.info("bad_request: #{inspect(reason)}")
    send_bad_request_error(conn, response_headers)
  end
```

and add the helper near `send_transform_error/2` (`sender.ex:227`):

```elixir
  defp send_bad_request_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "bad request")
  end
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec -- mix test test/image_pipe/response/sender_bad_request_test.exs`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/response/sender.ex test/image_pipe/response/sender_bad_request_test.exs
git commit -m "feat(response): map {:bad_request, _} transform errors to HTTP 400"
```

---

## Task A5: `{:redirect, status, location}` parse outcome

**Files:**
- Modify: `lib/image_pipe/parser.ex:22` (widen `@callback parse/2`)
- Modify: `lib/image_pipe/plug.ex` (redirect short-circuit + `result_metadata` head)
- Modify: `lib/image_pipe/response/sender.ex` (add `send_redirect/3`)
- Test: `test/image_pipe/plug_redirect_test.exs` (create) using a tiny stub parser

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/plug_redirect_test.exs`:

```elixir
defmodule ImagePipe.PlugRedirectTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  defmodule RedirectParser do
    @behaviour ImagePipe.Parser
    @impl true
    def parse(_conn, _opts), do: {:redirect, 303, "/iiif/abc/info.json"}
    @impl true
    def handle_error(conn, _error), do: send_resp(conn, 400, "")
  end

  test "a {:redirect, …} parse result short-circuits to a 303 with Location" do
    conn =
      conn(:get, "/iiif/abc")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(parser: RedirectParser))

    assert conn.status == 303
    assert get_resp_header(conn, "location") == ["/iiif/abc/info.json"]
  end
end
```

> If `ImagePipe.Plug.init/1` requires more options (e.g. an origin), pass the minimum the existing `plug_test.exs` uses for a no-fetch path.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plug_redirect_test.exs`
Expected: FAIL — currently a non-`{:ok,_}`/`{:error,_}` parse result raises (`WithClauseError`/`FunctionClauseError`).

- [ ] **Step 3: Widen the Parser callback**

In `lib/image_pipe/parser.ex`, change the `parse/2` callback spec (`parser.ex:22`):

```elixir
  @callback parse(Plug.Conn.t(), keyword()) ::
              {:ok, ImagePipe.Plan.t()}
              | {:redirect, 303, String.t()}
              | {:error, any()}
```

- [ ] **Step 4: Add the redirect short-circuit in `do_call`**

In `lib/image_pipe/plug.ex`, wrap the existing `with` so the redirect is handled around it. Replace the `do_call/2` body's leading `with {:ok, %Plan{} = plan} <- parse(conn, parser, opts), …` so that `parse` is matched first:

```elixir
  defp do_call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    case parse(conn, parser, opts) do
      {:redirect, status, location} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :redirect, fn ->
            Sender.send_redirect(conn, status, location)
          end)

        {conn, %{result: :redirect, status: status}}

      parsed ->
        do_call_with_plan(conn, parser, opts, parsed)
    end
  end
```

and move the existing `with`/`else` body into a new `do_call_with_plan/4` that takes the already-computed `parsed` result as the first `with` expression:

```elixir
  defp do_call_with_plan(conn, parser, opts, parsed) do
    with {:ok, %Plan{} = plan} <- parsed,
         {:ok, %Plan{} = plan} <- validate_client_plan(plan),
         :ok <- validate_detector_capability(plan, opts),
         {:ok, %Source.Resolved{} = resolved_source} <-
           Source.resolve(plan.source, opts, Options.source_runtime_opts(opts)) do
      prepared_http_cache = HTTPCache.prepare(conn, plan, resolved_source, opts)
      send_conditional_response(conn, plan, resolved_source, prepared_http_cache, opts)
    else
      # … (unchanged existing error clauses) …
    end
  end
```

> Keep the existing `else` clauses verbatim. The only change is that `parse(...)` is now called once in `do_call/2` and threaded in as `parsed`.

Add a `result_metadata/1` head for the redirect so the `[:parse]` telemetry span's stop metadata doesn't crash (`plug.ex:212`):

```elixir
  defp result_metadata({:redirect, status, _location}), do: %{result: :redirect, status: status}
```

- [ ] **Step 5: Add `Sender.send_redirect/3`**

In `lib/image_pipe/response/sender.ex`, add a public function:

```elixir
  @spec send_redirect(Plug.Conn.t(), 303, String.t()) :: Plug.Conn.t()
  def send_redirect(%Plug.Conn{} = conn, status, location) when is_binary(location) do
    conn
    |> put_resp_header("location", location)
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(status, "")
  end
```

(`put_resp_header/3` and `send_resp/3` are from `Plug.Conn`; add to the module's `import Plug.Conn` list if not already imported.)

- [ ] **Step 6: Run it to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plug_redirect_test.exs && mise exec -- mix test test/image_pipe/plug_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS (existing plug tests unaffected — imgproxy never returns `{:redirect, …}`).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser.ex lib/image_pipe/plug.ex lib/image_pipe/response/sender.ex test/image_pipe/plug_redirect_test.exs
git commit -m "feat(request): support a {:redirect, status, location} parse outcome (303 short-circuit)"
```

---

## Task A6: info.json Accept-negotiation hook (offers on the rendered delivery)

**Files:**
- Modify: `lib/image_pipe/response/json.ex` (`send/4`)
- Modify: `lib/image_pipe/request/runner.ex` (widen `{:rendered,…}` + `@type delivery()` + lift `offers` from render params)
- Modify: `lib/image_pipe/response/sender.ex` (Accept-match the offers on the `{:rendered,…}` clause; update `@type delivery()`)
- Modify (existing — **must migrate to the 5-tuple or the suite breaks**): `test/image_pipe/response/sender_render_test.exs:19,40`
- Test: `test/image_pipe/response/render_negotiation_test.exs` (create)

> Blast radius (verified): the only producer/consumer of the `{:rendered,…}` tuple in `lib/` are `runner.ex:48` (build) and `sender.ex:74` (match) — both `@type delivery()` decls (`runner.ex:26`, `sender.ex:30`) change too. In `test/`, the **only** other site is `sender_render_test.exs:19,40`. `Json.send/3`'s other callers (`json_test.exs`) are safe because `send/4` keeps a `headers \\ []` default. The imgproxy `/info` path supplies no `:offers` → `offers == []` → no `Vary`, content-type unchanged, so `imgproxy_wire_conformance_test.exs` (incl. its "no Vary on /info" assertion) stays green.

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/response/render_negotiation_test.exs`:

```elixir
defmodule ImagePipe.Response.RenderNegotiationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Request.CacheHeaders
  alias ImagePipe.Response.Sender

  @offers [{"application/ld+json;profile=\"http://iiif.io/api/image/3/context.json\"", ["application/ld+json"]}]

  defp render(accept) do
    delivery =
      {:ok, {:rendered, "application/json", "{}", @offers, %CacheHeaders{}}}

    conn(:get, "/") |> put_req_header("accept", accept) |> Sender.send_result(delivery, [])
  end

  test "upgrades Content-Type to ld+json when Accept allows it, with Vary: Accept" do
    conn = render("application/ld+json")
    assert ["application/ld+json;" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "falls back to application/json otherwise, still Vary: Accept" do
    conn = render("application/json")
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "no offers (imgproxy /info path): content-type unchanged, no Vary" do
    delivery = {:ok, {:rendered, "application/json", "{}", [], %CacheHeaders{}}}
    conn = conn(:get, "/") |> Sender.send_result(delivery, [])
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == []
  end
end
```

> If `%CacheHeaders{}` needs required keys, build it with whatever the existing render tests use (or the struct's defaults). The `apply_render_cache_headers/2` call must tolerate an empty struct.

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/response/render_negotiation_test.exs`
Expected: FAIL — the `{:rendered,…}` clause currently has 4 elements (no `offers`), so the 5-tuple doesn't match / `Json.send/4` is undefined.

- [ ] **Step 3: Widen `Json.send` to take response headers**

Replace `lib/image_pipe/response/json.ex` `send/3` with `send/4`:

```elixir
  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  @spec send(Plug.Conn.t(), String.t(), iodata(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, content_type, body, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end
```

- [ ] **Step 4: Carry `offers` through the rendered delivery**

In `lib/image_pipe/request/runner.ex`: update the `@type delivery()` `:rendered` arm to 5 elements and lift `offers` from the render params. Change the head's pattern to capture `params` and build the 5-tuple:

```elixir
  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), [{String.t(), [String.t()]}], CacheHeaders.t()}

  def run(
        _conn,
        %Plan{render: {:custom, _module, params}} = plan,
        %Source.Resolved{} = resolved_source,
        %CacheHeaders{} = prepared_http_cache,
        opts
      ) do
    case RenderRunner.run(plan, resolved_source, opts) do
      {:ok, {content_type, body}} ->
        offers = Map.get(params, :offers, [])
        {:ok, {:rendered, content_type, body, offers, prepared_http_cache}}

      {:error, reason} ->
        {:error, {:processing, {:render, reason}, []}}
    end
  end
```

- [ ] **Step 5: Negotiate in the Sender's `{:rendered,…}` clause**

In `lib/image_pipe/response/sender.ex`, update `@type delivery()` (`sender.ex:30`) to the 5-arm form (same as runner) and replace the `{:rendered,…}` `send_result/3` clause (`sender.ex:72-80`):

```elixir
  def send_result(
        %Plug.Conn{} = conn,
        {:ok, {:rendered, content_type, body, offers, %CacheHeaders{} = prepared}},
        _opts
      ) do
    {negotiated_type, vary} = negotiate_render(conn, content_type, offers)

    conn
    |> apply_render_cache_headers(prepared)
    |> maybe_put_vary(vary)
    |> Json.send(negotiated_type, body)
  end
```

and add the private helpers (near the other render helpers):

```elixir
  defp negotiate_render(_conn, base_type, []), do: {base_type, false}

  defp negotiate_render(%Plug.Conn{} = conn, base_type, offers) do
    accept = accept_header(conn)

    case Enum.find(offers, fn {_ct, tokens} -> Enum.any?(tokens, &String.contains?(accept, &1)) end) do
      {offered_type, _tokens} -> {offered_type, true}
      nil -> {base_type, true}
    end
  end

  defp accept_header(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "accept") do
      [value | _] -> value
      [] -> ""
    end
  end

  defp maybe_put_vary(conn, false), do: conn
  defp maybe_put_vary(conn, true), do: Plug.Conn.put_resp_header(conn, "vary", "Accept")
```

> `Json.send/4` is now called with 3 args here (headers default `[]`); the `Vary` header is set directly on the conn before `Json.send`, so it survives.

- [ ] **Step 6: Migrate the existing `sender_render_test.exs` to the 5-tuple**

In `test/image_pipe/response/sender_render_test.exs`, both `{:rendered, …}` literals (`:19` and `:40`) are now stale 4-tuples and will raise `FunctionClauseError`. Insert the `offers` slot (empty list) in each:

```elixir
      Sender.send_result(conn, {:ok, {:rendered, "application/json", ~s({"a":1}), [], prepared}}, [])
```

(Keep both tests as-is otherwise — they still assert the host cache-control precedence / prepared-header merge, now with `offers == []`.)

- [ ] **Step 7: Run it to verify everything passes**

Run: `mise exec -- mix test test/image_pipe/response/render_negotiation_test.exs test/image_pipe/response/sender_render_test.exs test/image_pipe/response/json_test.exs && mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs && mise exec -- mix compile --warnings-as-errors`
Expected: PASS. (imgproxy `/info` supplies no `:offers` → `offers == []` → no `Vary`, content-type unchanged — including the wire test's explicit "no Vary on /info" assertion.)

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/response/json.ex lib/image_pipe/request/runner.ex lib/image_pipe/response/sender.ex \
        test/image_pipe/response/render_negotiation_test.exs test/image_pipe/response/sender_render_test.exs
git commit -m "feat(response): Accept-negotiate rendered responses via static offers (Vary: Accept)"
```

---

## Final verification (Phase 2A)

- [ ] Run the full gate: `mise exec -- mise run precommit` (format check, warnings-as-errors compile, credo --strict, full test suite).
- [ ] Confirm green, then Phase 2A is complete and Phase 2B (`docs/superpowers/plans/2026-06-13-iiif-phase-2b-parser-and-gate.md`) can build on these primitives.

## Spec coverage (self-review)

- §1 transform→400 mapping → **A4** ✓
- §2 Resize `:reject` → **A3** ✓
- §3 `gray` op (+ semantic?/exports/executor/sequential gate/alpha) → **A2** ✓
- §4 redirect parse outcome → **A5** ✓
- §5 info.json negotiation hook (offers as render param, lifted by Runner) → **A6** ✓
- §6 `SourceInfo.display_dimensions/1` extraction → **A1** ✓

(Plan-layer `Plan.Operation.Gray` validation via `semantic?/1` and the `PlanExecutor` Gray dispatch are wired in A2 but exercised end-to-end by the IIIF wire tests in Phase 2B — there is no in-repo producer of a Gray plan until the IIIF parser exists, so per AGENTS.md we do not hand-build a Gray `Plan` in a 2A test.)
