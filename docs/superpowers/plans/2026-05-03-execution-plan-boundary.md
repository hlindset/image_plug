# Execution Plan Boundary Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate parser-specific request semantics from ImagePlug's product-neutral execution representation, and remove output encoding from the image transform chain.

**Architecture:** Move native/imgproxy parsing into parser-owned IR, then convert that IR to `ImagePlug.Plan` before anything reaches core runtime. A native URL parses into `ImagePlug.ParamParser.Native.ParsedRequest`, which owns source/output request data and one `ImagePlug.ParamParser.Native.PipelineRequest` per native pipeline. `ImagePlug.ParamParser.Native.PlanBuilder.to_plan/1` is the only adapter from native IR to core `ImagePlug.Plan`. `ImagePlug.Plan` owns source data, ordered image operation pipelines, and `ImagePlug.OutputPlan`; runtime negotiation resolves an output format without appending `Transform.Output` entries to image transform pipelines. Multiple pipelines are represented explicitly so imgproxy chained pipelines can materialize one pipeline's result before the next pipeline runs.

**Tech Stack:** Elixir, Plug, ExUnit, StreamData, Vix/Image, existing `ImagePlug.TransformChain`, `mise exec -- ...`.

---

## Discovery Inventory

Current request flow:

1. `ImagePlug.ParamParser.parse/1` returns `{:ok, %ImagePlug.ProcessingRequest{}} | {:error, reason}`.
2. `ImagePlug.call/2` calls `pipeline_planner.plan(request)` and expects `{:ok, TransformChain.t()}`.
3. `ImagePlug.call/2` builds `origin_identity(request, opts)` from `%ProcessingRequest{source_kind: :plain, source_path: path}`.
4. `RequestRunner.run/5` receives `conn`, `%ProcessingRequest{}`, `chain`, `origin_identity`, and opts.
5. `ResponseCache.lookup/4` and `Cache.lookup/4` build cache keys from `%ProcessingRequest{}` before origin fetch.
6. `OutputPolicy.from_request/3` derives explicit or automatic output from `%ProcessingRequest.format`.
7. Explicit output from the parser is appended by `PipelinePlanner.plan/1`.
8. Automatic output selected by `OutputPolicy` is appended by `RequestRunner` with `TransformChain.append_output/2`.
9. `Processor` executes `TransformChain` and returns `TransformState`.
10. `OutputEncoder` reads `TransformState.output` to encode memory or streaming output.

Current `ProcessingRequest` roles to split apart:

- Parser-native assignment state: signature, source kind/path, imgproxy aliases, later-assignment-wins fields, `@extension` output.
- Semantic validation input: dimensions, unsupported `:best`, `:auto`, `:fill_down`, `:sm`, extend and offsets.
- Transform planning input: geometry and focus mapping.
- Output intent input: `format == nil` means automatic/source output; atom means explicit output.
- Origin input: source kind/path.
- Cache-key input: source fields, processing fields, output intent.

Target split:

- Native parser IR:
  - `ImagePlug.ParamParser.Native.ParsedRequest`: whole native URL, source/output request data, ordered native pipeline requests.
  - `ImagePlug.ParamParser.Native.PipelineRequest`: normalized assignment state for exactly one native/imgproxy pipeline.
- Core execution contract:
  - `ImagePlug.Plan`: parser-neutral source, ordered materialized pipelines, output intent.

No module outside `ImagePlug.ParamParser.Native.*` should consume `ParsedRequest`, `PipelineRequest`, or the transitional `ProcessingRequest` module while it still exists.

Current `Transform.Output` coupling:

- `PipelinePlanner.plan/1` appends `{Transform.Output, %OutputParams{format: format}}`.
- `TransformChain.append_output/2` appends the same tuple for automatic negotiation.
- `Transform.Output.execute/2` writes `TransformState.output`.
- `TransformState` defaults `output: :auto`.
- `OutputEncoder.mime_type/1`, `memory_output/2`, and `limited_memory_output/3` use `state.output`.
- Tests asserting this behavior:
  - `test/image_plug/pipeline_planner_test.exs`: output-only chains and output-last assertions.
  - `test/image_plug/pipeline_planner_property_test.exs`: explicit output is always planned last.
  - `test/image_plug/processor_test.exs`: output transform sets `state.output`.
  - `test/image_plug/decode_planner_test.exs`: output-only chain and output-neutral access.
  - `test/image_plug/request_runner_test.exs`: explicit cache-hit setup passes output transform.
  - `test/image_plug/response_cache_test.exs` and `test/image_plug/output_encoder_test.exs`: encode from `TransformState.output`.

Current output/cache behavior to preserve:

- Explicit `format`, `f`, `ext`, and plain-source `@extension` bypass `Accept` and do not set `Vary`.
- `format:auto` is parser-invalid for native/imgproxy grammar.
- `best` parses through `format` and `@best`, but planner semantic validation rejects it before cache/origin.
- Dangling raw `@` strips the separator from source path and does not overwrite an explicit format.
- Unknown source extensions are parser errors.
- Automatic output cache key uses normalized modern candidates and auto flags, not raw `Accept` and not selected source format.
- Automatic response delivery sets `Vary: Accept`.
- Source-format fallback depends on origin content type and therefore cannot be resolved before origin fetch.

## Proposed Module Ownership

- `ImagePlug.ParamParser.Native`: parser grammar, parser-specific normalization, and `handle_error/2`. It returns `{:ok, %ImagePlug.Plan{}}` through the `ImagePlug.ParamParser` behaviour.
- `ImagePlug.ParamParser.Native.ParsedRequest`: parser-owned native/imgproxy whole-request IR.
- `ImagePlug.ParamParser.Native.PipelineRequest`: parser-owned native/imgproxy one-pipeline assignment IR. This replaces the current core-visible role of `ImagePlug.ProcessingRequest`.
- `ImagePlug.ParamParser.Native.PlanBuilder`: the native-only adapter from native IR to product-neutral `%ImagePlug.Plan{}`. It owns native semantic validation such as unsupported `:best`, `:sm`, `:auto`, `:fill_down`, extend, and offsets.
- `ImagePlug.Plan`: final product-neutral execution representation.
- `ImagePlug.Pipeline`: one ordered image-operation pipeline; multiple pipelines are ordered and separated by materialization barriers.
- `ImagePlug.Source.Plain`: normalized plain source path.
- `ImagePlug.OutputPlan`: requested output intent, before runtime source-format fallback.
- `ImagePlug.OutputPolicy`: runtime output negotiation from `%OutputPlan{}` plus `Accept` and opts.
- `ImagePlug.RequestRunner`: cache lookup, output resolution, processor orchestration, and response/cache delivery with explicit resolved output format.
- `ImagePlug.Processor`: origin fetch/decode/transform execution only; no output encoding state. It executes pipelines in order and materializes between pipelines.
- `ImagePlug.OutputEncoder`: encode a transformed image using an explicit resolved format.
- `ImagePlug.Cache.Key`: cache key from normalized `Plan` material plus resolved origin identity and vary inputs.
- `ImagePlug.Cache.TransformMaterial`: protocol for canonical cache material from transform params structs. Transform params structs are one-to-one with transform modules, so cache operation material dispatches by params struct.

Forbidden dependencies after the migration:

- `ImagePlug`, `RequestRunner`, `Processor`, `Cache.Key`, `ResponseCache`, `OutputPolicy`, and `OutputEncoder` must not alias or pattern match on `ImagePlug.ParamParser.Native.*` modules.
- `ImagePlug.ParamParser.Native.*` may depend on core plan structs and transform modules.
- Core plan structs must not depend on native parser modules.

## Dependency Direction Rules

Allowed dependency direction:

- `ImagePlug` depends on the `ImagePlug.ParamParser` behaviour and `%ImagePlug.Plan{}`.
- Parser implementations depend on the `ImagePlug.ParamParser` behaviour, parser-local IR, core plan structs, and core operation/transform constructors.
- Parser-local IR converts into `%ImagePlug.Plan{}` before crossing into core runtime.
- Runtime modules consume `%ImagePlug.Plan{}`, `%ImagePlug.Source.*`, `%ImagePlug.Pipeline{}`, `%ImagePlug.OutputPlan{}`, and resolved runtime output formats.
- Cache modules derive canonical cache material from `%ImagePlug.Plan{}`, `origin_identity`, and selected vary inputs.
- Output negotiation resolves `%ImagePlug.OutputPlan{}` into a runtime format decision.
- `Processor` executes product-neutral plan pipelines and may depend on `DecodePlanner`, `TransformChain`, and image materialization helpers.

Forbidden dependencies:

- Core runtime modules must not reference `ImagePlug.ParamParser.Native.*`.
- `Cache.Key` must not accept or inspect parser-local IR.
- `ImagePlug.Plan`, `ImagePlug.OutputPlan`, `ImagePlug.Pipeline`, and `ImagePlug.Source.*` must not reference parser modules.
- `OutputPolicy` must not append or mutate transform pipelines.
- `Processor` must not know parser-specific URL syntax, aliases, assignment order, or source `@extension` parsing.
- `OutputEncoder` must not read output format from `TransformState`.

## Module Structure And Dataflow

Target module structure:

```text
lib/image_plug.ex
  -> ImagePlug.ParamParser behaviour
  -> ImagePlug.Plan
  -> ImagePlug.RequestRunner

lib/image_plug/param_parser.ex
  defines parser behaviour returning {:ok, %ImagePlug.Plan{}} | {:error, reason}

lib/image_plug/param_parser/native.ex
  -> ImagePlug.ParamParser behaviour
  -> ImagePlug.ParamParser.Native.ParsedRequest
  -> ImagePlug.ParamParser.Native.PipelineRequest
  -> ImagePlug.ParamParser.Native.PlanBuilder

lib/image_plug/param_parser/native/parsed_request.ex
  parser-local whole-request IR

lib/image_plug/param_parser/native/pipeline_request.ex
  parser-local one-pipeline assignment IR

lib/image_plug/param_parser/native/plan_builder.ex
  -> ImagePlug.Plan
  -> ImagePlug.Source.Plain
  -> ImagePlug.Pipeline
  -> ImagePlug.OutputPlan
  -> ImagePlug.Transform.*

lib/image_plug/plan.ex
lib/image_plug/pipeline.ex
lib/image_plug/source/plain.ex
lib/image_plug/output_plan.ex
  core product-neutral data structs; no parser dependencies

lib/image_plug/request_runner.ex
  -> ImagePlug.ResponseCache
  -> ImagePlug.OutputPolicy
  -> ImagePlug.Processor
  -> ImagePlug.OutputEncoder through response/cache helpers

lib/image_plug/response_cache.ex
  -> ImagePlug.Cache
  -> ImagePlug.Cache.Key
  -> ImagePlug.OutputEncoder

lib/image_plug/cache/key.ex
  -> ImagePlug.Plan
  -> ImagePlug.Pipeline
  -> ImagePlug.OutputPlan
  -> ImagePlug.Source.*
  -> ImagePlug.Cache.TransformMaterial

lib/image_plug/cache/transform_material.ex
lib/image_plug/cache/transform_material/*.ex
  protocol and implementations for canonical transform params material

lib/image_plug/output_policy.ex
  -> ImagePlug.OutputPlan
  -> ImagePlug.ImageFormat

lib/image_plug/processor.ex
  -> ImagePlug.Plan
  -> ImagePlug.DecodePlanner
  -> ImagePlug.TransformChain
  -> image materializer helper/module

lib/image_plug/decode_planner.ex
  -> ImagePlug.Plan or ImagePlug.TransformChain

lib/image_plug/output_encoder.ex
  -> ImagePlug.ImageFormat
  -> explicit resolved output format
```

Target request dataflow:

```text
HTTP request
  -> ImagePlug.call/2
  -> configured ImagePlug.ParamParser.parse/1
  -> ImagePlug.ParamParser.Native.parse/1
  -> %ImagePlug.ParamParser.Native.ParsedRequest{
       pipelines: [%ImagePlug.ParamParser.Native.PipelineRequest{}],
       output_format: requested_native_format_or_nil
     }
  -> ImagePlug.ParamParser.Native.PlanBuilder.to_plan/1
  -> %ImagePlug.Plan{
       source: %ImagePlug.Source.Plain{},
       pipelines: [%ImagePlug.Pipeline{}],
       output: %ImagePlug.OutputPlan{}
     }
  -> ImagePlug.origin_identity(plan.source, opts)
  -> ImagePlug.RequestRunner.run(conn, plan, origin_identity, opts)
  -> ImagePlug.ResponseCache.lookup(conn, plan, origin_identity, opts)
  -> ImagePlug.Cache.Key.build(conn, plan, origin_identity, opts)
  -> cache hit returns encoded response
  -> cache miss:
       ImagePlug.OutputPolicy.from_output_plan(conn, plan.output, opts)
       ImagePlug.Processor.process_origin(plan, origin_identity, opts)
         -> ImagePlug.DecodePlanner.open_options(plan)
         -> fetch/decode origin from plan.source
         -> execute each plan.pipelines entry through TransformChain
         -> materialize between pipelines
       ImagePlug.OutputPolicy.resolve_source_format(policy, origin_source_format)
       ImagePlug.ResponseCache.store(conn, plan, origin_identity, state, resolved_format, response_headers, opts)
         -> ImagePlug.OutputEncoder.limited_memory_output(state, resolved_format, opts, max_body_bytes)
       ImagePlug.send_image(conn, state, resolved_format, response_headers, opts)
         -> ImagePlug.OutputEncoder streams/encodes using resolved_format
```

Data ownership by boundary:

- Parser boundary owns only parser syntax and parser-local normalization before emitting `%ImagePlug.Plan{}`.
- `%ImagePlug.Plan{}` owns normalized source, ordered pipeline boundaries, and requested output intent.
- `RequestRunner` owns orchestration, but not parser semantics or transform construction.
- `Cache.Key` owns canonical cache materialization from `%Plan{}`, `origin_identity`, and selected vary inputs. The parser never returns cache material.
- `Cache.TransformMaterial` owns canonical operation material for transform params. `Cache.Key` must not serialize raw transform tuples or raw params structs directly.
- `OutputPolicy` owns output negotiation and source-format fallback resolution. It returns a runtime resolved format and does not mutate `%Plan{}`.
- `Processor` owns origin fetch/decode and image transforms. It consumes `plan.source` and `plan.pipelines`, not output intent.
- `OutputEncoder` owns final encoding from image state plus an explicit resolved output format.

Future operation layer note:

- `ImagePlug.Plan` is parser-neutral and product-level, but in this PR its pipeline operations are still executable `ImagePlug.Transform.*` tuples. It is not fully execution-neutral yet.
- `ImagePlug.ParamParser.Native.PlanBuilder` may map native IR directly to current `ImagePlug.Transform.*` tuples in this PR, treating transform modules as the current core execution operation representation.
- If direct parser-to-transform coupling becomes awkward, add a later product-neutral `ImagePlug.Operation.*` layer and a compiler from operations to executable transforms.
- Do not add `ImagePlug.Operation.*` in this PR unless the current transform tuples block the parser/plan/cache/output boundary work.

## Target Shapes

The exact fields can be adjusted while implementing, but the planned first shape is:

Native parser IR:

```elixir
defmodule ImagePlug.ParamParser.Native.PipelineRequest do
  @moduledoc false

  @type resizing_type() :: :fit | :fill | :fill_down | :force | :auto
  @type gravity_anchor() :: {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type gravity() :: gravity_anchor() | {:fp, float(), float()} | :sm

  defstruct width: nil,
            height: nil,
            resizing_type: :fit,
            enlarge: false,
            extend: false,
            extend_gravity: nil,
            extend_x_offset: nil,
            extend_y_offset: nil,
            gravity: {:anchor, :center, :center},
            gravity_x_offset: 0.0,
            gravity_y_offset: 0.0
end
```

