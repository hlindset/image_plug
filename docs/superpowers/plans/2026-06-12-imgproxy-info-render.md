# imgproxy `/info` Render Mechanism — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cross-dialect, non-image JSON render path and ship imgproxy's `/info` endpoint (header-depth field set) as its first consumer.

**Architecture:** A `Plan.render` selector (default `:image_encode`) chooses a terminal renderer. Non-image renders run in the **request layer** (`Runner`) — never through the streaming `SourceSession`/`Producer` — calling `Processor.fetch_decode_validate_source_with_source_format/3`, building a neutral `Plan.RenderContext{info: %Plan.SourceInfo{}}`, calling an `Output.Render` renderer, and returning a complete-body `{:rendered, content_type, body, cache_headers}` delivery. The imgproxy parser recognizes a `/info` path prefix and emits an `:imgproxy_info` render spec.

**Tech Stack:** Elixir, Plug, Vix/libvips, `Boundary`, ExUnit, NimbleOptions.

**Spec:** `docs/superpowers/specs/2026-06-12-cross-dialect-info-render-mechanism-design.md`

**Conventions:** Run everything with `mise exec -- ...`. Run a single test file with `mise exec -- mix test path:line`. The Elixir gate is `mise exec -- mix run -e "" ` → use `mise run precommit` before finishing. Boundary export assertions in `test/image_pipe/architecture_boundary_test.exs` are **exact-match** — when you add a `Plan.*` / `Output.*` export you must add it to that test's list too, or it fails.

---

## File map

**Create:**
- `lib/image_pipe/plan/source_info.ex` — neutral header-facts struct.
- `lib/image_pipe/plan/render.ex` — render selector spec (`renderer` tag + `params`).
- `lib/image_pipe/plan/render_context.ex` — neutral context passed to renderers.
- `lib/image_pipe/output/render.ex` — `Output.Render` behaviour + tag→module dispatch.
- `lib/image_pipe/output/render/imgproxy_info.ex` — imgproxy info JSON renderer (owns wire spellings).
- `lib/image_pipe/request/render_runner.ex` — request-layer render orchestration (decode → context → render).
- `lib/image_pipe/response/json.ex` — complete-body non-image sender helper.
- Test files mirroring each.

**Modify:**
- `lib/image_pipe/plan.ex` — add `render` field, `validate_render`, exports.
- `lib/image_pipe/transform.ex` — `validate_prefetch_safe_plan` allows empty pipeline for render plans.
- `lib/image_pipe/cache/key.ex` — fold render selector into `representation:`.
- `lib/image_pipe/request/runner.ex` — branch to render path; add `{:rendered}` to `delivery()`.
- `lib/image_pipe/response/sender.ex` — `{:rendered}` `delivery()` variant + `send_result/3` clause.
- `lib/image_pipe/output.ex` — export `Render`.
- `lib/image_pipe/parser/imgproxy.ex` + `parser/imgproxy/path.ex` + `parser/imgproxy/plan_builder.ex` — `/info` dispatch.
- `lib/image_pipe/telemetry/logger.ex` + `docs/telemetry.md` — `[:render]` span.
- `docs/imgproxy_support_matrix.md` — info rows + divergences.
- `test/image_pipe/architecture_boundary_test.exs` — new exports.

---

## Plan-review corrections (READ FIRST — applies on top of the tasks below)

A three-reviewer pass found these code-verified issues. Apply each within the named
task; they override the task body where they conflict.

**Two decisions — RESOLVED by the maintainer:**

- **D1 — JSON library → stdlib `JSON`, bump the Elixir floor.** Before Task 5, add a
  **Task 0**: in `mix.exs` change the `elixir:` requirement from `~> 1.17` to
  `~> 1.18` (stdlib `JSON` is 1.18+; the dev toolchain is already 1.20). No new dep.
  Run `mise exec -- mix compile` to confirm, commit
  `chore: require Elixir ~> 1.18 for stdlib JSON (#252)`. Tasks 5/12 then use
  `JSON.encode_to_iodata!` / `JSON.decode!` as written.
- **D2 — expired-`/info` status → keep 400, record the divergence.** Task 12's
  expired test asserts `conn.status == 400` (the repo's actual shared `handle_error`
  behavior). Do **not** add a 404 clause (that would change the processing endpoint
  too — out of scope). Task 14 records "expired URL returns 400; imgproxy returns
  404" as a known divergence.

**Task 4 + Task 5 — merge into one task (no red commit, no phantom list):**
- There is **no `assert_boundary_exports(ImagePipe.Output, …)`** in
  `architecture_boundary_test.exs` (Output only has dep assertions). Drop the
  instruction to "add `Render` to the Output exports list" — just add `Render` to
  `lib/image_pipe/output.ex` `exports:`. (Optionally add a new
  `assert_boundary_exports(output, [Render, ...])` to lock it, but only if you also
  enumerate the existing exports.)
- The `@renderers` map references `ImagePipe.Output.Render.ImgproxyInfo`, created in
  Task 5. **Do Tasks 4 and 5 as a single red→green→commit**: behaviour + dispatch +
  the renderer + both test files in one commit. The Task 4 `module(:imgproxy_info)`
  assertion only passes once Task 5's module exists.

**Task 5 — fix the `@wire` table (verified against imgproxy `imagetype/defs.go`):**
- The detectable rows are byte-correct (`jpeg/png/webp/avif`, `heif → "heic"/
  image/heif`, `tiff`, `jpeg_xl → "jxl"/image/jxl`). **Drop the `:gif` row** —
  `Request.SourceFormat.from_image/1` never produces `:gif`, so it's unreachable.
- **Add `:jpeg2000`** (which `SourceFormat` *does* produce via `jp2kload`). The
  generic fallback currently fabricates `{"jpeg2000", "application/octet-stream"}`,
  but imgproxy has no JP2 type at all (it would report `format: null`). ImagePipe
  *can* decode JP2, so this is a deliberate divergence: map
  `jpeg2000: {"jp2", "image/jp2"}` and record it in Task 14. The `@moduledoc`'s
  "no jpeg2000 type" line refers to imgproxy — keep it but note our divergence.

**Task 6 — wrong return shape (BLOCKER).** `Transform.validate_prefetch_safe_plan/1`
returns `{:ok, [Pipeline.t()]}`, NOT `{:ok, plan}`, and the plug binds
`{:ok, _pipelines}` at `plug.ex:133`. The render carve-out must return the
pipeline-list shape **and** still run shape validation:

```elixir
def validate_prefetch_safe_plan(%Plan{render: render} = plan) when render != :image_encode do
  case Plan.validate_shape(plan) do
    {:ok, %Plan{pipelines: pipelines}} -> {:ok, pipelines}   # [] for an info plan
    {:error, _} = error -> error
  end
end
```

Fix the Task 6 test accordingly: assert `{:ok, []}` for the render plan and the
real `{:error, :empty_pipeline_plan}` (verify the exact error term) for the
image-encode plan.