```elixir
defmodule ImagePlug.ParamParser.Native.ParsedRequest do
  @moduledoc false

  @enforce_keys [:signature, :source_kind, :source_path, :pipelines]
  defstruct @enforce_keys ++ [output_format: nil]

  @type output_format() :: :webp | :avif | :jpeg | :png | :best

  @type t :: %__MODULE__{
          signature: String.t(),
          source_kind: :plain,
          source_path: [String.t()],
          pipelines: [ImagePlug.ParamParser.Native.PipelineRequest.t()],
          output_format: output_format() | nil
        }
end
```

Core execution structs:

```elixir
defmodule ImagePlug.Source.Plain do
  @enforce_keys [:path]
  defstruct @enforce_keys
  @type t :: %__MODULE__{path: [String.t()]}
end
```

```elixir
defmodule ImagePlug.OutputPlan do
  @enforce_keys [:mode]
  defstruct @enforce_keys

  @type format :: :avif | :webp | :jpeg | :png
  @type t :: %__MODULE__{mode: :automatic | {:explicit, format()}}
end
```

`%OutputPlan{mode: :automatic}` means Accept/config-driven modern format negotiation with runtime source-format fallback after origin fetch. Do not add a separate `:source` mode in this PR unless implementation proves current behavior already distinguishes explicit source preservation from automatic negotiation.

```elixir
defmodule ImagePlug.Pipeline do
  @enforce_keys [:operations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{operations: ImagePlug.TransformChain.t()}
end
```

```elixir
defmodule ImagePlug.Plan do
  @enforce_keys [:source, :pipelines, :output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: ImagePlug.Source.Plain.t(),
          pipelines: [ImagePlug.Pipeline.t()],
          output: ImagePlug.OutputPlan.t()
        }
end
```

Pipeline semantics:

- `pipelines` is always non-empty for executable plans.
- The current native/imgproxy subset produces one pipeline.
- Future imgproxy chained pipelines produce multiple pipelines split on `/-/`.
- `Processor` runs each pipeline's operations in order.
- If another pipeline follows, `Processor` materializes the current image before running the next pipeline.
- `DecodePlanner` should base origin open options on the first pipeline only. Later random/heavy operations work on materialized intermediate images and must not force random access for the origin decode.

## Task 1: Add Product-Neutral Plan Structs

**Files:**
- Create: `lib/image_plug/source/plain.ex`
- Create: `lib/image_plug/pipeline.ex`
- Create: `lib/image_plug/output_plan.ex`
- Create: `lib/image_plug/plan.ex`
- Create: `test/image_plug/plan_test.exs`

- [ ] **Step 1: Write failing struct tests**

```elixir
defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputPlan
  alias ImagePlug.Plan
  alias ImagePlug.Pipeline
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  test "represents source, image pipelines, and output separately" do
    operations = [
      {Transform.Contain,
       %Transform.Contain.ContainParams{
         type: :dimensions,
         width: {:pixels, 300},
         height: :auto,
         constraint: :max,
         letterbox: false
       }}
    ]

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %OutputPlan{mode: {:explicit, :webp}}
    }

    assert plan.source.path == ["images", "cat.jpg"]
    assert [%Pipeline{operations: ^operations}] = plan.pipelines
    assert plan.output.mode == {:explicit, :webp}
  end
end
```

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/image_plug/plan_test.exs`

Expected: compile failure because `ImagePlug.Plan`, `ImagePlug.Pipeline`, `ImagePlug.Source.Plain`, and `ImagePlug.OutputPlan` do not exist.

- [ ] **Step 3: Add minimal structs**

Create the four modules with the target shapes above. Keep them data-only.

- [ ] **Step 4: Run GREEN**

Run: `mise exec -- mix test test/image_plug/plan_test.exs`

Expected: pass.

- [ ] **Step 5: Commit**

```bash
mise exec -- git add lib/image_plug/source/plain.ex lib/image_plug/pipeline.ex lib/image_plug/output_plan.ex lib/image_plug/plan.ex test/image_plug/plan_test.exs
mise exec -- git commit -m "feat: add execution plan data model"
```

## Task 2: Add Plan Construction Without Rewiring Runtime

**Files:**
- Create: `lib/image_plug/param_parser/native/pipeline_request.ex`
- Create: `lib/image_plug/param_parser/native/parsed_request.ex`
- Create: `lib/image_plug/param_parser/native/plan_builder.ex`
- Create: `test/param_parser/native/plan_builder_test.exs`
- Modify: `test/image_plug/pipeline_planner_test.exs` only if keeping temporary compatibility coverage for the old runtime planner

- [ ] **Step 1: Add failing tests for `Native.PlanBuilder.to_plan/1`**

Add tests asserting:

```elixir
defmodule ImagePlug.ParamParser.Native.PlanBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputPlan
  alias ImagePlug.ParamParser.Native.ParsedRequest
  alias ImagePlug.ParamParser.Native.PipelineRequest
  alias ImagePlug.ParamParser.Native.PlanBuilder
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  test "converts one native pipeline request into a product-neutral plan" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output_format: nil
    }

    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [
                %Pipeline{operations: operations}
              ],
              output: %OutputPlan{mode: :automatic}
            }} = PlanBuilder.to_plan(request)

    assert [{Transform.Contain, params}] = operations
    assert params.width == {:pixels, 300}
  end
end
```

Add explicit output tests:

```elixir
request = %ParsedRequest{
  signature: "_",
  source_kind: :plain,
  source_path: ["images", "cat.jpg"],
  pipelines: [%PipelineRequest{}],
  output_format: :png
}

assert {:ok,
        %ImagePlug.Plan{
          pipelines: [%ImagePlug.Pipeline{operations: []}],
          output: %ImagePlug.OutputPlan{mode: :automatic}
        }} =
         PlanBuilder.to_plan(%ParsedRequest{request | output_format: nil})

assert {:ok,
        %ImagePlug.Plan{
          pipelines: [%ImagePlug.Pipeline{operations: []}],
          output: %ImagePlug.OutputPlan{mode: {:explicit, :png}}
        }} =
         PlanBuilder.to_plan(request)
```

Add a property replacing "explicit output format is always planned last" with "explicit output format is represented only as output intent":

```elixir
assert {:ok, %ImagePlug.Plan{} = plan} = PlanBuilder.to_plan(parsed_request)

case parsed_request.output_format do
  nil ->
    assert plan.output == %ImagePlug.OutputPlan{mode: :automatic}

  format ->
    assert plan.output == %ImagePlug.OutputPlan{mode: {:explicit, format}}
end

assert [%ImagePlug.Pipeline{} | _] = plan.pipelines
```

Do not add a direct reference to the output transform module in this test. It should survive the final output-transform grep audit.

Add a producer-boundary invariant test for executable plans:

```elixir
assert {:error, :empty_pipeline_plan} =
         PlanBuilder.to_plan(%ParsedRequest{
           signature: "_",
           source_kind: :plain,
           source_path: ["images", "cat.jpg"],
           pipelines: [],
           output_format: nil
         })
```

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/param_parser/native/plan_builder_test.exs`

Expected: compile failure for missing native IR modules and `PlanBuilder.to_plan/1`.

- [ ] **Step 3: Implement native IR modules**

Create `PipelineRequest` and `ParsedRequest` under `ImagePlug.ParamParser.Native`.

- [ ] **Step 4: Implement `Native.PlanBuilder.to_plan/1`**