**Task 10 — two unstated edits.** (a) Prefix the unused `conn` in the new render
`run/5` clause as `_conn`, or `mix compile --warnings-as-errors` fails. (b) The new
`handle_processing_error(conn, {:render, reason}, _)` clause must be placed **before**
the `when tag in @plan_validation_error_tags` guard clause in `sender.ex` (≈line
150), or `{:render, _}` falls through to no clause and crashes.

**Task 11 — feasible but the sketch will not compile as written. Required:**
- `decode_source_path/2`, `encoded_source_value/2`, `decode_encoded_source/2` are
  **private** (`path.ex:135, 154, 238`). Promote them or add thin public wrappers
  before `parse_source_no_extension/3` can call them.
- `ParsedRequest` is rigidly typed: `@enforce_keys [:signature, :source_kind,
  :source_path, :pipelines]`, `source_kind: :plain`, `source_path: String.t()` (a
  **single binary**). The existing `parsed_request/4` (`imgproxy.ex:218-238`)
  hardcodes `source_kind: :plain` and stores the single decoded `source` binary that
  `Path.parse_source` returns. `PlanBuilder.source_plan` only handles `:plain`
  (`plan_builder.ex:47-51`). So the info path must **mirror `parsed_request/4`**:
  decode to a single `source` binary, set `source_kind: :plain`. Add `info?: false`
  to `ParsedRequest`'s `defstruct` + `@type`, set `info?: true` on the info path.
- `Path.split_endpoint/1`: `parser_request_path/1` reads **`request_path`** (after
  `script_name` prefix stripping, `path.ex:179-195`), so the load-bearing peel is
  `%{conn | request_path: "/" <> rest}`. The `path_info: nil` in the sketch is inert
  — **treat the sketch as illustrative; read `parser_request_path/1` first** and peel
  the leading `"info"` from whatever it actually reads.
- Keep the empty-source guard: `parse_source_no_extension(:plain, ...)` must still
  reject a bare `/info/unsafe/plain/` (missing source identifier), as
  `parse_plain_source` does.

**Task 12 — expired test asserts 400 (per D2):** change `assert conn.status == 404`
to `assert conn.status == 400` (the repo's actual behavior) unless D2 chooses 404.
The `exp:` option spelling is correct.

**Task 13 — telemetry message clause (BLOCKER).** The span event suffix includes
`:stop`, absorbed by `| _` in the Logger's `message/3` clauses (see
`logger.ex:205`). So the clause must be `defp message([:render | _], measurements,
meta)`, placed before the generic fallback. There is **no `duration_ms/1` helper** —
remove it; use the existing `outcome/1` and, if you want duration, read
`measurements[:duration]` the way the other clauses do. Adding `[:render]` to the
`request:` group in `@group_span_events` is correct.

**Task 7 — note.** `representation_data/0` is at `key.ex:89`, call site `key.ex:73`.
Adding `render:` to the keyword changes the canonical bytes for **all** requests, so
**regenerate any committed cache-key hash fixtures** in `test/image_pipe/cache/`.

**Task 9 — drop the tautological assertion.** `build_source_info/2` is passed
`byte_size` directly, so asserting `info.byte_size == 4096` tests nothing. Keep the
`format`/`width`/`height`/`orientation` assertions; drop the `byte_size` one.

**Task 14 — divergence wording fixes.** (a) `size`: imgproxy emits it from the
source response's **`Content-Length` header** (it does **not** download); ImagePipe
omits it in Phase 1. (b) Add: `mime_type` — imgproxy derives MIME from the response
`Content-Type` / extension / magic bytes; ImagePipe derives it from the decoded
format atom. (c) Add the JP2 divergence (Task 5) and the expired-status divergence
(D2, if 400 is kept).

**Caching decision (spec line 320):** Phase 1 does the cache-**key fold** (Task 7,
mandatory) but does **not store** rendered bodies. The render path returns
`{:rendered, …}` directly from `Runner` without a cache write — leave it that way;
storage is an explicit follow-up.

---

## Task 1: `Plan.SourceInfo` struct

**Files:**
- Create: `lib/image_pipe/plan/source_info.ex`
- Create: `test/image_pipe/plan/source_info_test.exs`
- Modify: `lib/image_pipe/plan.ex` (exports)
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

`test/image_pipe/plan/source_info_test.exs`:

```elixir
defmodule ImagePipe.Plan.SourceInfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.SourceInfo

  test "holds neutral source facts with byte_size optional" do
    info = %SourceInfo{
      format: :jpeg,
      width: 1200,
      height: 800,
      orientation: 1,
      byte_size: 12_345
    }

    assert info.format == :jpeg
    assert info.width == 1200
    assert info.height == 800
    assert info.orientation == 1
    assert info.byte_size == 12_345
  end

  test "byte_size defaults to nil" do
    info = %SourceInfo{format: :png, width: 10, height: 10, orientation: 1}
    assert info.byte_size == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/source_info_test.exs`
Expected: FAIL — `ImagePipe.Plan.SourceInfo` is undefined.

- [ ] **Step 3: Create the struct**

`lib/image_pipe/plan/source_info.ex`:

```elixir
defmodule ImagePipe.Plan.SourceInfo do
  @moduledoc """
  Product-neutral facts about a decoded source image, read from the lazy header
  open. Consumed by `ImagePipe.Output.Render` renderers. `width`/`height` are the
  STORED (pre-orientation) dimensions; renderers apply orientation as needed.
  `byte_size` is the lone non-header field, filled by the request layer from the
  source response / filesystem (nil when unavailable).
  """

  @enforce_keys [:format, :width, :height, :orientation]
  defstruct @enforce_keys ++ [byte_size: nil]

  @type t :: %__MODULE__{
          format: atom(),
          width: pos_integer(),
          height: pos_integer(),
          orientation: 1..8,
          byte_size: non_neg_integer() | nil
        }
end
```

- [ ] **Step 4: Export from the `Plan` boundary**

In `lib/image_pipe/plan.ex`, add `SourceInfo` to the `exports:` list (alphabetical-ish near `Source`):

```elixir
      Response,
      SourceInfo,
      Color,
```

- [ ] **Step 5: Add to the architecture boundary export assertion**

In `test/image_pipe/architecture_boundary_test.exs`, find the `assert_boundary_exports(ImagePipe.Plan, ...)` list and add `SourceInfo` to it (match the existing format).

- [ ] **Step 6: Run tests**

Run: `mise exec -- mix test test/image_pipe/plan/source_info_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/plan/source_info.ex test/image_pipe/plan/source_info_test.exs lib/image_pipe/plan.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(plan): add neutral SourceInfo header-facts struct (#252)"
```

---

## Task 2: `Plan.Render` spec + `Plan.render` field + validation

**Files:**
- Create: `lib/image_pipe/plan/render.ex`
- Create: `test/image_pipe/plan/render_test.exs`
- Modify: `lib/image_pipe/plan.ex` (struct field, `validate_shape`, `shape_error`, exports)
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

`test/image_pipe/plan/render_test.exs`:

```elixir
defmodule ImagePipe.Plan.RenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Render
  alias ImagePipe.Plan.Source

  defp base_plan(extra) do
    struct!(
      %Plan{
        source: %Source.Path{segments: ["a.jpg"]},
        pipelines: [],
        output: %Output{mode: :automatic}
      },
      extra
    )
  end

  test "render defaults to :image_encode" do
    plan = base_plan(pipelines: [%Plan.Pipeline{operations: []}])
    assert plan.render == :image_encode
  end

  test "validate_shape accepts a render spec" do
    plan = base_plan(render: %Render{renderer: :imgproxy_info, params: %{}})
    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate_shape rejects a non-render, non-:image_encode value" do
    plan = base_plan(render: :bogus)
    assert {:error, {:invalid_render_plan, :bogus}} = Plan.validate_shape(plan)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/render_test.exs`
Expected: FAIL — `ImagePipe.Plan.Render` undefined / `render` key missing.

- [ ] **Step 3: Create the `Render` struct**

`lib/image_pipe/plan/render.ex`:

```elixir
defmodule ImagePipe.Plan.Render do
  @moduledoc """
  Selects a non-image terminal renderer for a plan. `renderer` is a neutral tag a
  parser emits (e.g. `:imgproxy_info`); the `Output` layer maps it to a renderer
  module. `params` carries renderer-specific options. A plain `:image_encode` on
  `Plan.render` (the default) means "encode an image" — no `Render` struct.
  """

  @enforce_keys [:renderer]
  defstruct @enforce_keys ++ [params: %{}]

  @type t :: %__MODULE__{
          renderer: atom(),
          params: map()
        }
end
```

- [ ] **Step 4: Add the `render` field to `Plan` and validate it**

In `lib/image_pipe/plan.ex`:

Add to `defstruct` defaults (after `auto_rotate: false`):

```elixir
                auto_rotate: false,
                render: :image_encode
```

Add to the `@type t` map:

```elixir
          auto_rotate: boolean(),
          render: :image_encode | ImagePipe.Plan.Render.t()
```

Add `Render` to the `alias` block and the `exports:` list (add `Render` near `Response`).

Add to the `@type shape_error()` union:

```elixir
          | {:invalid_render_plan, term()}
```

Add a `validate_render` call to the `validate_shape/1` `with` chain (after `validate_auto_rotate`):

```elixir
         :ok <- validate_auto_rotate(plan.auto_rotate),
         :ok <- validate_render(plan.render) do
```

Add the clauses near the other `validate_*` private functions:

```elixir
  defp validate_render(:image_encode), do: :ok
  defp validate_render(%ImagePipe.Plan.Render{renderer: r}) when is_atom(r), do: :ok
  defp validate_render(render), do: {:error, {:invalid_render_plan, render}}
```

- [ ] **Step 5: Update the architecture boundary export assertion**

Add `Render` to the `ImagePipe.Plan` exports list in `test/image_pipe/architecture_boundary_test.exs`.

- [ ] **Step 6: Run tests**

Run: `mise exec -- mix test test/image_pipe/plan/render_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/plan/render.ex test/image_pipe/plan/render_test.exs lib/image_pipe/plan.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(plan): add Plan.render selector with validate_shape (#252)"
```

---

## Task 3: `Plan.RenderContext` struct

**Files:**
- Create: `lib/image_pipe/plan/render_context.ex`
- Create: `test/image_pipe/plan/render_context_test.exs`
- Modify: `lib/image_pipe/plan.ex` (exports), `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

`test/image_pipe/plan/render_context_test.exs`:

```elixir
defmodule ImagePipe.Plan.RenderContextTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo

  test "carries a SourceInfo" do
    info = %SourceInfo{format: :jpeg, width: 4, height: 3, orientation: 1}
    ctx = %RenderContext{info: info}
    assert ctx.info == info
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/render_context_test.exs`
Expected: FAIL — `ImagePipe.Plan.RenderContext` undefined.

- [ ] **Step 3: Create the struct**

`lib/image_pipe/plan/render_context.ex`:

```elixir
defmodule ImagePipe.Plan.RenderContext do
  @moduledoc """
  Inputs a renderer formats over, assembled by the request layer. Phase 1 carries
  only header facts (`info`). Future depths (`:pixels`, `:detector`,
  `:source_bytes`) add fields populated by their satisfier stages; a future
  `image` field is a plain `Vix.Vips.Image.t()` (never a `Transform.State`), so
  renderers under `Output.*` never depend on `Transform.*`.
  """

  @enforce_keys [:info]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          info: ImagePipe.Plan.SourceInfo.t()
        }
end
```

- [ ] **Step 4: Export + boundary test**

Add `RenderContext` to `Plan`'s `exports:` and to the architecture boundary test's `ImagePipe.Plan` exports list.

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/plan/render_context_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/render_context.ex test/image_pipe/plan/render_context_test.exs lib/image_pipe/plan.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(plan): add RenderContext (#252)"
```

---

## Task 4: `Output.Render` behaviour + dispatch

**Files:**
- Create: `lib/image_pipe/output/render.ex`
- Create: `test/image_pipe/output/render_test.exs`
- Modify: `lib/image_pipe/output.ex` (exports), `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

`test/image_pipe/output/render_test.exs`:

```elixir
defmodule ImagePipe.Output.RenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Render

  test "resolves a known renderer tag to its module" do
    assert Render.module(:imgproxy_info) == ImagePipe.Output.Render.ImgproxyInfo
  end

  test "returns an error tuple for an unknown tag" do
    assert {:error, {:unknown_renderer, :nope}} = Render.fetch_module(:nope)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/render_test.exs`
Expected: FAIL — `ImagePipe.Output.Render` undefined.

- [ ] **Step 3: Create the behaviour + dispatch**

`lib/image_pipe/output/render.ex`:

```elixir
defmodule ImagePipe.Output.Render do
  @moduledoc """
  Behaviour for non-image terminal renderers. A renderer declares which expensive
  pipeline stages it needs (`requires/1`) and formats a complete response body
  (`render/3`) over a neutral `Plan.RenderContext`. Phase 1 inhabits only the
  `:header` need.
  """

  alias ImagePipe.Plan.RenderContext

  @type need :: :header
  @type body :: {content_type :: String.t(), iodata()}

  @callback requires(params :: map()) :: [need()]
  @callback render(RenderContext.t(), params :: map(), keyword()) ::
              {:ok, body()} | {:error, term()}

  @renderers %{imgproxy_info: ImagePipe.Output.Render.ImgproxyInfo}

  @spec module(atom()) :: module() | nil
  def module(tag), do: Map.get(@renderers, tag)

  @spec fetch_module(atom()) :: {:ok, module()} | {:error, {:unknown_renderer, atom()}}
  def fetch_module(tag) do
    case module(tag) do
      nil -> {:error, {:unknown_renderer, tag}}
      mod -> {:ok, mod}
    end
  end
end
```

- [ ] **Step 4: Export + boundary test**

In `lib/image_pipe/output.ex` add `Render` to `exports:`. Add `Render` to the architecture boundary test's `ImagePipe.Output` exports list.

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/output/render_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: FAIL — `ImagePipe.Output.Render.ImgproxyInfo` referenced in `@renderers` does not exist yet. (This is expected; Task 5 creates it. To keep the commit green, temporarily set `@renderers %{}` and skip the `:imgproxy_info` assertion, OR implement Task 5 first.) **Recommended:** implement Task 5 before running Task 4 Step 5; do Task 4 Steps 1–4, then Task 5, then return to run both test files together.

- [ ] **Step 6: Commit** (after Task 5 makes it green)

```bash
git add lib/image_pipe/output/render.ex test/image_pipe/output/render_test.exs lib/image_pipe/output.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(output): add Output.Render behaviour + dispatch (#252)"
```

---

## Task 5: `Output.Render.ImgproxyInfo` renderer (pure)

**Files:**
- Create: `lib/image_pipe/output/render/imgproxy_info.ex`
- Create: `test/image_pipe/output/render/imgproxy_info_test.exs`

This renderer owns the imgproxy wire spellings (from imgproxy `imagetype/defs.go`). It depends only on `Plan.*` and stdlib JSON.

- [ ] **Step 1: Write the failing test**

`test/image_pipe/output/render/imgproxy_info_test.exs`:

```elixir
defmodule ImagePipe.Output.Render.ImgproxyInfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Render.ImgproxyInfo
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo

  defp render(info) do
    {:ok, {content_type, body}} =
      ImgproxyInfo.render(%RenderContext{info: info}, %{}, [])

    {content_type, JSON.decode!(IO.iodata_to_binary(body))}
  end

  test "requires only :header" do
    assert ImgproxyInfo.requires(%{}) == [:header]
  end

  test "renders the default field set for a jpeg" do
    info = %SourceInfo{format: :jpeg, width: 1200, height: 800, orientation: 1, byte_size: 9876}
    {content_type, json} = render(info)

    assert content_type == "application/json"
    assert json["format"] == "jpeg"
    assert json["mime_type"] == "image/jpeg"
    assert json["width"] == 1200
    assert json["height"] == 800
    assert json["orientation"] == 1
    assert json["size"] == 9876
  end

  test "reports imgproxy spellings for HEIC and JXL sources" do
    {_ct, heic} =
      render(%SourceInfo{format: :heif, width: 10, height: 10, orientation: 1})

    assert heic["format"] == "heic"
    assert heic["mime_type"] == "image/heif"

    {_ct, jxl} =
      render(%SourceInfo{format: :jpeg_xl, width: 10, height: 10, orientation: 1})

    assert jxl["format"] == "jxl"
    assert jxl["mime_type"] == "image/jxl"
  end

  test "swaps width/height for EXIF orientations 5-8" do
    info = %SourceInfo{format: :jpeg, width: 4000, height: 3000, orientation: 6}
    {_ct, json} = render(info)
    assert json["width"] == 3000
    assert json["height"] == 4000
  end

  test "omits size when byte_size is nil" do
    info = %SourceInfo{format: :png, width: 5, height: 5, orientation: 1, byte_size: nil}
    {_ct, json} = render(info)
    refute Map.has_key?(json, "size")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/render/imgproxy_info_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the renderer**

`lib/image_pipe/output/render/imgproxy_info.ex`:

```elixir
defmodule ImagePipe.Output.Render.ImgproxyInfo do
  @moduledoc """
  Serializes `Plan.SourceInfo` into imgproxy's `/info` JSON (Phase-1 header field
  set: format, mime_type, width, height, orientation, size). Owns the imgproxy
  wire spellings (per imgproxy `imagetype/defs.go`): note imgproxy spells HEIC
  "heic"/image/heif and JPEG-XL "jxl"/image/jxl, and has no "heif"/"jpeg2000"
  types. `width`/`height` are orientation-adjusted (swapped for EXIF 5-8).
  """

  @behaviour ImagePipe.Output.Render

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo

  # source atom => {imgproxy format string, imgproxy mime}
  @wire %{
    jpeg: {"jpeg", "image/jpeg"},
    png: {"png", "image/png"},
    webp: {"webp", "image/webp"},
    avif: {"avif", "image/avif"},
    heif: {"heic", "image/heif"},
    tiff: {"tiff", "image/tiff"},
    jpeg_xl: {"jxl", "image/jxl"},
    gif: {"gif", "image/gif"}
  }

  @impl true
  def requires(_params), do: [:header]

  @impl true
  def render(%RenderContext{info: %SourceInfo{} = info}, _params, _opts) do
    {format, mime} = wire(info.format)
    {w, h} = display_dimensions(info.width, info.height, info.orientation)

    doc =
      %{
        "format" => format,
        "mime_type" => mime,
        "width" => w,
        "height" => h,
        "orientation" => info.orientation
      }
      |> maybe_put("size", info.byte_size)

    {:ok, {"application/json", JSON.encode_to_iodata!(doc)}}
  end

  defp wire(format), do: Map.get(@wire, format, {Atom.to_string(format), "application/octet-stream"})

  # EXIF orientations 5-8 are quarter-turns: reported width/height are swapped.
  defp display_dimensions(w, h, orientation) when orientation in [5, 6, 7, 8], do: {h, w}
  defp display_dimensions(w, h, _orientation), do: {w, h}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

> **Note on JSON:** this uses the stdlib `JSON` module (Elixir 1.18+). If the repo
> targets an older Elixir, substitute `Jason` (check `mix.exs` deps first and match
> whichever the codebase already uses for JSON).

- [ ] **Step 4: Run the renderer tests**

Run: `mise exec -- mix test test/image_pipe/output/render/imgproxy_info_test.exs`
Expected: PASS.

- [ ] **Step 5: Now run Task 4's tests (dispatch resolves to this module)**

Run: `mise exec -- mix test test/image_pipe/output/render_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/output/render/imgproxy_info.ex test/image_pipe/output/render/imgproxy_info_test.exs lib/image_pipe/output/render.ex test/image_pipe/output/render_test.exs lib/image_pipe/output.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(output): add ImgproxyInfo renderer + wire-spelling table (#252)"
```

---

## Task 6: Empty-pipeline gate for render plans

`Transform.validate_prefetch_safe_plan/1` (`lib/image_pipe/transform.ex`) rejects an empty pipeline. Allow it when `plan.render` is a render selector (plan-shape check — no `Output.Render` knowledge in `Transform`).

**Files:**
- Modify: `lib/image_pipe/transform.ex` (the `validate_prefetch_safe_plan/1` function, ~line 72)
- Create: `test/image_pipe/transform/render_prefetch_test.exs`

- [ ] **Step 1: Read the current function**

Read `lib/image_pipe/transform.ex` around `validate_prefetch_safe_plan/1`. It calls `Plan.validated_pipelines(plan)` (which returns `{:error, :empty_pipeline_plan}` for `pipelines: []`).

- [ ] **Step 2: Write the failing test**

`test/image_pipe/transform/render_prefetch_test.exs`:

```elixir
defmodule ImagePipe.Transform.RenderPrefetchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Render
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform

  defp plan(extra) do
    struct!(
      %Plan{
        source: %Source.Path{segments: ["a.jpg"]},
        pipelines: [],
        output: %Output{mode: :automatic}
      },
      extra
    )
  end

  test "a render plan with an empty pipeline is prefetch-safe" do
    p = plan(render: %Render{renderer: :imgproxy_info, params: %{}})
    assert {:ok, _} = Transform.validate_prefetch_safe_plan(p)
  end

  test "an image-encode plan with an empty pipeline is still rejected" do
    p = plan(render: :image_encode)
    assert {:error, :empty_pipeline_plan} = Transform.validate_prefetch_safe_plan(p)
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/render_prefetch_test.exs`
Expected: FAIL — render plan currently rejected with `:empty_pipeline_plan`.

- [ ] **Step 4: Add the plan-shape carve-out**

In `lib/image_pipe/transform.ex`, at the top of `validate_prefetch_safe_plan/1`, short-circuit render plans before the pipeline check:

```elixir
  def validate_prefetch_safe_plan(%Plan{render: render} = plan) when render != :image_encode do
    {:ok, plan}
  end

  def validate_prefetch_safe_plan(%Plan{} = plan) do
    # ... existing body unchanged ...
  end
```

(Keep the original body in the second clause; only add the first clause.)

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/transform/render_prefetch_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform.ex test/image_pipe/transform/render_prefetch_test.exs
git commit -m "feat(transform): allow empty pipeline for render plans (#252)"
```

---

## Task 7: Fold render selector into the cache key

`Cache.Key.plan_material/2` (`lib/image_pipe/cache/key.ex:62`) emits a static `representation: [version: …]`. Make it depend on `plan.render` so `/info` and the image render of the same source get distinct keys and ETags.

**Files:**
- Modify: `lib/image_pipe/cache/key.ex`
- Modify/Create: `test/image_pipe/cache/key_test.exs` (add cases)

- [ ] **Step 1: Write the failing test**

Add to the cache key test (create the file if a focused one doesn't exist):

```elixir
defmodule ImagePipe.Cache.KeyRenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Key
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Render
  alias ImagePipe.Plan.Source

  defp material(render) do
    plan =
      struct!(
        %Plan{
          source: %Source.Path{segments: ["a.jpg"]},
          pipelines: [%Plan.Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        },
        render: render
      )

    {:ok, material} = Key.plan_material(plan, [])
    material[:representation]
  end

  test "render selector changes the representation key data" do
    image = material(:image_encode)
    info = material(%Render{renderer: :imgproxy_info, params: %{}})
    refute image == info
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/cache/key_render_test.exs`
Expected: FAIL — both produce the same static representation data.

- [ ] **Step 3: Make `representation_data` depend on `plan.render`**

In `lib/image_pipe/cache/key.ex`, change the call site (line 72) and the helper (line 89):

```elixir
       representation: representation_data(plan.render),
```

```elixir
  defp representation_data(:image_encode), do: [version: @representation_version, render: :image_encode]

  defp representation_data(%ImagePipe.Plan.Render{renderer: renderer, params: params}),
    do: [version: @representation_version, render: renderer, params: params]
```

(Ensure `ImagePipe.Plan.Render` is reachable — `Cache` already deps on `Plan`.)

- [ ] **Step 4: Run tests**

Run: `mise exec -- mix test test/image_pipe/cache/key_render_test.exs test/image_pipe/cache`
Expected: PASS. (If existing cache-key snapshot tests assert exact `representation` bytes, update them in place — greenfield, no data-version bump needed.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/image_pipe/cache/key_render_test.exs
git commit -m "feat(cache): fold render selector into the cache key (#252)"
```

---

## Task 8: `Response.Json` complete-body sender helper

**Files:**
- Create: `lib/image_pipe/response/json.ex`
- Create: `test/image_pipe/response/json_test.exs`
- Modify: `lib/image_pipe/response.ex` (exports), `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write the failing test**

`test/image_pipe/response/json_test.exs`:

```elixir
defmodule ImagePipe.Response.JsonTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Response.Json

  test "sends a complete body with the given content type and 200" do
    conn = conn(:get, "/info/x")
    sent = Json.send(conn, "application/json", ~s({"format":"jpeg"}))

    assert sent.status == 200
    assert sent.resp_body == ~s({"format":"jpeg"})
    assert get_resp_header(sent, "content-type") == ["application/json; charset=utf-8"]
    # No image content-disposition is attached.
    assert get_resp_header(sent, "content-disposition") == []
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/response/json_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the helper**

`lib/image_pipe/response/json.ex`:

```elixir
defmodule ImagePipe.Response.Json do
  @moduledoc """
  Sends a complete-body, non-image response (content-type + iodata). Used by
  request-layer renders. Does NOT attach image `content-disposition`.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  @spec send(Plug.Conn.t(), String.t(), iodata()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, content_type, body) do
    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end
end
```

- [ ] **Step 4: Export + boundary test**

Add `Json` to `lib/image_pipe/response.ex` `exports:` and to the architecture boundary test's `ImagePipe.Response` exports list.

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/response/json_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/json.ex test/image_pipe/response/json_test.exs lib/image_pipe/response.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(response): add complete-body JSON sender helper (#252)"
```

---

## Task 9: `RenderRunner` — request-layer render orchestration

Builds the `SourceInfo` from a decode + best-effort byte size, builds the context, calls the renderer.

**Files:**
- Create: `lib/image_pipe/request/render_runner.ex`
- Create: `test/image_pipe/request/render_runner_test.exs`

`byte_size` is best-effort: for a `Source.Resolved` whose fetch yields a `path`, `File.stat`; otherwise `nil`. The orientation integer is read from the decoded image header.

- [ ] **Step 1: Read the seams**

- `ImagePipe.Request.Processor.fetch_decode_validate_source_with_source_format/3` returns `{:ok, decoded}` where `decoded.image` is a `Vix.Vips.Image`, `decoded.source_format` is the atom, `decoded.original_dims` is `{w, h}` (stored).
- The orientation header: `Vix.Vips.Image.header_value(image, "orientation")` returns `{:ok, int}` or `{:error, _}` (default 1). (See `PlanExecutor.exif_orientation/1` for the pattern.)

- [ ] **Step 2: Write the failing test**

`test/image_pipe/request/render_runner_test.exs` — unit-test the pure `build_source_info/2` helper (decode is integration-tested at the wire level in Task 12):

```elixir
defmodule ImagePipe.Request.RenderRunnerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Request.RenderRunner

  test "build_source_info maps decoded facts + byte_size, orientation default 1" do
    {:ok, image} = Image.open("test/support/.../tiny.jpg")
    decoded = %{image: image, source_format: :jpeg, original_dims: {12, 8}}

    info = RenderRunner.build_source_info(decoded, 4096)

    assert info.format == :jpeg
    assert info.width == 12
    assert info.height == 8
    assert info.orientation in 1..8
    assert info.byte_size == 4096
  end
end
```

(Use any tiny committed JPEG fixture; search `test/support` for an existing one and fix the path.)

- [ ] **Step 3: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/request/render_runner_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 4: Implement `RenderRunner`**

`lib/image_pipe/request/render_runner.ex`:

```elixir
defmodule ImagePipe.Request.RenderRunner do
  @moduledoc """
  Request-layer orchestration for non-image renders. Decodes the source to the
  needed depth (Phase 1: header only), builds a neutral `RenderContext`, and calls
  the selected `Output.Render` renderer, returning a complete body. Never starts a
  `SourceSession`/`Producer` and never constructs `%Output.Resolved{}`.
  """

  alias ImagePipe.Output.Render
  alias ImagePipe.Plan
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Request.Processor
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias Vix.Vips.Image, as: VipsImage

  @spec run(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, {content_type :: String.t(), body :: iodata()}} | {:error, term()}
  def run(%Plan{render: %Plan.Render{renderer: tag, params: params}} = plan, resolved_source, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:render], %{representation: :json}, fn ->
      result = do_run(plan, resolved_source, params, tag, opts)
      {result, render_stop_metadata(result)}
    end)
  end

  defp do_run(plan, resolved_source, params, tag, opts) do
    with {:ok, module} <- Render.fetch_module(tag),
         {:ok, decoded} <-
           Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
      info = build_source_info(decoded, byte_size_of(resolved_source, opts))
      module.render(%RenderContext{info: info}, params, opts)
    end
  end

  @spec build_source_info(map(), non_neg_integer() | nil) :: SourceInfo.t()
  def build_source_info(decoded, byte_size) do
    {width, height} = decoded.original_dims

    %SourceInfo{
      format: decoded.source_format,
      width: width,
      height: height,
      orientation: orientation(decoded.image),
      byte_size: byte_size
    }
  end

  defp orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _ -> 1
    end
  end

  # Best-effort: only a filesystem-backed source gives a cheap byte size in Phase 1.
  defp byte_size_of(%Source.Resolved{} = _resolved, _opts), do: nil

  defp render_stop_metadata({:ok, {content_type, _body}}),
    do: %{result: :ok, content_type: content_type}

  defp render_stop_metadata({:error, reason}),
    do: %{result: :render_error, error: inspect(reason)}
end
```

> **byte_size note:** Phase 1 returns `nil` (omit `size`) unless a later refinement
> threads the fetched `path`/`Content-Length`. This keeps the documented
> "omit-when-absent" behavior and avoids a stream download. Do not download to
> compute size.

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/request/render_runner_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/request/render_runner.ex test/image_pipe/request/render_runner_test.exs
git commit -m "feat(request): add RenderRunner request-layer render path (#252)"
```

---

## Task 10: Wire `{:rendered}` through Runner, Sender, and the plug

**Files:**
- Modify: `lib/image_pipe/request/runner.ex` (`delivery()` type + branch on `plan.render`)
- Modify: `lib/image_pipe/response/sender.ex` (`delivery()` type + `send_result/3` clause)
- Verify: `lib/image_pipe/plug.ex` `request_result*/1` handle `{:ok, {:rendered, ...}}`

- [ ] **Step 1: Branch `Runner.run/5` on the render selector**

In `lib/image_pipe/request/runner.ex`:

Add `{:rendered, ...}` to `@type delivery()` (lines 22-24):

```elixir
  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t()}
          | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
          | {:rendered, String.t(), iodata(), CacheHeaders.t()}
```

At the top of `run/5`, before `run_with_cache_config`, branch on the render selector:

```elixir
  def run(conn, %Plan{render: %Plan.Render{}} = plan, %Source.Resolved{} = resolved_source,
          %CacheHeaders{} = prepared_http_cache, opts) do
    case ImagePipe.Request.RenderRunner.run(plan, resolved_source, opts) do
      {:ok, {content_type, body}} ->
        {:ok, {:rendered, content_type, body, prepared_http_cache}}

      {:error, reason} ->
        {:error, {:processing, normalize_render_error(reason), []}}
    end
  end

  def run(conn, %Plan{} = plan, %Source.Resolved{} = resolved_source,
          %CacheHeaders{} = prepared_http_cache, opts) do
    run_with_cache_config(conn, plan, resolved_source, prepared_http_cache, opts)
  end
```

Add the alias `alias ImagePipe.Request.RenderRunner` and a private:

```elixir
  defp normalize_render_error(reason), do: {:render, reason}
```

- [ ] **Step 2: Add the Sender clause**

In `lib/image_pipe/response/sender.ex`:

Add `{:rendered, ...}` to its `@type delivery()` (lines 26-28, keep in sync with Runner).

Add a `send_result/3` clause (near the other `{:ok, ...}` clauses):

```elixir
  def send_result(
        %Plug.Conn{} = conn,
        {:ok, {:rendered, content_type, body, %CacheHeaders{} = prepared}},
        _opts
      ) do
    conn
    |> apply_render_cache_headers(prepared)
    |> ImagePipe.Response.Json.send(content_type, body)
  end
```

Add a private to apply only the prepared cache/representation headers (reuse the existing header-merge helpers; a render has no `%Resolved{}`):

```elixir
  defp apply_render_cache_headers(%Plug.Conn{} = conn, %CacheHeaders{} = prepared) do
    (prepared.headers ++ prepared.representation_headers)
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
  end
```

Add `alias ImagePipe.Response.Json` if not present. Add a `handle_processing_error/3` clause for the render error tag → 500:

```elixir
  defp handle_processing_error(conn, {:render, reason}, response_headers) do
    Logger.error("render_error: #{inspect(reason)}")
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error rendering response")
  end
```

- [ ] **Step 3: Verify the plug result mapping**

In `lib/image_pipe/plug.ex`, confirm `request_result({:ok, _delivery})` → `:ok` and `request_result_metadata({:ok, _delivery})` → `%{result: :ok}` already match `{:ok, {:rendered, ...}}` generically (they pattern-match `{:ok, _delivery}` — no change needed). If a `%Vary: Accept%` is added anywhere for `:automatic` output, ensure the imgproxy info plan's `Output.mode` is **not** `:automatic` (set in Task 11).

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. (Full behavior is exercised by the Task 12 wire test.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/response/sender.ex
git commit -m "feat(request): deliver {:rendered} complete bodies via Sender (#252)"
```

---

## Task 11: imgproxy `/info` dispatch in the parser

Recognize a leading `/info` path segment, peel it, verify the signature on the remainder, parse source with **no output-extension split**, honor `expires`/`cachebuster`, ignore display options, and emit a render plan with `pipelines: []` and a non-`:automatic` `Output`.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy.ex` (`parse_request/2`, a new info branch)
- Modify: `lib/image_pipe/parser/imgproxy/path.ex` (info-prefix recognition + no-extension source parse)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (emit a render plan)
- Create: `test/image_pipe/parser/imgproxy/info_dispatch_test.exs`

- [ ] **Step 1: Write the failing parser test**

`test/image_pipe/parser/imgproxy/info_dispatch_test.exs`:

```elixir
defmodule ImagePipe.Parser.Imgproxy.InfoDispatchTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Render

  defp opts, do: [imgproxy: []]  # signature disabled (unsafe)

  test "parses an unsafe /info URL into an imgproxy_info render plan" do
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")
    assert {:ok, %Plan{render: %Render{renderer: :imgproxy_info}, pipelines: []} = plan} =
             Imgproxy.parse(conn, opts())

    refute plan.output.mode == :automatic
  end

  test "the /info prefix is not part of the signed path (verifies on the remainder)" do
    # With signatures disabled, "unsafe" is accepted; this asserts the peel happened
    # (otherwise "info" would be treated as the signature and rejected).
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")
    assert {:ok, %Plan{}} = Imgproxy.parse(conn, opts())
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/info_dispatch_test.exs`
Expected: FAIL — `/info` treated as the signature; no render plan emitted.

- [ ] **Step 3: Recognize + peel `/info` in `parse_request/2`**

In `lib/image_pipe/parser/imgproxy.ex`, add an info-aware path before `Path.extract`. Add a `Path.extract_endpoint/1` that returns `{:info, conn_for_remainder}` or `:image`, then branch:

```elixir
  defp parse_request(%Plug.Conn{} = conn, opts) do
    case Path.split_endpoint(conn) do
      {:info, info_conn} -> parse_info_request(info_conn, opts)
      :image -> parse_image_request(conn, opts)
    end
  end
```

Rename the existing `parse_request/2` body to `parse_image_request/2` (unchanged).

Add `parse_info_request/2` (mirrors the image path but builds an info `ParsedRequest` and skips no source-extension):

```elixir
  defp parse_info_request(%Plug.Conn{} = conn, opts) do
    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- verify_signature(signature, signed_path, opts),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <-
           Options.parse(option_segments, preset_config(Keyword.get(opts, :imgproxy, [])),
             request_defaults(Keyword.get(opts, :imgproxy, []))),
         {:ok, source_path, _ignored_format} <-
           Path.parse_source_no_extension(source_kind, raw_source_path, source_parsing_config(opts)) do
      info_parsed_request(signature, source_path, source_kind, request_options)
    end
  end
```

> The exact `parsed_request/4` and `info_parsed_request/4` shapes depend on the
> existing `ParsedRequest`. Read `parser/imgproxy/parsed_request.ex`; add a flag
> (e.g. `info?: true`) or a distinct struct so `PlanBuilder.to_plan/2` can branch.
> Keep `expires`/`cachebuster` flowing through `request_options` (they ride the
> existing `policy`/`cache` fields, so `PlanBuilder.expires_plan/cachebuster_plan`
> still enforce `expires → {:error, {:expired_request, _}}`).

- [ ] **Step 4: Add `Path.split_endpoint/1` + `parse_source_no_extension`**

In `lib/image_pipe/parser/imgproxy/path.ex`:

```elixir
  def split_endpoint(%Plug.Conn{} = conn) do
    case parser_request_path(conn) do
      "/info/" <> rest -> {:info, %{conn | request_path: "/" <> rest, path_info: nil}}
      "/info" -> {:info, %{conn | request_path: "/"}}
      _ -> :image
    end
  end
```

> Adjust to however `parser_request_path/1` derives the path (it may read
> `path_info`/`script_name` rather than `request_path`). Read it and peel the
> leading `"info"` segment from whichever source it uses — the goal is that
> `Path.extract/1` then sees `signature` as segment 1 of the remainder.

Add a no-extension source parser that reuses the existing decoders but never splits on `@`/`.` for an output format:

```elixir
  def parse_source_no_extension(:plain, source_path, _opts) do
    decode_source_path(Enum.join(source_path, "/"), nil)
  end

  def parse_source_no_extension(:encoded, source_path, opts) do
    source_path
    |> encoded_source_value(opts)
    |> decode_encoded_source(nil)
  end

  def parse_source_no_extension(:encrypted, source_path, opts) do
    parse_encrypted_source(source_path, opts)  # encrypted payloads carry no output ext
  end
```

> Verify the helper names (`decode_source_path/2`, `encoded_source_value/2`,
> `decode_encoded_source/2`) against the file and make them callable (they are
> currently private — promote the minimum needed, or add thin public wrappers).

- [ ] **Step 5: Emit a render plan in `PlanBuilder`**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add an info branch to `to_plan/2` that produces a plan with `pipelines: []`, a non-`:automatic` `Output`, and the render selector:

```elixir
  def to_plan(%ParsedRequest{info?: true} = request, opts) do
    with {:ok, source} <- source_plan(request.source_kind, request.source_path, opts),
         {:ok, expires} <- expires_plan(request.policy, opts),
         {:ok, cachebuster} <- cachebuster_plan(request.cache) do
      {:ok,
       %Plan{
         source: source,
         auto_rotate: false,
         pipelines: [],
         output: %Output{mode: {:explicit, :jpeg}},
         expires: expires,
         cachebuster: cachebuster,
         response: %Response{},
         render: %ImagePipe.Plan.Render{renderer: :imgproxy_info, params: %{}}
       }}
    end
  end
```

> `output: %Output{mode: {:explicit, :jpeg}}` is a non-`:automatic` placeholder so
> no `Vary: Accept` is emitted (the render ignores `output` entirely). Confirm
> `ParsedRequest` carries `info?`, `source_kind`, `source_path`, `policy`, `cache`;
> add `info?: false` default if you introduce the flag.

- [ ] **Step 6: Run the parser test**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/info_dispatch_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/imgproxy.ex lib/image_pipe/parser/imgproxy/path.ex lib/image_pipe/parser/imgproxy/plan_builder.ex lib/image_pipe/parser/imgproxy/parsed_request.ex test/image_pipe/parser/imgproxy/info_dispatch_test.exs
git commit -m "feat(parser): dispatch imgproxy /info to a render plan (#252)"
```

---

## Task 12: Wire-level `/info` tests (end-to-end)

**Files:**
- Create: `test/image_pipe/imgproxy_info_wire_test.exs`

Find an existing imgproxy wire test (e.g. `test/image_pipe/imgproxy_*_test.exs`) and copy its `ImagePipe.call/2` setup (mount opts, a `Source.File` or stub source, a committed image fixture). Match that style.

- [ ] **Step 1: Write the wire tests**

```elixir
defmodule ImagePipe.ImgproxyInfoWireTest do
  use ExUnit.Case, async: true
  import Plug.Test

  # Copy the opts/source-config + fixture setup from an existing imgproxy wire test.
  defp call(path), do: ImagePipe.call(conn(:get, path), mount_opts())

  test "signed /info returns 200 application/json with the header field set" do
    conn = call("/info/unsafe/plain/" <> fixture_url("landscape.jpg"))
    assert conn.status == 200
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")

    json = JSON.decode!(conn.resp_body)
    assert json["format"] == "jpeg"
    assert json["mime_type"] == "image/jpeg"
    assert is_integer(json["width"]) and json["width"] > 0
    assert is_integer(json["height"]) and json["height"] > 0
    assert json["orientation"] in 1..8
  end

  test "EXIF orientation 6 source reports swapped width/height" do
    conn = call("/info/unsafe/plain/" <> fixture_url("portrait_exif6.jpg"))
    json = JSON.decode!(conn.resp_body)
    # portrait stored landscape; orientation 6 => width < height after swap
    assert json["orientation"] == 6
    assert json["height"] > json["width"]
  end

  test "a bad signature returns before any source fetch" do
    # With signatures ENABLED in mount_opts_signed(), a wrong sig must 403 and not fetch.
    conn = ImagePipe.call(conn(:get, "/info/badsig/plain/" <> fixture_url("landscape.jpg")), mount_opts_signed())
    assert conn.status == 403
  end

  test "no Vary: Accept on the JSON response" do
    conn = call("/info/unsafe/plain/" <> fixture_url("landscape.jpg"))
    assert Plug.Conn.get_resp_header(conn, "vary") == [] or
             not Enum.any?(Plug.Conn.get_resp_header(conn, "vary"), &String.contains?(&1, "accept"))
  end

  test "size is omitted when the source carries no cheap byte size" do
    conn = call("/info/unsafe/plain/" <> fixture_url("landscape.jpg"))
    json = JSON.decode!(conn.resp_body)
    refute Map.has_key?(json, "size")
  end

  test "an expired /info URL returns 404" do
    # exp:<past-unix-ts> as an info option; mount_opts with an injected clock if the
    # codebase supports one (see PlanBuilder now_unix_seconds/1 :clock opt). Match the
    # existing imgproxy expires test for the exact option spelling + clock injection.
    conn = call("/info/unsafe/exp:1/plain/" <> fixture_url("landscape.jpg"))
    assert conn.status == 404
  end

  test "a non-image source returns a clean 415/422 (not a crash)" do
    conn = call("/info/unsafe/plain/" <> fixture_url("not_an_image.txt"))
    assert conn.status in [415, 422]
  end
end
```

Add a HEIC test only if a HEIC fixture exists (`format == "heic"`, `mime_type == "image/heif"`); otherwise rely on the Task 5 unit test for spelling and note the gap. For the expired and non-image cases, reuse fixtures/clock-injection from the existing imgproxy wire tests (search `test/image_pipe/imgproxy_*` for an `exp:`/expires example and a non-image fixture).

- [ ] **Step 2: Run**

Run: `mise exec -- mix test test/image_pipe/imgproxy_info_wire_test.exs`
Expected: PASS. Debug failures against `mix test --failed`.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_info_wire_test.exs
git commit -m "test(imgproxy-info): wire-level /info contract (#252)"
```

---

## Task 13: `[:render]` telemetry in the default Logger + docs

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Modify: `docs/telemetry.md`
- Modify/Create: `test/image_pipe/telemetry/logger_test.exs` (add a case)

- [ ] **Step 1: Read the Logger**

Read `lib/image_pipe/telemetry/logger.ex`: note `@group_span_events` (span subscriptions) and the `message/3` clauses. The `[:render]` span is emitted by `RenderRunner` (Task 9) as `[:request, :render]`-style via `Telemetry.span(opts, [:render], …)`. Confirm the actual event prefix the codebase uses (check how `[:encode]`/`[:deliver]` appear in `@group_span_events`) and use the matching shape for `[:render]`.

- [ ] **Step 2: Write/extend the failing test**

Add to `test/image_pipe/telemetry/logger_test.exs` a case that attaches the default logger, emits a `[:render]` stop event (or drives a `/info` request), and asserts the log line mentions `render` and the outcome (`:ok`). Match the existing logger-test pattern in that file.

- [ ] **Step 3: Subscribe + render the event**

Add the `[:render]` span events to `@group_span_events`. Add a `message/3` clause that surfaces the outcome (and `representation` / `content_type` metadata), placed **before** the generic fallback clause:

```elixir
  defp message([:render, :stop], measurements, %{result: result} = meta) do
    "render #{meta[:representation]} #{outcome(meta)} (#{duration_ms(measurements)}ms)"
  end
```

(Match the file's actual helper names — `outcome/1`, `duration_ms/1` may be named differently; mirror an existing span clause.)

- [ ] **Step 4: Update `docs/telemetry.md`**

Add the `[:render]` span (start/stop/exception), its measurements, and metadata keys (`representation`, `result`, `content_type`) to the events table; note the default Logger renders it.

- [ ] **Step 5: Run tests**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex docs/telemetry.md test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(telemetry): [:render] span + default Logger coverage (#252)"
```

---

## Task 14: imgproxy support-matrix update

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Remove stale statements**

Search the matrix for lines stating ImagePipe has no info endpoint (e.g. "ImagePipe doesn't currently expose Imgproxy info endpoints"). Remove/replace them.

- [ ] **Step 2: Add the info surface rows**

Add an info-option table marking each field: **Supported** (`format`, `mime_type`, `width`, `height`, `orientation`, `size`); **Deferred** (`exif`, `iptc`, `xmp` — note default-ON); **Excluded** (`colorspace`, `bands`, `sample_format`, `alpha`, `pages_number` — default-OFF/slow); **Deferred** (all pixel/detector/raw-byte fields). Keep `IMGPROXY_INFO_PRESETS*` rows as Missing (option grammar deferred).

- [ ] **Step 3: Add the stage/order + behavioral divergence notes**

- **Stage/order:** `/info` runs in the request layer (no transform pipeline; empty pipeline); renders bypass the streaming encode/deliver path.
- **Behavioral divergences (Diverges):**
  1. Default `/info` response is a strict **subset** (omits default-ON `exif`/`iptc`/`xmp`).
  2. `format`/`mime_type` spellings (`heic`/`image/heif`, `jxl`/`image/jxl`, …) + HEIC↔AVIF loader-vs-magic-byte detection divergence.
  3. `size` omitted on length-less sources (imgproxy downloads to compute it).
  4. Non-image/video source errors (415/422) where imgproxy returns a format list.

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): info-endpoint support matrix + divergences (#252)"
```

---

## Task 15: Full gate + finalize

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass. Fix anything that fails.

- [ ] **Step 2: Rename the branch before pushing**

```bash
git branch -m feat/imgproxy-info-render
```

- [ ] **Step 3: (If touching `fiddle/`)** — not required for this change; the demo UI has no `/info` control. Skip `precommit:demo`.

---

## Notes for the implementer

- **Render plans never start `SourceSession`/`Producer`.** The whole render path is `Runner.run → RenderRunner.run → Processor.fetch_decode_* → renderer`. Do not route a render through `process_prepared_stream`.
- **`byte_size` is best-effort and Phase 1 returns `nil`** (omit `size`). Do not buffer the stream to compute it.
- **No info-option grammar in Phase 1.** The options segment is parsed only so the signed path reconstructs; display toggles are ignored; `expires`/`cachebuster` are honored via the existing planner policy.
- **Do not extend `ImagePipe.Format`** for `mime_type` — the imgproxy wire spellings live in `Output.Render.ImgproxyInfo`.
- **Do not write a synthetic `:pixels`-rejection test** — there is no `:pixels` renderer in Phase 1.