Move or delegate current native/imgproxy-specific validation and transform mapping into parser-owned `Native.PlanBuilder`. It should accept only `%ParsedRequest{}` and produce `%Plan{}`. Do not make core runtime depend on `Native.PlanBuilder`. If existing `PipelinePlanner` helpers are still useful, keep them private/internal until the sweep, but the final public adapter is `Native.PlanBuilder.to_plan/1`.

```elixir
def to_plan(%ParsedRequest{} = request) do
  with {:ok, pipelines} <- build_pipelines(request.pipelines),
       {:ok, output} <- output_plan(request.output_format) do
    {:ok,
     %Plan{
       source: %Source.Plain{path: request.source_path},
       pipelines: pipelines,
       output: output
     }}
  end
end

defp build_pipelines([]), do: {:error, :empty_pipeline_plan}

defp build_pipelines(pipeline_requests) do
  pipeline_requests
  |> Enum.map(&pipeline/1)
  |> reduce_results()
end

defp pipeline(%PipelineRequest{} = pipeline_request) do
  with :ok <- validate_dimensions(pipeline_request),
       :ok <- validate_supported_semantics(pipeline_request),
       {:ok, operations} <- plan_geometry(pipeline_request) do
    {:ok, %Pipeline{operations: operations}}
  end
end

defp output_plan(nil), do: {:ok, %OutputPlan{mode: :automatic}}
defp output_plan(:best), do: {:error, {:unsupported_output_format, :best}}
defp output_plan(format) when format in [:avif, :webp, :jpeg, :png],
  do: {:ok, %OutputPlan{mode: {:explicit, format}}}
```

Import aliases for `ImagePlug.Plan`, `ImagePlug.Pipeline`, `ImagePlug.OutputPlan`, `ImagePlug.Source.Plain`, and `ImagePlug.ParamParser.Native.PipelineRequest`.

- [ ] **Step 5: Keep old runtime planner temporarily**

Keep `ImagePlug.PipelinePlanner.plan/1` unchanged for the old runtime until `ImagePlug` consumes `%Plan{}`. Do not introduce a dependency from `PipelinePlanner`, `RequestRunner`, `Processor`, cache, output, or plug modules to `ImagePlug.ParamParser.Native.*`. If useful, `Native.PlanBuilder` may delegate to existing private mapping helpers during the transition, but the dependency direction must remain parser adapter -> reusable helper/core transform constructors, never runtime/core -> native parser.

- [ ] **Step 6: Run GREEN**

Run: `mise exec -- mix test test/param_parser/native/plan_builder_test.exs test/image_plug/pipeline_planner_test.exs`

Expected: pass with old `PipelinePlanner.plan/1` runtime tests still passing.

- [ ] **Step 7: Commit**

```bash
mise exec -- git add lib/image_plug/param_parser/native/pipeline_request.ex lib/image_plug/param_parser/native/parsed_request.ex lib/image_plug/param_parser/native/plan_builder.ex test/param_parser/native/plan_builder_test.exs test/image_plug/pipeline_planner_test.exs
mise exec -- git commit -m "feat: build execution plans from native parser IR"
```

## Task 3: Rewire Parser And Runner To Pass Plans

**Files:**
- Modify: `lib/image_plug/param_parser.ex`
- Modify: `lib/image_plug/param_parser/native.ex`
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: `test/image_plug_test.exs`
- Modify: `test/image_plug/request_runner_test.exs`

- [ ] **Step 1: Write failing top-level plan handoff tests**

Update parser fakes in `test/image_plug_test.exs` to return `%Plan{}` instead of `%ProcessingRequest{}`. Remove fake planner use from new tests; the plug should only depend on the parser behaviour's plan-returning API.

Add or keep an integration assertion for explicit output:

```elixir
conn =
  conn(:get, "/_/f:webp/plain/images/cat-300.jpg")
  |> ImagePlug.call(root_url: "http://origin.test", param_parser: ImagePlug.ParamParser.Native, origin_req_options: [plug: OriginImage])

assert conn.status == 200
assert get_resp_header(conn, "content-type") == ["image/webp"]
assert get_resp_header(conn, "vary") == []
```

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/image_plug_test.exs test/image_plug/request_runner_test.exs`

Expected: failures because `ImagePlug.call/2` still expects parser output as `%ProcessingRequest{}` and expects `planner.plan/1` to return a chain.

- [ ] **Step 3: Change parser contract and native parser return**

Change `ParamParser.parse/1` callback to return `{:ok, ImagePlug.Plan.t()} | {:error, term()}`.

Update `ImagePlug.ParamParser.Native.parse/1` to parse into `%ParsedRequest{}` and call `ImagePlug.ParamParser.Native.PlanBuilder.to_plan/1`. Native parser errors and native semantic errors still flow through `Native.handle_error/2`.

- [ ] **Step 4: Change `ImagePlug.call/2` to consume `%Plan{}`**

Remove the separate `:pipeline_planner` call. The only parser/runtime handoff is the plan:

```elixir
with {:ok, %Plan{} = plan} <- param_parser.parse(conn) |> wrap_parser_error(),
     {:ok, origin_identity} <- origin_identity(plan, opts) |> wrap_origin_error() do
  result = RequestRunner.run(conn, plan, origin_identity, opts)
  send_runner_result(result, conn, opts)
end
```

Build origin identity from `plan.source`:

```elixir
defp origin_identity(%Plan{source: %Source.Plain{path: path}}, opts) do
  opts |> Keyword.fetch!(:root_url) |> Origin.build_url(path)
end
```

- [ ] **Step 5: Change `RequestRunner` to accept `%Plan{}`**

Use the first pipeline's operations instead of receiving a separate planned chain. Still append a temporary `Transform.Output` entry in this transitional commit if needed to keep `OutputEncoder` unchanged. Keep processor source/fetch internals unchanged until Task 4.

```elixir
case plan.pipelines do
  [%Pipeline{operations: operations}] ->
    executable_chain = TransformChain.append_output(operations, format)
    Processor.process_origin(processor_source_input(plan), executable_chain, origin_identity, opts)

  [_ | _] ->
    {:error, :unsupported_multiple_pipelines_during_transition}

  [] ->
    {:error, :empty_pipeline_plan}
end
```

Add a private transitional adapter if the current `Processor` still pattern matches on `%ProcessingRequest{}`:

```elixir
defp processor_source_input(%Plan{source: %Source.Plain{path: path}}) do
  %ImagePlug.ProcessingRequest{source_kind: :plain, source_path: path}
end
```

This adapter is migration glue inside Task 3 only. It must be deleted in Task 4 and must not survive beyond that commit.

The temporary `Transform.Output` chain append is removed in Task 7.

- [ ] **Step 6: Run GREEN**

Run: `mise exec -- mix test test/image_plug_test.exs test/image_plug/request_runner_test.exs`

Expected: pass with runtime using `%Plan{}` through `ImagePlug.call/2` and `RequestRunner`, while `Processor` still has the old source/fetch boundary.

- [ ] **Step 7: Commit**

```bash
mise exec -- git add lib/image_plug/param_parser.ex lib/image_plug/param_parser/native.ex lib/image_plug.ex lib/image_plug/request_runner.ex test/image_plug_test.exs test/image_plug/request_runner_test.exs
mise exec -- git commit -m "refactor: pass execution plans through request runner"
```

## Task 4: Change Processor To Consume Plans

**Files:**
- Modify: `lib/image_plug/processor.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: `test/image_plug/processor_test.exs`
- Modify: `test/image_plug/request_runner_test.exs`

- [ ] **Step 1: Write failing processor plan-source tests**

Add focused tests proving `Processor` fetches origin from `%Plan{source: %Source.Plain{}}` and `origin_identity`, not from `%ProcessingRequest{}`.

Keep runtime single-pipeline only in this task:

```elixir
assert {:error, :unsupported_multiple_pipelines_during_transition} =
         RequestRunner.run(conn, %Plan{plan | pipelines: [%Pipeline{operations: []}, %Pipeline{operations: []}]}, origin_identity, opts)
```

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/image_plug/processor_test.exs test/image_plug/request_runner_test.exs`

Expected: failures because `Processor` still accepts `%ProcessingRequest{}` for origin source data.

- [ ] **Step 3: Change `Processor` source inputs**

Change `Processor.process_origin/4`, `fetch_decode_validate_origin_with_source_format/4`, and `fetch_origin_with_source_format/3` to accept `%Plan{}` for source data. Fetch origin from `%Plan{source: %Source.Plain{}}`; keep the resolved `origin_identity` string as the fetch URL.

If the temporary `Transform.Output` compatibility chain is still needed, keep it as an explicit transient chain argument:

```elixir
Processor.process_origin(%Plan{} = plan, executable_chain, origin_identity, opts)
```

This is a migration-only shape. After Task 7, `Processor` should execute `plan.pipelines` directly and no longer receive a chain containing `Transform.Output`.

- [ ] **Step 4: Run GREEN**

Run: `mise exec -- mix test test/image_plug/processor_test.exs test/image_plug/request_runner_test.exs test/image_plug_test.exs`

Expected: pass with runtime and processor source handling based on `%Plan{}`.

- [ ] **Step 5: Commit**

```bash
mise exec -- git add lib/image_plug/processor.ex lib/image_plug/request_runner.ex test/image_plug/processor_test.exs test/image_plug/request_runner_test.exs test/image_plug_test.exs
mise exec -- git commit -m "refactor: fetch origins from execution plans"
```

## Task 5: Move Cache Keys To Canonical Plan Material

Cache key construction must derive from `%ImagePlug.Plan{}` plus `origin_identity` and selected request vary inputs. The parser must not return cache material, and cache code must not know about parser IR modules such as `ProcessingRequest` or `ImagePlug.ParamParser.Native.*`.

`Cache.Key` unit tests should primarily use hand-built `%ImagePlug.Plan{}` values. Tests that go through `ImagePlug.ParamParser.Native` or native plan conversion are allowed only as integration/equivalence tests outside the core `Cache.Key` unit boundary.

**Files:**
- Create: `lib/image_plug/cache/transform_material.ex`
- Create: `lib/image_plug/cache/transform_material/contain.ex`
- Create: `lib/image_plug/cache/transform_material/cover.ex`
- Create: `lib/image_plug/cache/transform_material/crop.ex`
- Create: `lib/image_plug/cache/transform_material/focus.ex`
- Create: `lib/image_plug/cache/transform_material/scale.ex`
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/cache.ex`
- Modify: `lib/image_plug/response_cache.ex`
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Create: `test/image_plug/cache/transform_material_test.exs`
- Modify: `test/image_plug/cache_test.exs`
- Modify: `test/image_plug/response_cache_test.exs`

- [ ] **Step 1: Write failing cache-key tests using `%Plan{}`**

Change `Key.build/4` tests so they pass hand-built `%Plan{}` values. Do not use native IR in `Cache.Key` unit tests. Keep parser/native equivalence coverage in parser or integration tests where the subject under test is the conversion into `%Plan{}`.

Expected material shape:

```elixir
[
  schema_version: 2,
  origin_identity: "https://origin-a.test/images/cat.jpg",
  source: source_material(plan.source),
  pipelines: pipelines_material(plan.pipelines),
  output: output_material(conn, plan.output, opts),
  selected_headers: selected_headers(conn, opts),
  selected_cookies: selected_cookies(conn, opts)
]
```

Example canonical pipeline material:

```elixir
pipelines: [
  [
    [op: :contain, width: {:pixels, 300}, height: :auto, constraint: :max, letterbox: false]
  ],
  [
    [op: :crop, width: {:pixels, 200}, height: {:pixels, 100}, crop_from: :focus]
  ]
]
```

For automatic output, assert:

```elixir
output: [
  mode: :automatic,
  modern_candidates: [:avif, :webp],
  auto: [avif: true, webp: true]
]
```

Required constraints:

- `Cache.Key.build/4` accepts `%ImagePlug.Plan{}` only.
- `Cache.Key` does not call parser modules.
- `Cache.Key` does not inspect parser IR fields.
- `source_material/1` emits normalized product-neutral source material.
- `pipelines_material/1` preserves pipeline boundaries.
- `pipelines_material/1` emits canonical operation material, not raw parser request fields.
- Raw transform tuples and raw params structs must not be inserted directly into cache material.
- Operation material must dispatch through `ImagePlug.Cache.TransformMaterial.material(params)`.
- Automatic output material is based on normalized Accept capabilities and auto flags only.
- Raw `Accept` is not included.
- Runtime-selected source fallback format is not included in the pre-origin cache key.
- Explicit output material is independent of Accept and does not add Accept/Vary material.

- [ ] **Step 2: Write failing transform material protocol tests**

Add implementations for every current transform params struct found by code search, at minimum `Contain`, `Cover`, `Crop`, `Focus`, and `Scale`. The listed five are examples from current discovery, not an exhaustive source of truth.

Run this search before deciding protocol coverage:

```bash
mise exec -- rg "defmodule ImagePlug.Transform.*Params|defstruct" lib/image_plug/transform
```

Acceptance criterion: every params struct that can appear in `Plan.pipelines` implements `ImagePlug.Cache.TransformMaterial`.

Do not proceed with only the named minimum set if the search finds additional transform params structs that can appear in executable plan pipelines. Add protocol implementations and tests for those structs in the same task.

Add tests that assert every current transform params struct has canonical material:

```elixir
assert TransformMaterial.material(%Transform.Contain.ContainParams{
         type: :dimensions,
         width: {:pixels, 300},
         height: :auto,
         constraint: :max,
         letterbox: false
       }) == [op: :contain, type: :dimensions, width: {:pixels, 300}, height: :auto, constraint: :max, letterbox: false]
```

Add equivalent tests for `CoverParams`, `CropParams`, `FocusParams`, and `ScaleParams`. Do not implement `Transform.Output.OutputParams`; `Transform.Output` is transitional and must never appear in plan pipeline cache material.

- [ ] **Step 3: Run RED**

Run: `mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/cache/transform_material_test.exs`

Expected: failures because `Key.build/4` only accepts `%ProcessingRequest{}` and transform params do not implement `ImagePlug.Cache.TransformMaterial`.

- [ ] **Step 4: Implement `ImagePlug.Cache.TransformMaterial`**

Create the protocol:

```elixir
defprotocol ImagePlug.Cache.TransformMaterial do
  @moduledoc """
  Canonical cache material for transform parameter structs.

  Every transform params struct that can appear in `ImagePlug.Plan` pipelines must
  implement this protocol. Missing implementations are programmer errors and may
  raise `Protocol.UndefinedError` during cache key construction.
  """

  @spec material(t()) :: keyword()
  def material(params)
end
```

Implement the protocol for each transform params struct in separate files under `lib/image_plug/cache/transform_material/`. Transform params structs are one-to-one with transform modules, so dispatch by params struct is sufficient.

- [ ] **Step 5: Implement canonical plan-based key building**

Change `Key.build/4` to accept `%ImagePlug.Plan{}`. Build all cache material from product-neutral plan fields, `origin_identity`, and selected request vary inputs:

```elixir
def build(conn, %Plan{} = plan, origin_identity, opts \\ []) do
  material = [
    schema_version: @schema_version,
    origin_identity: origin_identity,
    source: source_material(plan.source),
    pipelines: pipelines_material(plan.pipelines),
    output: output_material(conn, plan.output, opts),
    selected_headers: selected_headers(conn, opts),
    selected_cookies: selected_cookies(conn, opts)
  ]

  ...
end
```

Set `@schema_version 2` because material shape changes.

Implement `pipelines_material/1` as a separate function so cache material is an explicit canonical representation. It must preserve the outer pipeline list and map each operation through the protocol:

```elixir
defp operation_material({_transform_module, params}) do
  TransformMaterial.material(params)
end
```

- [ ] **Step 6: Update cache wrappers to accept plans**

Change `Cache.lookup/4` and `ResponseCache.lookup/4` specs and heads from `%ProcessingRequest{}` to `%Plan{}` and pass the plan to `Key.build/4`.

- [ ] **Step 7: Run GREEN**

Run: `mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/cache/transform_material_test.exs test/image_plug/cache_test.exs test/image_plug/response_cache_test.exs`

Expected: pass.

- [ ] **Step 8: Commit**

```bash
mise exec -- git add lib/image_plug/cache/key.ex lib/image_plug/cache.ex lib/image_plug/response_cache.ex lib/image_plug/cache/transform_material.ex lib/image_plug/cache/transform_material test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/cache/transform_material_test.exs test/image_plug/cache_test.exs test/image_plug/response_cache_test.exs
mise exec -- git commit -m "refactor: build cache keys from execution plans"
```

## Task 6: Resolve Output Without TransformState

**Files:**
- Modify: `lib/image_plug/output_policy.ex`
- Modify: `lib/image_plug/output_encoder.ex`
- Modify: `lib/image_plug/response_cache.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: `lib/image_plug.ex`
- Modify: `test/image_plug/output_policy_test.exs`
- Modify: `test/image_plug/output_encoder_test.exs`
- Modify: `test/image_plug/response_cache_test.exs`
- Modify: `test/image_plug/request_runner_test.exs`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Write failing output-policy and encoder tests**

Change `OutputPolicy.from_request/3` tests to `OutputPolicy.from_output_plan/3`:

```elixir
assert OutputPolicy.from_output_plan(conn, %OutputPlan{mode: {:explicit, :webp}}, []) == %OutputPolicy{...}
assert OutputPolicy.from_output_plan(conn, %OutputPlan{mode: :automatic}, []) == %OutputPolicy{...}
```

Change encoder tests to pass the resolved format explicitly:

```elixir
assert {:ok, %OutputEncoder.EncodedOutput{} = output} =
         OutputEncoder.memory_output(%TransformState{image: image}, :png, [])
```

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/response_cache_test.exs`

Expected: compile failures for missing new arities and plan-based policy API.

- [ ] **Step 3: Update output policy API**

Change `OutputPolicy.from_request/3` to `from_output_plan/3` and read `%OutputPlan{mode: ...}`.

- [ ] **Step 4: Update output encoder API**

Replace `mime_type(state)` with `mime_type(format)`. Replace:

```elixir
memory_output(%TransformState{} = state, opts)
limited_memory_output(%TransformState{} = state, opts, max_body_bytes)
```

with:

```elixir
memory_output(%TransformState{} = state, format, opts)
limited_memory_output(%TransformState{} = state, format, opts, max_body_bytes)
```

Use `ImageFormat.mime_type(format)` and return the same encode error shape for unsupported formats.

- [ ] **Step 5: Thread resolved format through runtime**

Change `RequestRunner` success delivery to `{:image, final_state, resolved_format, response_headers}`.

Change `ResponseCache.store/5` to receive `resolved_format` and call `OutputEncoder.limited_memory_output(state, resolved_format, opts, max_body_bytes)`.

Change `ImagePlug.send_image/5` to receive `resolved_format` and stream with `ImageFormat.mime_type!(resolved_format)` and suffix.

- [ ] **Step 6: Run GREEN**

Run: `mise exec -- mix test test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/response_cache_test.exs test/image_plug/request_runner_test.exs test/image_plug_test.exs`

Expected: pass.

- [ ] **Step 7: Commit**

```bash
mise exec -- git add lib/image_plug/output_policy.ex lib/image_plug/output_encoder.ex lib/image_plug/response_cache.ex lib/image_plug/request_runner.ex lib/image_plug.ex test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/response_cache_test.exs test/image_plug/request_runner_test.exs test/image_plug_test.exs
mise exec -- git commit -m "refactor: pass resolved output format explicitly"
```

## Task 7: Remove Output Transform From Execution Flow

**Files:**
- Modify: `lib/image_plug/transform_chain.ex`
- Modify: `lib/image_plug/transform_state.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: `lib/image_plug/processor.ex`
- Delete: `lib/image_plug/transform/output.ex`
- Modify: `lib/image_plug/param_parser/native/plan_builder.ex`
- Modify: `test/param_parser/native/plan_builder_test.exs`
- Modify: `test/image_plug/decode_planner_test.exs`
- Modify: `test/image_plug/processor_test.exs` only where tests assert `TransformState.output`

- [ ] **Step 1: Write failing tests that no planner emits `Transform.Output`**

Replace output-chain assertions:

```elixir
assert {:ok,
        %Plan{
          pipelines: [%Pipeline{operations: []}],
          output: %OutputPlan{mode: {:explicit, :webp}}
        }} =
         PlanBuilder.to_plan(parsed_request_with_force_resize_and_webp_output)
```

Replace output-only decode planner tests with empty-chain tests. Remove the output-neutral access assertions because output is no longer a transform. Include `test/image_plug/pipeline_planner_property_test.exs` or any other property test file here if Task 2 kept temporary output-transform assertions there; otherwise sweep those migration-only assertions in Task 10.

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/param_parser/native/plan_builder_test.exs test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs`

Expected: failures where old native plan building, `TransformChain.append_output/2`, or `TransformState.output` remains expected.

- [ ] **Step 3: Remove output transform utilities**

Remove `Transform.Output` from `TransformChain.item/0`. Delete `TransformChain.append_output/2`. Delete `lib/image_plug/transform/output.ex` once no code references it.

- [ ] **Step 4: Remove `TransformState.output`**

Delete the field and type from `TransformState`. Update tests and helper transforms that set `output` to set only `image`.

- [ ] **Step 5: Remove transient executable chains from runtime**

Remove the Task 3/4 temporary `TransformChain.append_output/2` path. For this task, `Processor` may still require exactly one pipeline, but it should read that pipeline from `%Plan{}` instead of receiving a separate chain argument.

Make the final Task 7 processor signature explicit:

```elixir
Processor.process_origin(%Plan{} = plan, origin_identity, opts)
```

Task 8 keeps this public shape and adds support for multiple pipelines.

- [ ] **Step 6: Run GREEN**

Run: `mise exec -- mix test test/param_parser/native/plan_builder_test.exs test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs`

Expected: pass.

- [ ] **Step 7: Commit**

```bash
mise exec -- git rm lib/image_plug/transform/output.ex
mise exec -- git add lib/image_plug/transform_chain.ex lib/image_plug/transform_state.ex lib/image_plug/request_runner.ex lib/image_plug/processor.ex lib/image_plug/param_parser/native/plan_builder.ex test/param_parser/native/plan_builder_test.exs test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs
mise exec -- git commit -m "refactor: remove output transform from image pipeline"
```

## Task 8: Execute Materialized Multi-Pipeline Plans

**Files:**
- Modify: `lib/image_plug/processor.ex`
- Modify: `lib/image_plug/decode_planner.ex`
- Create or modify: `lib/image_plug/image_materializer.ex`
- Modify: `test/image_plug/processor_test.exs`
- Modify: `test/image_plug/decode_planner_test.exs`

- [ ] **Step 1: Add materialized multi-pipeline execution test**

Add a focused `Processor` test with two pipelines:

```elixir
plan = %Plan{
  source: %Source.Plain{path: ["images", "cat-300.jpg"]},
  pipelines: [
    %Pipeline{operations: [{FirstTransform, %FirstTransform{}}]},
    %Pipeline{operations: [{SecondTransform, %SecondTransform{}}]}
  ],
  output: %OutputPlan{mode: {:explicit, :jpeg}}
}
```

Use a fake materializer module from opts that sends `:materialized_between_pipelines` and returns the state. Have `SecondTransform.execute/2` send `:second_transform_ran`. Assert ordering:

```elixir
assert_receive :materialized_between_pipelines
assert_receive :second_transform_ran
```

The production implementation should execute `TransformChain.execute/2` for each pipeline, call the materializer after every pipeline except the last, and then continue with the returned state.

The materializer is a first-class dependency:

```elixir
materializer = Keyword.get(opts, :image_materializer, ImagePlug.ImageMaterializer)
```

Define the materializer contract:

```elixir
@callback materialize(TransformState.t(), keyword()) ::
            {:ok, TransformState.t()} | {:error, term()}
```

The fake materializer should return the full `%TransformState{}` so metadata/source-format fields are preserved. Pass the test pid through opts so the assertion does not depend on where materialization runs:

```elixir
test_pid = self()

defmodule FakeMaterializer do
  def materialize(%TransformState{} = state, opts) do
    send(Keyword.fetch!(opts, :test_pid), :materialized_between_pipelines)
    {:ok, state}
  end
end

opts = Keyword.put(opts, :test_pid, test_pid)
```

Use the same pattern for the second transform:

```elixir
def execute(%TransformState{} = state, params) do
  send(params.test_pid, :second_transform_ran)
  {:ok, state}
end
```

- [ ] **Step 2: Add first-pipeline decode planning test**

Add a focused test showing that a random-access operation in the second pipeline does not force random origin decode when the first pipeline is sequential-safe:

```elixir
plan = %Plan{
  source: %Source.Plain{path: ["images", "cat-300.jpg"]},
  pipelines: [
    %Pipeline{operations: [{Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}]},
    %Pipeline{operations: [{Cover, %CoverParams{type: :dimensions, width: {:pixels, 80}, height: {:pixels, 80}, constraint: :none}}]}
  ],
  output: %OutputPlan{mode: {:explicit, :jpeg}}
}

assert DecodePlanner.open_options(plan) == [access: :sequential, fail_on: :error]
```

Keep `DecodePlanner.open_options(chain)` for one pipeline if useful, but add `open_options(%Plan{})` and have `Processor` call that entry point.

- [ ] **Step 3: Implement multi-pipeline processor execution**

Change `Processor` to execute every `%Pipeline{}` in `plan.pipelines`. Materialize after each pipeline except the last through `Keyword.get(opts, :image_materializer, ImagePlug.ImageMaterializer)`. Return explicit errors for empty plans or invalid pipeline shapes instead of relying on pattern-match crashes.

- [ ] **Step 4: Implement first-pipeline decode planning**

Add `DecodePlanner.open_options(%Plan{})` and have `Processor` call it. The implementation should inspect only the first pipeline's operations when choosing origin decode access because later pipelines run after materialization barriers.

- [ ] **Step 5: Run GREEN**

Run: `mise exec -- mix test test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib/image_plug/processor.ex lib/image_plug/decode_planner.ex lib/image_plug/image_materializer.ex test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs
mise exec -- git commit -m "refactor: execute materialized image pipelines"
```

## Task 9: Add Native Parser Multi-Pipeline IR

**Files:**
- Modify: `lib/image_plug/param_parser/native.ex`
- Modify: `lib/image_plug/param_parser/native/parsed_request.ex`
- Modify: `lib/image_plug/param_parser/native/plan_builder.ex`
- Modify: `test/param_parser/native_test.exs`
- Modify: `test/param_parser/native_property_test.exs`
- Modify: `test/param_parser/native/plan_builder_test.exs`

- [ ] **Step 1: Write failing parser contract tests for native parsed request splitting**

Keep native parser successful parse assertions matching `%Plan{}`:

```elixir
assert {:ok,
        %Plan{
          source: %Source.Plain{path: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %OutputPlan{mode: :automatic}
        }} = Native.parse(conn(:get, "/_/plain/images/cat.jpg"))
```

Add a chained-pipeline parser test:

```elixir
assert {:ok,
        %Plan{
          pipelines: [
            %Pipeline{operations: first_operations},
            %Pipeline{operations: second_operations}
          ]
        }} = Native.parse(conn(:get, "/_/w:500/-/h:200/plain/images/cat.jpg"))

assert [{Transform.Contain, first_params}] = first_operations
assert first_params.width == {:pixels, 500}
assert first_params.height == :auto

assert [{Transform.Contain, second_params}] = second_operations
assert second_params.width == :auto
assert second_params.height == {:pixels, 200}
```

Add edge-case tests for malformed chained-pipeline separators:

```elixir
assert {:error, :empty_pipeline_group} =
         Native.parse(conn(:get, "/_/-/w:500/plain/images/cat.jpg"))

assert {:error, :empty_pipeline_group} =
         Native.parse(conn(:get, "/_/w:500/-/plain/images/cat.jpg"))

assert {:error, :empty_pipeline_group} =
         Native.parse(conn(:get, "/_/w:500/-/-/h:200/plain/images/cat.jpg"))
```

Preserve no-op single-pipeline behavior:

```elixir
assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
         Native.parse(conn(:get, "/_/plain/images/cat.jpg"))
```

Add a per-pipeline later-assignment-wins test:

```elixir
assert {:ok,
        %Plan{
          pipelines: [
            %Pipeline{operations: first_operations},
            %Pipeline{operations: second_operations}
          ]
        }} = Native.parse(conn(:get, "/_/w:500/w:600/-/h:200/h:300/plain/images/cat.jpg"))

assert [{Transform.Contain, first_params}] = first_operations
assert first_params.width == {:pixels, 600}

assert [{Transform.Contain, second_params}] = second_operations
assert second_params.height == {:pixels, 300}
```

Keep parser edge-case tests for:

- `format`, `f`, `ext`, and `@extension`
- `@best`
- dangling `@`
- unknown extensions
- `format:auto`
- `auto`, `fill-down`, `gravity:sm`, extend, extend gravity, extend offsets

For unsupported-but-parse-valid semantic values, assert `Native.parse/1` returns `{:error, {:unsupported_output_format, :best}}` or the existing planner error before cache/origin through the parser boundary.

- [ ] **Step 2: Run RED**

Run: `mise exec -- mix test test/param_parser/native_test.exs test/param_parser/native_property_test.exs`

Expected: failures because native parser still treats `-` as `:unsupported_chained_pipeline` and only constructs a single native pipeline request.

- [ ] **Step 3: Parse into native parsed request**

Change `Native.parse/1` internals to:

```text
path segments
-> split options on "-"
-> parse each option group into %PipelineRequest{}
-> parse final plain source and output extension into %ParsedRequest{}
-> Native.PlanBuilder.to_plan(parsed_request)
```

The source and output intent belong to `%ParsedRequest{}`. Per-pipeline geometry/gravity/etc. belong to each `%PipelineRequest{}`.

Reject empty pipeline groups as `{:error, :empty_pipeline_group}`. Empty operation lists are still valid for the existing no-op single-pipeline request, but empty groups introduced by chained separators are not meaningful in this PR.

- [ ] **Step 4: Convert all old `%ProcessingRequest{}` test expectations**

Replace successful native parser test pattern matches on `%ProcessingRequest{}` with `%Plan{}` assertions or helper assertions that inspect `Plan.source`, `Plan.pipelines`, and `Plan.output`. Keep `Native.PlanBuilder` tests for parser-owned IR details.

- [ ] **Step 5: Run GREEN**

Run: `mise exec -- mix test test/param_parser/native_test.exs test/param_parser/native_property_test.exs test/image_plug_test.exs`

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib/image_plug/param_parser/native.ex lib/image_plug/param_parser/native/parsed_request.ex lib/image_plug/param_parser/native/plan_builder.ex test/param_parser/native_test.exs test/param_parser/native_property_test.exs test/param_parser/native/plan_builder_test.exs
mise exec -- git commit -m "feat: parse native chained pipelines into plans"
```

## Task 10: Sweep Old Request And Output Assumptions

**Files:**
- Delete or modify: `lib/image_plug/processing_request.ex`
- Delete or quarantine: `lib/image_plug/pipeline_planner.ex`
- Delete or modify: `test/image_plug/processing_request_test.exs`
- Delete or modify: `test/image_plug/pipeline_planner_test.exs`
- Create: `test/image_plug/architecture_boundary_test.exs`
- Delete or rewrite any migration-only tests added only to prove temporary Task 3/4/7 compatibility paths.
- Modify any remaining files found by:
  - `mise exec -- rg "ProcessingRequest" lib test`
  - `mise exec -- rg "PipelinePlanner" lib test`
  - `mise exec -- rg "ParamParser.Native" lib/image_plug.ex lib/image_plug/request_runner.ex lib/image_plug/processor.ex lib/image_plug/cache.ex lib/image_plug/cache/key.ex lib/image_plug/response_cache.ex lib/image_plug/output_policy.ex lib/image_plug/output_encoder.ex`
  - `mise exec -- rg "Transform.Output|OutputParams|TransformState.output|\\.output" lib test`
  - `mise exec -- rg "append_output|build_plan" lib test`

- [ ] **Step 1: Run search checks**

Run:

```bash
mise exec -- rg "Transform.Output|OutputParams|TransformState.output|append_output" lib test
mise exec -- rg "ProcessingRequest" lib test
mise exec -- rg "PipelinePlanner" lib test
mise exec -- rg "ParamParser.Native" lib/image_plug.ex lib/image_plug/request_runner.ex lib/image_plug/processor.ex lib/image_plug/cache.ex lib/image_plug/cache/key.ex lib/image_plug/response_cache.ex lib/image_plug/output_policy.ex lib/image_plug/output_encoder.ex
```

Expected:

- No `Transform.Output`, `OutputParams`, `TransformState.output`, or `append_output` remain.
- No `ProcessingRequest` references remain.
- No `PipelinePlanner` runtime contract remains. If a mapping helper survives, it is private/internal and is called from `ImagePlug.ParamParser.Native.PlanBuilder`, not from runtime modules.
- No core runtime module aliases or pattern matches on `ImagePlug.ParamParser.Native.*`.

- [ ] **Step 2: Remove old core-visible planning/request contracts**

Delete `ImagePlug.ProcessingRequest` once native parser tests use `ParsedRequest` and `PipelineRequest`. Delete or quarantine `ImagePlug.PipelinePlanner` once all public parsing returns `%Plan{}` and runtime modules consume `%Plan{}` directly. Do not leave a compatibility alias in the final PR; aliases for old request contracts tend to survive and weaken the boundary.

The final state for this PR should be:

- `ImagePlug.ParamParser.Native.ParsedRequest` for whole native URL IR.
- `ImagePlug.ParamParser.Native.PipelineRequest` for one native chain.
- no core-visible `ImagePlug.ProcessingRequest` consumed anywhere.

- [ ] **Step 3: Remove migration-only tests and assertions**

Delete tests whose only purpose was to keep temporary migration paths passing, including:

- tests for `processor_source_input/1` or any `%Plan{}` -> `%ProcessingRequest{}` adapter;
- tests asserting `RequestRunner` appends a temporary `Transform.Output` entry;
- tests asserting `Processor.process_origin/4` receives an external executable chain alongside `%Plan{}`;
- old `PipelinePlanner` compatibility tests;
- old `%ProcessingRequest{}` parser contract tests.

Rewrite only the durable behavioral coverage into final-boundary tests:

- parser tests assert `%Plan{source, pipelines, output}`;
- request runner tests assert cache/output/origin behavior through `%Plan{}`;
- processor tests assert execution from `plan.source` and `plan.pipelines`;
- output tests assert explicit resolved format flow;
- cache tests assert canonical material from `%Plan{}`.

- [ ] **Step 4: Add an architecture boundary regression test**

Add a small test that scans the runtime files most likely to drift:

```elixir
defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @runtime_files [
    "lib/image_plug.ex",
    "lib/image_plug/request_runner.ex",
    "lib/image_plug/processor.ex",
    "lib/image_plug/cache.ex",
    "lib/image_plug/cache/key.ex",
    "lib/image_plug/response_cache.ex",
    "lib/image_plug/output_policy.ex",
    "lib/image_plug/output_encoder.ex"
  ]

  @forbidden [
    "ImagePlug.ParamParser.Native",
    "ImagePlug." <> "Processing" <> "Request",
    "ImagePlug." <> "Pipeline" <> "Planner"
  ]

  test "runtime modules do not depend on native parser IR" do
    for file <- @runtime_files do
      body = File.read!(file)

      for forbidden <- @forbidden do
        refute body =~ forbidden
      end
    end
  end
end
```

- [ ] **Step 5: Run focused sweep tests**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs test/param_parser/native_test.exs test/param_parser/native/plan_builder_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/transform_material_test.exs test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/processor_test.exs test/image_plug/decode_planner_test.exs
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
mise exec -- git add lib test
mise exec -- git commit -m "test: align coverage with execution plan boundary"
```

## Task 11: Full Verification

**Files:**
- No planned source edits unless verification exposes issues.

- [ ] **Step 1: Format**

Run: `mise exec -- mix format`

Expected: no formatting errors.

- [ ] **Step 2: Full tests**

Run: `mise exec -- mix test`

Expected: all tests pass.

- [ ] **Step 3: Compile with warnings as errors**

Run: `mise exec -- mix compile --warnings-as-errors`

Expected: clean compile.

- [ ] **Step 4: Final search audit**

Run:

```bash
mise exec -- rg "Transform.Output|OutputParams|TransformState.output|append_output" lib test
mise exec -- rg "ProcessingRequest|PipelinePlanner" lib test
mise exec -- rg "ParamParser.Native" lib/image_plug.ex lib/image_plug/request_runner.ex lib/image_plug/processor.ex lib/image_plug/cache.ex lib/image_plug/cache/key.ex lib/image_plug/response_cache.ex lib/image_plug/output_policy.ex lib/image_plug/output_encoder.ex
mise exec -- rg "TransformState.*output|output:.*TransformState|TransformState\\{.*output" lib test
```

Expected:

- No output transform execution flow remains.
- `ProcessingRequest` and the old `PipelinePlanner` runtime contract are gone.
- `ImagePlug.ParamParser.Native.*` is not visible to `ImagePlug`, `RequestRunner`, `Processor`, `Cache.Key`, `ResponseCache`, `OutputPolicy`, or `OutputEncoder`.
- `OutputEncoder` does not read output format from `TransformState`.

- [ ] **Step 5: Commit final fixes if any**

```bash
mise exec -- git add lib test
mise exec -- git commit -m "chore: verify execution plan refactor"
```

Skip this commit if there are no verification fixes.

## Acceptance Mapping

- Plug runner no longer knows imgproxy aliases or assignment order after Task 9.
- Image transform pipelines contain only image operations after Task 7.
- OutputEncoder receives explicit resolved formats after Task 6.
- `Transform.Output` entries are removed from transform execution after Task 7.
- Cache key reads normalized source, pipelines, and output intent after Task 5.
- Output negotiation resolves intent without mutating transforms after Task 6.
- Parser-specific semantics remain in `ImagePlug.ParamParser.Native`, `Native.ParsedRequest`, `Native.PipelineRequest`, and `Native.PlanBuilder` after Task 9.
- Ordered future parsers can populate `Plan.pipelines` directly because the final plan stores ordered pipelines and ordered operations inside each pipeline.
- Imgproxy chained pipelines can be represented faithfully because pipeline boundaries materialize intermediates before the next pipeline runs.
- Unsupported parse-valid values fail before cache/origin through `Native.PlanBuilder.to_plan/1` from `Native.parse/1` after Task 9.
- Source-format fallback remains runtime-only through `OutputPolicy.resolve_source_format/2`.
