# Boundary Namespace Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate ImagePlug to architecture-aligned namespaces and enforce module dependency direction with the `boundary` library.

**Architecture:** The public `ImagePlug` module remains the Plug facade. Core request data moves under `ImagePlug.Plan`, parser adapters move under `ImagePlug.Parser`, orchestration and side effects move under `ImagePlug.Runtime`, output negotiation/encoding moves under `ImagePlug.Output`, cache remains under `ImagePlug.Cache`, and transform operations become structs whose modules implement the `ImagePlug.Transform` behaviour. Parser code may construct concrete transform operation structs through exported transform modules; runtime code must treat operations through the generic transform contract and must not name concrete transform modules.

**Tech Stack:** Elixir, Mix, Boundary, ExUnit, StreamData, NimbleOptions, Plug, Req, Image/Vix.

For all `rg` checks where the expected result is "no matches", an exit code of 1 from `rg` is success.

---

## Target Module Map

| Current module | Target module |
| --- | --- |
| `ImagePlug` | `ImagePlug` |
| `ImagePlug.Application` | `ImagePlug.Application` |
| `ImagePlug.SimpleServer` | dev-only demo module moved outside production `lib` path |
| `ImagePlug.Plan` | `ImagePlug.Plan` |
| `ImagePlug.Pipeline` | `ImagePlug.Plan.Pipeline` |
| `ImagePlug.OutputPlan` | `ImagePlug.Plan.Output` |
| `ImagePlug.Source.Plain` | `ImagePlug.Plan.Source.Plain` |
| `ImagePlug.ParamParser` | `ImagePlug.Parser` |
| `ImagePlug.ParamParser.Native` | `ImagePlug.Parser.Native` |
| `ImagePlug.ParamParser.Native.ParsedRequest` | `ImagePlug.Parser.Native.ParsedRequest` |
| `ImagePlug.ParamParser.Native.PipelineRequest` | `ImagePlug.Parser.Native.PipelineRequest` |
| `ImagePlug.ParamParser.Native.PlanBuilder` | `ImagePlug.Parser.Native.PlanBuilder` |
| `ImagePlug.RequestRunner` | `ImagePlug.Runtime.RequestRunner` |
| `ImagePlug.Processor` | `ImagePlug.Runtime.Processor` |
| `ImagePlug.Processor.DecodedOrigin` | `ImagePlug.Runtime.DecodedOrigin` |
| `ImagePlug.Origin` | `ImagePlug.Runtime.Origin` |
| `ImagePlug.Origin.StreamStatus` | `ImagePlug.Runtime.Origin.StreamStatus` |
| `ImagePlug.ResponseCache` | `ImagePlug.Runtime.ResponseCache` |
| new | `ImagePlug.Runtime.ResponseSender` |
| new | `ImagePlug.Runtime.SourceIdentity` |
| new | `ImagePlug.Runtime.Options` |
| `ImagePlug.ImageFormat` | `ImagePlug.Output.Format` |
| `ImagePlug.OutputPolicy` | `ImagePlug.Output.Policy` |
| `ImagePlug.OutputEncoder` | `ImagePlug.Output.Encoder` |
| `ImagePlug.OutputNegotiation` | `ImagePlug.Output.Negotiation` |
| `ImagePlug.Transform` | `ImagePlug.Transform` |
| `ImagePlug.TransformState` | `ImagePlug.Transform.State` |
| `ImagePlug.TransformChain` | `ImagePlug.Transform.Chain` |
| `ImagePlug.DecodePlanner` | `ImagePlug.Transform.DecodePlanner` |
| `ImagePlug.ImageMaterializer` | `ImagePlug.Transform.Materializer` |
| `ImagePlug.Cache.Material` | `ImagePlug.Transform.Material` |
| `ImagePlug.Cache.Material.*` | protocol implementations beside concrete transforms or under `ImagePlug.Transform.Material.*` |
| `ImagePlug.Utils` | `ImagePlug.Transform.Geometry` |
| `ImagePlug.Transform.Scale.ScaleParams` | collapsed into `ImagePlug.Transform.Scale` |
| `ImagePlug.Transform.Cover.CoverParams` | collapsed into `ImagePlug.Transform.Cover` |
| `ImagePlug.Transform.Contain.ContainParams` | collapsed into `ImagePlug.Transform.Contain` |
| `ImagePlug.Transform.Crop.CropParams` | collapsed into `ImagePlug.Transform.Crop` |
| `ImagePlug.Transform.Focus.FocusParams` | collapsed into `ImagePlug.Transform.Focus` |

## Boundary Rules

Use explicit dependency lists so the direction is unambiguous:

```text
ImagePlug deps:
- ImagePlug.Parser
- ImagePlug.Plan
- ImagePlug.Runtime

ImagePlug.Parser deps:
- ImagePlug.Plan
- ImagePlug.Transform

ImagePlug.Plan deps:
- ImagePlug.Transform

ImagePlug.Runtime deps:
- ImagePlug.Plan
- ImagePlug.Cache
- ImagePlug.Output
- ImagePlug.Transform

ImagePlug.Cache deps:
- ImagePlug.Plan
- ImagePlug.Output
- ImagePlug.Transform

ImagePlug.Output deps:
- ImagePlug.Plan

ImagePlug.Transform deps:
- none
```

`ImagePlug.Transform` must export the transform contract, runtime-facing support modules, and concrete operation constructors:

```elixir
use Boundary,
  deps: [],
  exports: [
    State,
    Chain,
    DecodePlanner,
    Materializer,
    Material,
    Scale,
    Cover,
    Contain,
    Crop,
    Focus
  ]
```

Concrete transform modules are exported because parser adapters construct operation structs explicitly, for example `ImagePlug.Transform.Scale.new!/1`. Runtime modules must not name concrete transform modules; they must call generic helpers on `ImagePlug.Transform`, such as `transform_name/1`, `metadata/1`, and `execute/2`.

## Task 1: Add Boundary Dependency and Compiler

**Files:**
- Modify: `mix.exs`
- Test: compile only

- [ ] **Step 1: Add the dependency**

In `deps/0`, add `boundary` as a development/test-only compiler dependency:

```elixir
{:boundary, "~> 0.10", only: [:dev, :test], runtime: false},
```

- [ ] **Step 2: Add environment-scoped compiler configuration**

In `project/0`, add:

```elixir
compilers: extra_compilers(Mix.env()) ++ Mix.compilers(),
```

Add this private function near `elixirc_paths/1`:

```elixir
defp extra_compilers(:prod), do: []
defp extra_compilers(_env), do: [:boundary]
```

Keep Boundary out of production compilation for library consumers.

- [ ] **Step 3: Fetch dependencies**

Run:

```bash
mise exec -- mix deps.get
```

Expected: dependency resolution succeeds and `mix.lock` includes `boundary`.

- [ ] **Step 4: Compile before adding rules**

Run:

```bash
mise exec -- mix compile
```

Expected: compile succeeds. Boundary may be inert until `use Boundary` declarations exist.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore: add boundary compiler"
```

## Task 2: Introduce Struct-Based Transform Operation Contract

**Files:**
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `lib/image_plug/transform/contain.ex`
- Modify: `lib/image_plug/transform/cover.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/focus.ex`
- Modify: `lib/image_plug/transform_chain.ex`
- Modify: `lib/image_plug/decode_planner.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/cache/material/*.ex`
- Modify: `test/transform_chain_test.exs`
- Modify: `test/image_plug/decode_planner_test.exs`
- Modify: `test/image_plug/cache/material_test.exs`
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Modify: transform operation tests, if separate

- [ ] **Step 1: Add contract tests**

Add tests that describe the struct-based operation contract:

```elixir
test "transform modules construct operation structs" do
  assert %ImagePlug.Transform.Scale{
           type: :dimensions,
           width: {:pixels, 10},
           height: :auto
         } =
           ImagePlug.Transform.Scale.new!(
             type: :dimensions,
             width: {:pixels, 10},
             height: :auto
           )
end

test "transform modules support fallible construction" do
  assert {:ok, %ImagePlug.Transform.Scale{}} =
           ImagePlug.Transform.Scale.new(
             type: :dimensions,
             width: {:pixels, 10},
             height: :auto
           )
end

test "fallible construction returns errors for missing required attrs" do
  assert {:error, _reason} = ImagePlug.Transform.Scale.new(type: :dimensions)
end

test "transform name is delegated to operation module" do
  operation =
    ImagePlug.Transform.Scale.new!(
      type: :dimensions,
      width: {:pixels, 10},
      height: :auto
    )

  assert ImagePlug.Transform.transform_name(operation) == :scale
end

test "metadata is delegated to operation module" do
  operation =
    ImagePlug.Transform.Contain.new!(
      type: :dimensions,
      width: {:pixels, 10},
      height: :auto,
      constraint: :max,
      letterbox: false
    )

  assert ImagePlug.Transform.metadata(operation) == %{access: :sequential}
end
```

- [ ] **Step 2: Run transform tests and verify failure**

Run:

```bash
mise exec -- mix test test/transform_chain_test.exs test/image_plug/decode_planner_test.exs
```

Expected: fails because `new/1`, `new!/1`, `name/1`, generic transform dispatch helpers, struct operations, and updated chain/decode planner code do not exist yet.

- [ ] **Step 3: Update `ImagePlug.Transform`**

Make `ImagePlug.Transform` the behaviour and generic dispatcher:

```elixir
alias ImagePlug.TransformState

@type attrs() :: keyword() | map()
@type operation() :: struct()

@callback new(attrs() | operation()) :: {:ok, operation()} | {:error, term()}
@callback new!(attrs() | operation()) :: operation()
@callback name(operation()) :: atom()
@callback metadata(operation()) :: map()
@callback execute(operation(), TransformState.t()) :: TransformState.t()

@spec transform_name(operation()) :: atom()
def transform_name(%module{} = operation), do: module.name(operation)

@spec metadata(operation()) :: map()
def metadata(%module{} = operation), do: module.metadata(operation)

@spec execute(operation(), TransformState.t()) :: TransformState.t()
def execute(%module{} = operation, %TransformState{} = state), do: module.execute(operation, state)
```

Task 6 later renames `ImagePlug.TransformState` to `ImagePlug.Transform.State`; update this behaviour alias and specs during that namespace move.

- [ ] **Step 4: Collapse nested params structs into transform structs**

For each concrete transform:

```text
ImagePlug.Transform.Scale.ScaleParams -> ImagePlug.Transform.Scale
ImagePlug.Transform.Contain.ContainParams -> ImagePlug.Transform.Contain
ImagePlug.Transform.Cover.CoverParams -> ImagePlug.Transform.Cover
ImagePlug.Transform.Crop.CropParams -> ImagePlug.Transform.Crop
ImagePlug.Transform.Focus.FocusParams -> ImagePlug.Transform.Focus
```

Update each transform module to define its params directly with `defstruct`. Replace `%ScaleParams{}` with `%__MODULE__{}` inside `ImagePlug.Transform.Scale`, and use the same pattern for the other concrete transform modules. Update callback order from:

```elixir
def execute(%TransformState{} = state, %__MODULE__{} = operation)
```

to:

```elixir
def execute(%__MODULE__{} = operation, %TransformState{} = state)
```

- [ ] **Step 5: Add `new/1`, `new!/1`, and `name/1` to each transform**

Each concrete transform module should expose this shape, with the name adjusted per module:

```elixir
@impl ImagePlug.Transform
def new(attrs) do
  {:ok, new!(attrs)}
rescue
  exception in [ArgumentError, KeyError] ->
    {:error, exception}
end

@impl ImagePlug.Transform
def new!(%__MODULE__{} = operation), do: operation

def new!(attrs) when is_list(attrs) or is_map(attrs) do
  attrs
  |> validate_attrs!()
  |> then(&struct!(__MODULE__, &1))
end

@impl ImagePlug.Transform
def name(%__MODULE__{}), do: :scale
```

`validate_attrs!/1` must preserve existing params validation semantics or introduce equivalent transform-level validation for required keys and accepted values. If a transform uses `NimbleOptions` for constructor validation, include `NimbleOptions.ValidationError` in the `new/1` rescue list for that module. `new/1` should wrap only construction and validation errors. It must not become a catch-all for execution-time failures or unrelated code paths.

Use these names:

```text
Scale.name(_) -> :scale
Contain.name(_) -> :contain
Cover.name(_) -> :cover
Crop.name(_) -> :crop
Focus.name(_) -> :focus
```

Keep each module's existing `metadata/1` semantics and update it to accept the operation struct directly.

- [ ] **Step 6: Make chain and decode planner depend on the operation type**

Update `ImagePlug.TransformChain.item/0` and `t/0` to avoid direct concrete transform type references:

```elixir
@type item() :: Transform.operation()
@type t() :: [item()]
```

Update `TransformChain.execute/2` to dispatch through the contract:

```elixir
next_state = Transform.execute(operation, state)
```

Update `DecodePlanner.access_requirement/1` to call safe metadata dispatch. Keep optimized decoding conservative by falling back to random access if metadata raises:

```elixir
defp access_requirement(operation) do
  operation
  |> safe_metadata()
  |> access_from_metadata()
end

defp safe_metadata(operation) do
  Transform.metadata(operation)
rescue
  _exception -> %{access: :random}
catch
  _kind, _reason -> %{access: :random}
end
```

`ImagePlug.Transform.metadata/1` itself should remain strict. The rescue belongs only in `DecodePlanner`, where `:random` means "do not use the sequential one-pass optimization" and is the safe default for unknown or invalid metadata.

- [ ] **Step 7: Update material protocol implementations for struct operations**

Before Task 7 moves the protocol, update implementations to target concrete transform structs directly:

```elixir
defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Scale do
  def material(%ImagePlug.Transform.Scale{} = operation) do
    [
      op: :scale,
      type: operation.type,
      width: operation.width,
      height: operation.height
    ]
  end
end
```

Repeat for `Contain`, `Cover`, `Crop`, and `Focus`. Update cache projection from tuple destructuring to direct protocol dispatch:

```elixir
defp operation_material(operation) do
  Material.material(operation)
end
```

Update cacheability checks in `RequestRunner` from:

```elixir
Enum.all?(operations, fn {_module, params} -> Material.impl_for(params) end)
```

to:

```elixir
Enum.all?(operations, fn operation -> Material.impl_for(operation) end)
```

By the end of this task, no `*.ScaleParams`, `*.CoverParams`, `*.ContainParams`, `*.CropParams`, or `*.FocusParams` references should remain.

- [ ] **Step 8: Run focused tests and compile**

Run:

```bash
mise exec -- mix test test/transform_chain_test.exs test/image_plug/decode_planner_test.exs
mise exec -- mix test test/image_plug/cache/material_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
rg "(ScaleParams|ContainParams|CoverParams|CropParams|FocusParams)" lib test
rg "\\{ImagePlug\\.Transform|\\{Transform\\." lib test -g "!lib/image_plug/param_parser/**" -g "!test/param_parser/**"
mise exec -- mix compile --warnings-as-errors
```

Expected: tests and compile pass. The params `rg` check returns no matches. The tuple `rg` check returns no non-parser matches; Task 3 removes the remaining parser tuple construction.

- [ ] **Step 9: Commit**

```bash
git add lib test
git commit -m "refactor: introduce struct-based transform operations"
```

## Task 3: Update Native Parser to Use Transform Constructors

**Files:**
- Modify: `lib/image_plug/param_parser/native/plan_builder.ex`
- Test: `test/param_parser/native/plan_builder_test.exs`
- Test: `test/param_parser/native_test.exs`
- Test: `test/param_parser/native_property_test.exs`

- [ ] **Step 1: Add parser architecture test for tuple and params leaks**

Add an assertion to `test/param_parser/native/plan_builder_test.exs` or a new architecture test:

```elixir
test "native parser builds transforms through operation constructors" do
  body = File.read!("lib/image_plug/param_parser/native/plan_builder.ex")

  refute body =~ "ScaleParams"
  refute body =~ "ContainParams"
  refute body =~ "CoverParams"
  refute body =~ "CropParams"
  refute body =~ "FocusParams"
  refute body =~ "{ImagePlug.Transform."
  refute body =~ "{Transform."
end
```

This parser string test is transitional migration scaffolding. Remove it in Task 12 if Boundary and the final runtime architecture test make it redundant.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
mise exec -- mix test test/param_parser/native/plan_builder_test.exs
```

Expected: fails because `PlanBuilder` currently constructs concrete transform tuples.

- [ ] **Step 3: Replace tuple construction with constructors**

In `PlanBuilder`, replace tuple construction with concrete transform constructors:

```elixir
defp scale(width, height) do
  Transform.Scale.new!(
    type: :dimensions,
    width: width,
    height: height
  )
end

defp contain(width, height, %PipelineRequest{} = request) do
  Transform.Contain.new!(
    type: :dimensions,
    width: width,
    height: height,
    constraint: contain_constraint(request.enlarge),
    letterbox: false
  )
end

defp cover(width, height, %PipelineRequest{} = request) do
  Transform.Cover.new!(
    type: :dimensions,
    width: width,
    height: height,
    constraint: cover_constraint(request.enlarge)
  )
end

defp crop(width, height, crop_attrs) do
  Transform.Crop.new!(
    Keyword.merge(crop_attrs, width: width, height: height)
  )
end

defp maybe_prepend_focus([operation | _rest] = operations, gravity) do
  if Transform.transform_name(operation) == :cover do
    [Transform.Focus.new!(type: focus_type(gravity)) | operations]
  else
    operations
  end
end
```

Preserve exact existing crop and focus semantics while changing only the operation representation.

- [ ] **Step 4: Run parser tests and compile**

Run:

```bash
mise exec -- mix test test/param_parser/native/plan_builder_test.exs test/param_parser/native_test.exs test/param_parser/native_property_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/image_plug/param_parser/native/plan_builder.ex test/param_parser/native/plan_builder_test.exs
git commit -m "refactor: build native parser plans through transform constructors"
```

## Task 4: Migrate Plan Namespace

**Files:**
- Move: `lib/image_plug/pipeline.ex` to `lib/image_plug/plan/pipeline.ex`
- Move: `lib/image_plug/output_plan.ex` to `lib/image_plug/plan/output.ex`
- Move: `lib/image_plug/source/plain.ex` to `lib/image_plug/plan/source/plain.ex`
- Modify: `lib/image_plug/plan.ex`
- Modify: all source and test references

- [ ] **Step 1: Move files with git**

Run:

```bash
git mv lib/image_plug/pipeline.ex lib/image_plug/plan/pipeline.ex
git mv lib/image_plug/output_plan.ex lib/image_plug/plan/output.ex
git mv lib/image_plug/source/plain.ex lib/image_plug/plan/source/plain.ex
```

- [ ] **Step 2: Rename modules**

Change module declarations:

```elixir
defmodule ImagePlug.Plan.Pipeline do
```

```elixir
defmodule ImagePlug.Plan.Output do
```

```elixir
defmodule ImagePlug.Plan.Source.Plain do
```

Update `ImagePlug.Plan` aliases to:

```elixir
alias ImagePlug.Plan.Output
alias ImagePlug.Plan.Pipeline
alias ImagePlug.Plan.Source.Plain
```

- [ ] **Step 3: Update references**

Use project-wide replacement:

```bash
rg -l "ImagePlug\\.Pipeline|ImagePlug\\.OutputPlan|ImagePlug\\.Source\\.Plain|alias ImagePlug\\.Pipeline|alias ImagePlug\\.OutputPlan|alias ImagePlug\\.Source\\.Plain" lib test | xargs perl -pi -e 's/ImagePlug\\.Pipeline/ImagePlug.Plan.Pipeline/g; s/ImagePlug\\.OutputPlan/ImagePlug.Plan.Output/g; s/ImagePlug\\.Source\\.Plain/ImagePlug.Plan.Source.Plain/g; s/alias ImagePlug\\.Pipeline/alias ImagePlug.Plan.Pipeline/g; s/alias ImagePlug\\.OutputPlan/alias ImagePlug.Plan.Output/g; s/alias ImagePlug\\.Source\\.Plain/alias ImagePlug.Plan.Source.Plain/g'
```

- [ ] **Step 4: Run focused plan/parser/runtime tests**

Run:

```bash
mise exec -- mix test test/image_plug/plan_test.exs test/param_parser/native/plan_builder_test.exs test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "refactor: move request model under plan namespace"
```

## Task 5: Migrate Output Namespace

**Files:**
- Move: `lib/image_plug/image_format.ex` to `lib/image_plug/output/format.ex`
- Move: `lib/image_plug/output_policy.ex` to `lib/image_plug/output/policy.ex`
- Move: `lib/image_plug/output_encoder.ex` to `lib/image_plug/output/encoder.ex`
- Move: `lib/image_plug/output_negotiation.ex` to `lib/image_plug/output/negotiation.ex`
- Modify: all source and test references

- [ ] **Step 1: Move files**

```bash
git mv lib/image_plug/image_format.ex lib/image_plug/output/format.ex
git mv lib/image_plug/output_policy.ex lib/image_plug/output/policy.ex
git mv lib/image_plug/output_encoder.ex lib/image_plug/output/encoder.ex
git mv lib/image_plug/output_negotiation.ex lib/image_plug/output/negotiation.ex
```

- [ ] **Step 2: Rename modules**

Use these declarations:

```elixir
defmodule ImagePlug.Output.Format do
defmodule ImagePlug.Output.Policy do
defmodule ImagePlug.Output.Encoder do
defmodule ImagePlug.Output.Negotiation do
```

- [ ] **Step 3: Update references**

Replace:

```text
ImagePlug.ImageFormat -> ImagePlug.Output.Format
ImagePlug.OutputPolicy -> ImagePlug.Output.Policy
ImagePlug.OutputEncoder -> ImagePlug.Output.Encoder
ImagePlug.OutputNegotiation -> ImagePlug.Output.Negotiation
```

- [ ] **Step 4: Run output and cache-key tests**

```bash
mise exec -- mix test test/image_plug/output_encoder_test.exs test/image_plug/output_negotiation_test.exs test/image_plug/output_negotiation_property_test.exs test/image_plug/output_policy_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "refactor: move output modules under output namespace"
```

## Task 6: Migrate Transform Infrastructure Namespace

**Files:**
- Move: `lib/image_plug/transform_state.ex` to `lib/image_plug/transform/state.ex`
- Move: `lib/image_plug/transform_chain.ex` to `lib/image_plug/transform/chain.ex`
- Move: `lib/image_plug/decode_planner.ex` to `lib/image_plug/transform/decode_planner.ex`
- Move: `lib/image_plug/image_materializer.ex` to `lib/image_plug/transform/materializer.ex`
- Move: `lib/image_plug/utils.ex` to `lib/image_plug/transform/geometry.ex`
- Modify: all source and test references

- [ ] **Step 1: Move files**

```bash
git mv lib/image_plug/transform_state.ex lib/image_plug/transform/state.ex
git mv lib/image_plug/transform_chain.ex lib/image_plug/transform/chain.ex
git mv lib/image_plug/decode_planner.ex lib/image_plug/transform/decode_planner.ex
git mv lib/image_plug/image_materializer.ex lib/image_plug/transform/materializer.ex
git mv lib/image_plug/utils.ex lib/image_plug/transform/geometry.ex
```

- [ ] **Step 2: Rename modules**

Use these declarations:

```elixir
defmodule ImagePlug.Transform.State do
defmodule ImagePlug.Transform.Chain do
defmodule ImagePlug.Transform.DecodePlanner do
defmodule ImagePlug.Transform.Materializer do
defmodule ImagePlug.Transform.Geometry do
```

- [ ] **Step 3: Update operation modules**

In each concrete transform module, update imports and aliases:

```elixir
import ImagePlug.Transform.State
import ImagePlug.Transform.Geometry

alias ImagePlug.Transform.State
```

Update callback specs to use `State.t()`.

- [ ] **Step 4: Update runtime modules**

Replace:

```text
ImagePlug.TransformState -> ImagePlug.Transform.State
ImagePlug.TransformChain -> ImagePlug.Transform.Chain
ImagePlug.DecodePlanner -> ImagePlug.Transform.DecodePlanner
ImagePlug.ImageMaterializer -> ImagePlug.Transform.Materializer
ImagePlug.Utils -> ImagePlug.Transform.Geometry
```

Update `ImagePlug.Transform` itself to alias `ImagePlug.Transform.State` and to use `State.t()` in the `execute/2` callback and dispatcher spec.

- [ ] **Step 5: Run transform and processor tests**

```bash
mise exec -- mix test test/transform_chain_test.exs test/image_plug/decode_planner_test.exs test/image_plug/image_materializer_test.exs test/image_plug/processor_test.exs test/image_plug/sequential_compatibility_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add lib test
git commit -m "refactor: move transform runtime support under transform namespace"
```

## Task 7: Move Transform Material Projection Into Transform Boundary

**Files:**
- Move: `lib/image_plug/cache/material.ex` to `lib/image_plug/transform/material.ex`
- Move: `lib/image_plug/cache/material/*.ex` to `lib/image_plug/transform/material/*.ex`
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/request_runner.ex`
- Modify: cache material tests

Task 7 should be a namespace-only protocol move. Struct-based protocol targets were introduced in Task 2 under the current `ImagePlug.Cache.Material` namespace; this task moves that protocol to `ImagePlug.Transform.Material` and updates references.

`ImagePlug.Transform.Material` must produce canonical, cache-agnostic operation fingerprints only. It must not reference cache entries, output formats, request options, Plug connections, or runtime state.

- [ ] **Step 1: Move protocol files**

```bash
git mv lib/image_plug/cache/material.ex lib/image_plug/transform/material.ex
mkdir -p lib/image_plug/transform/material
git mv lib/image_plug/cache/material/*.ex lib/image_plug/transform/material/
```

- [ ] **Step 2: Rename protocol**

Change:

```elixir
defprotocol ImagePlug.Transform.Material do
  @spec material(t()) :: keyword()
  def material(params)
end
```

Update defimpl declarations:

```elixir
defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Scale do
  def material(%ImagePlug.Transform.Scale{} = operation) do
    [
      op: :scale,
      type: operation.type,
      width: operation.width,
      height: operation.height
    ]
  end
end
```

- [ ] **Step 3: Update cache references**

Replace `ImagePlug.Cache.Material` with `ImagePlug.Transform.Material`.

In `Cache.Key`, the operation projection should remain parser-independent:

```elixir
defp operation_material(operation) do
  Material.material(operation)
end
```

- [ ] **Step 4: Run cache tests**

```bash
mise exec -- mix test test/image_plug/cache/material_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "refactor: move transform material projection into transform boundary"
```

## Task 8A: Mechanically Migrate Runtime Namespace

**Files:**
- Create: `lib/image_plug/runtime.ex`
- Move: `lib/image_plug/request_runner.ex` to `lib/image_plug/runtime/request_runner.ex`
- Move: `lib/image_plug/processor.ex` to `lib/image_plug/runtime/processor.ex`
- Move: `lib/image_plug/origin.ex` to `lib/image_plug/runtime/origin.ex`
- Move: `lib/image_plug/origin/stream_status.ex` to `lib/image_plug/runtime/origin/stream_status.ex`
- Move: `lib/image_plug/response_cache.ex` to `lib/image_plug/runtime/response_cache.ex`
- Modify: runtime tests

- [ ] **Step 1: Create runtime root module and move runtime files**

Create `lib/image_plug/runtime.ex`:

```elixir
defmodule ImagePlug.Runtime do
  @moduledoc false
end
```

```bash
git mv lib/image_plug/request_runner.ex lib/image_plug/runtime/request_runner.ex
git mv lib/image_plug/processor.ex lib/image_plug/runtime/processor.ex
git mv lib/image_plug/origin.ex lib/image_plug/runtime/origin.ex
git mv lib/image_plug/origin/stream_status.ex lib/image_plug/runtime/origin/stream_status.ex
git mv lib/image_plug/response_cache.ex lib/image_plug/runtime/response_cache.ex
```

- [ ] **Step 2: Rename moved modules and references**

Rename module declarations:

```elixir
defmodule ImagePlug.Runtime.RequestRunner do
defmodule ImagePlug.Runtime.Processor do
defmodule ImagePlug.Runtime.Origin do
defmodule ImagePlug.Runtime.Origin.StreamStatus do
defmodule ImagePlug.Runtime.ResponseCache do
```

Replace:

```text
ImagePlug.RequestRunner -> ImagePlug.Runtime.RequestRunner
ImagePlug.Processor -> ImagePlug.Runtime.Processor
ImagePlug.Origin -> ImagePlug.Runtime.Origin
ImagePlug.Origin.StreamStatus -> ImagePlug.Runtime.Origin.StreamStatus
ImagePlug.ResponseCache -> ImagePlug.Runtime.ResponseCache
```

- [ ] **Step 3: Run runtime and plug tests**

```bash
mise exec -- mix test test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs test/image_plug/origin_test.exs test/image_plug/response_cache_test.exs test/image_plug_test.exs test/simple_server_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add lib test
git commit -m "refactor: move runtime modules under runtime namespace"
```

## Task 8B: Extract Runtime Support Modules

**Files:**
- Create: `lib/image_plug/runtime/decoded_origin.ex`
- Create: `lib/image_plug/runtime/source_identity.ex`
- Create: `lib/image_plug/runtime/options.ex`
- Modify: `lib/image_plug/runtime/processor.ex`
- Modify: `lib/image_plug.ex`
- Modify: plug/runtime tests

- [ ] **Step 1: Extract nested decoded origin struct**

Create `lib/image_plug/runtime/decoded_origin.ex`:

```elixir
defmodule ImagePlug.Runtime.DecodedOrigin do
  @moduledoc false

  alias ImagePlug.Runtime.Origin

  @enforce_keys [:decode_options, :image, :origin_response, :source_format]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          origin_response: Origin.Response.t(),
          source_format: :avif | :webp | :jpeg | :png | nil
        }
end
```

Remove the nested `defmodule DecodedOrigin` from `Runtime.Processor` and alias `ImagePlug.Runtime.DecodedOrigin`.

- [ ] **Step 2: Extract source identity**

Create `lib/image_plug/runtime/source_identity.ex`:

```elixir
defmodule ImagePlug.Runtime.SourceIdentity do
  @moduledoc false

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Runtime.Origin

  @spec resolve(Plan.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%Plan{source: %Plain{path: source_path}}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    Origin.build_url(root_url, source_path)
  end

  def resolve(%Plan{source: source}, _opts) do
    {:error, {:unsupported_source, source}}
  end
end
```

- [ ] **Step 3: Extract option validation and normalize parser options in init**

Create `lib/image_plug/runtime/options.ex`:

```elixir
defmodule ImagePlug.Runtime.Options do
  @moduledoc false

  alias ImagePlug.Cache

  @required_options_schema NimbleOptions.new!(
                             parser: [type: :atom, required: true],
                             root_url: [type: :string, required: true]
                           )

  def validate!(opts) do
    opts
    |> normalize_parser_option()
    |> Cache.validate_config!()
    |> validate_required_opts!()
  end

  defp normalize_parser_option(opts) do
    case Keyword.fetch(opts, :parser) do
      {:ok, _parser} -> opts
      :error -> Keyword.put(opts, :parser, Keyword.fetch!(opts, :param_parser))
    end
  end

  defp validate_required_opts!(opts) do
    required_opts = Keyword.take(opts, [:parser, :root_url])

    case NimbleOptions.validate(required_opts, @required_options_schema) do
      {:ok, _validated_opts} ->
        opts

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePlug options: #{Exception.message(error)}"
    end
  end
end
```

Update `ImagePlug.init/1` to delegate validation and normalization:

```elixir
@impl Plug
def init(opts), do: Runtime.Options.validate!(opts)
```

After this step, `ImagePlug.call/2` may safely read:

```elixir
parser = Keyword.fetch!(opts, :parser)
```

This preserves `:param_parser` during migration while introducing the cleaner `:parser` option. Because the library is greenfield, a later cleanup task may remove `:param_parser`.

- [ ] **Step 4: Add focused option normalization tests**

In `test/image_plug_test.exs`, add tests covering both option shapes during migration:

```elixir
test "init normalizes parser option" do
  opts = ImagePlug.init(parser: ImagePlug.ParamParser.Native, root_url: "https://example.test")

  assert Keyword.fetch!(opts, :parser) == ImagePlug.ParamParser.Native
end

test "init temporarily accepts legacy param_parser option" do
  opts = ImagePlug.init(param_parser: ImagePlug.ParamParser.Native, root_url: "https://example.test")

  assert Keyword.fetch!(opts, :parser) == ImagePlug.ParamParser.Native
end
```

- [ ] **Step 5: Run runtime and plug tests**

```bash
mise exec -- mix test test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs test/image_plug_test.exs test/simple_server_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add lib test
git commit -m "refactor: extract runtime request support modules"
```

## Task 8C: Extract Response Sender and Slim Plug Facade

**Files:**
- Create: `lib/image_plug/runtime/response_sender.ex`
- Modify: `lib/image_plug.ex`
- Modify: `test/image_plug_test.exs`
- Modify: `test/image_plug/request_runner_test.exs`

- [ ] **Step 1: Extract Plug response sending**

Move response delivery from `ImagePlug` into `ImagePlug.Runtime.ResponseSender`. The public function should be:

```elixir
@spec send_result(Plug.Conn.t(), RequestRunner.delivery() | RequestRunner.error(), keyword()) ::
        Plug.Conn.t()
def send_result(conn, result, opts)

@spec send_origin_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
def send_origin_error(conn, error)

@spec send_origin_error(Plug.Conn.t(), term(), [{String.t(), String.t()}]) :: Plug.Conn.t()
def send_origin_error(conn, error, response_headers)
```

It should own cache entry delivery, image streaming, response headers, and error responses. It may depend on `ImagePlug.Cache.Entry`, `ImagePlug.Output.Format`, and `ImagePlug.Transform.State`.

- [ ] **Step 2: Slim `ImagePlug`**

After extraction, `ImagePlug.call/2` should look like:

```elixir
@impl Plug
def call(%Plug.Conn{} = conn, opts) do
  parser = Keyword.fetch!(opts, :parser)

  with {:ok, %Plan{} = plan} <- parser.parse(conn) |> wrap_parser_error(),
       {:ok, origin_identity} <- SourceIdentity.resolve(plan, opts) |> wrap_origin_error() do
    result = RequestRunner.run(conn, plan, origin_identity, opts)
    ResponseSender.send_result(conn, result, opts)
  else
    {:error, {:parser, error}} ->
      parser.handle_error(conn, error)

    {:error, {:origin, error}} ->
      ResponseSender.send_origin_error(conn, error)
  end
end
```

- [ ] **Step 3: Run runtime and plug tests**

```bash
mise exec -- mix test test/image_plug/request_runner_test.exs test/image_plug/processor_test.exs test/image_plug/origin_test.exs test/image_plug/response_cache_test.exs test/image_plug_test.exs test/simple_server_test.exs
rg "send_resp|send_file|send_chunked|chunk\\(|put_resp_header|put_resp_content_type" lib/image_plug.ex lib/image_plug/runtime
mise exec -- mix compile --warnings-as-errors
```

Expected: tests and compile pass. The `rg` check should show response delivery mechanics owned by `ImagePlug.Runtime.ResponseSender`, with no response delivery logic remaining in `lib/image_plug.ex`.

- [ ] **Step 4: Commit**

```bash
git add lib test
git commit -m "refactor: move plug response delivery into runtime"
```

## Task 9: Migrate Parser Namespace

**Files:**
- Move: `lib/image_plug/param_parser.ex` to `lib/image_plug/parser.ex`
- Move: `lib/image_plug/param_parser/native.ex` to `lib/image_plug/parser/native.ex`
- Move: `lib/image_plug/param_parser/native/*.ex` to `lib/image_plug/parser/native/*.ex`
- Move: `test/param_parser` to `test/parser`
- Modify: parser tests
- Modify: `lib/simple_server.ex` before Task 10 moves it to `dev/simple_server.ex`
- Modify: README examples if present

- [ ] **Step 1: Move files**

```bash
git mv lib/image_plug/param_parser.ex lib/image_plug/parser.ex
git mv lib/image_plug/param_parser/native.ex lib/image_plug/parser/native.ex
mkdir -p lib/image_plug/parser/native
git mv lib/image_plug/param_parser/native/*.ex lib/image_plug/parser/native/
git mv test/param_parser test/parser
```

- [ ] **Step 2: Rename modules**

Use:

```elixir
defmodule ImagePlug.Parser do
defmodule ImagePlug.Parser.Native do
defmodule ImagePlug.Parser.Native.ParsedRequest do
defmodule ImagePlug.Parser.Native.PipelineRequest do
defmodule ImagePlug.Parser.Native.PlanBuilder do
```

Update behaviour declarations:

```elixir
@behaviour ImagePlug.Parser
```

- [ ] **Step 3: Update option name in examples**

Change `param_parser: ImagePlug.ParamParser.Native` to:

```elixir
parser: ImagePlug.Parser.Native
```

Update the temporary option normalization tests from `ImagePlug.ParamParser.Native` to `ImagePlug.Parser.Native` after the parser namespace move.

- [ ] **Step 4: Run parser and plug tests**

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/parser/native_property_test.exs test/image_plug_test.exs test/simple_server_test.exs
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib test README.md
git commit -m "refactor: move parameter parsers under parser namespace"
```

## Task 10: Add Boundary Declarations

**Files:**
- Modify: `lib/image_plug.ex`
- Modify: `lib/application.ex`
- Move: `lib/simple_server.ex` to `dev/simple_server.ex`
- Modify: `mix.exs`
- Modify: `lib/image_plug/plan.ex`
- Modify: `lib/image_plug/parser.ex`
- Modify: `lib/image_plug/runtime.ex`
- Modify: `lib/image_plug/cache.ex`
- Create: `lib/image_plug/output.ex`
- Modify: `lib/image_plug/transform.ex`

- [ ] **Step 0: Run pre-Boundary dependency checks**

Run:

```bash
rg "ImagePlug\\.(Parser|Runtime|Cache|Output|Plan)" lib/image_plug/transform lib/image_plug/transform*.ex
rg "ImagePlug\\.Transform\\.(Scale|Contain|Cover|Crop|Focus)" lib/image_plug/plan lib/image_plug/plan.ex
mise exec -- mix xref graph --label compile-connected
```

Expected: transform modules do not depend on `Parser`, `Runtime`, `Cache`, `Output`, or `Plan`; plan modules do not name concrete transform operation modules; no compile-connected cycles are reported.

If supported by the local Elixir version, optionally run the more specific cycle-only output:

```bash
mise exec -- mix xref graph --format cycles --label compile-connected --no-compile --no-deps-check --no-archives-check
```

- [ ] **Step 0A: Move demo server out of production compilation**

Because `ImagePlug.SimpleServer` is a demo/dev-only server, keep it out of the production library boundary graph.

```bash
mkdir -p dev
git mv lib/simple_server.ex dev/simple_server.ex
```

Update `elixirc_paths/1` in `mix.exs`. Keep `dev` compiled in `:test` so `test/simple_server_test.exs` can still exercise the demo server while keeping it out of production compilation:

```elixir
defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
defp elixirc_paths(:dev), do: ["lib", "dev"]
defp elixirc_paths(_env), do: ["lib"]
```

If `ImagePlug.Application` currently starts `ImagePlug.SimpleServer`, remove that child from supervision or gate it to dev-only before adding Boundary declarations. `ImagePlug.Application` must not depend on `ImagePlug.SimpleServer`.

`dev/simple_server.ex` may declare its own top-level dev-only boundary:

```elixir
defmodule ImagePlug.SimpleServer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug,
      ImagePlug.Parser
    ]

  # existing demo server code
end
```

- [ ] **Step 1: Add root facade boundary**

In `ImagePlug`:

```elixir
use Boundary,
  deps: [
    ImagePlug.Parser,
    ImagePlug.Plan,
    ImagePlug.Runtime
  ],
  exports: []
```

`exports: []` intentionally exports no `ImagePlug.*` child modules from the facade boundary. The `ImagePlug` module itself remains the public Plug module.

- [ ] **Step 2: Add Plan boundary**

In `ImagePlug.Plan`:

```elixir
use Boundary,
  deps: [ImagePlug.Transform],
  exports: [
    Pipeline,
    Output,
    Source.Plain
  ]
```

- [ ] **Step 3: Add Parser boundary**

In `ImagePlug.Parser`:

```elixir
use Boundary,
  deps: [
    ImagePlug.Plan,
    ImagePlug.Transform
  ],
  exports: [Native]
```

In `ImagePlug.Parser.Native`:

```elixir
use Boundary,
  deps: [
    ImagePlug.Parser,
    ImagePlug.Plan,
    ImagePlug.Transform
  ],
  exports: []
```

After adding this nested boundary, run the parser tests. Default to keeping implementation modules such as `ImagePlug.Parser.Native.PlanBuilder` private and moving tests through `ImagePlug.Parser.Native.parse/1`. Export `ParsedRequest`, `PipelineRequest`, or `PlanBuilder` only if they are intentionally architectural parser APIs; otherwise avoid exporting them just to satisfy tests.

- [ ] **Step 4: Add Runtime boundary**

In `ImagePlug.Runtime`:

```elixir
use Boundary,
  deps: [
    ImagePlug.Plan,
    ImagePlug.Cache,
    ImagePlug.Output,
    ImagePlug.Transform
  ],
  exports: [
    RequestRunner,
    Origin,
    ResponseSender,
    SourceIdentity,
    Options
  ]
```

Do not export `Processor` or `ResponseCache` unless a non-runtime boundary actually needs to call them. They should remain internal runtime implementation details when only `RequestRunner` uses them.

If tests directly exercise `Runtime.Processor` or `Runtime.ResponseCache`, prefer testing through `Runtime.RequestRunner`; export them only if they are intentionally architectural runtime APIs.

- [ ] **Step 5: Add Cache boundary**

In `ImagePlug.Cache`:

```elixir
use Boundary,
  deps: [
    ImagePlug.Plan,
    ImagePlug.Output,
    ImagePlug.Transform
  ],
  exports: [
    Entry,
    Key,
    FileSystem
  ]
```

- [ ] **Step 6: Add Output boundary**

Create `lib/image_plug/output.ex`:

```elixir
defmodule ImagePlug.Output do
  @moduledoc false

  use Boundary,
    deps: [ImagePlug.Plan],
    exports: [
      Format,
      Policy,
      Encoder,
      Negotiation
    ]
end
```

- [ ] **Step 7: Add Transform boundary**

In `ImagePlug.Transform`:

```elixir
use Boundary,
  deps: [],
  exports: [
    State,
    Chain,
    DecodePlanner,
    Materializer,
    Material,
    Scale,
    Cover,
    Contain,
    Crop,
    Focus
  ]
```

Export concrete transform modules because parsers construct operation structs through those modules. Runtime code still must not name these concrete modules; that rule is enforced by the targeted architecture test in Task 11.

- [ ] **Step 8: Add top-level application boundary**

In `ImagePlug.Application`:

```elixir
use Boundary,
  top_level?: true,
  deps: []
```

Use `deps: []` only if `ImagePlug.Application` has no `ImagePlug` child boundary dependencies after removing `SimpleServer`; otherwise declare only the boundaries it actually starts.

- [ ] **Step 9: Compile with Boundary**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: pass with no Boundary warnings.

- [ ] **Step 10: Commit**

```bash
git add lib dev mix.exs
git commit -m "chore: declare image plug boundaries"
```

## Task 11: Replace String-Scan Architecture Test

**Files:**
- Delete or rewrite: `test/image_plug/architecture_boundary_test.exs`
- Test: compile and full suite

- [ ] **Step 1: Replace old parser leak scan with precise remaining checks**

Replace the old test with checks Boundary cannot express cleanly, if any. The main remaining useful scan is that runtime files must not name concrete transform modules:

```elixir
defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @runtime_globs ["lib/image_plug/runtime.ex", "lib/image_plug/runtime/**/*.ex"]
  @concrete_transforms [
    "ImagePlug.Transform.Scale",
    "ImagePlug.Transform.Contain",
    "ImagePlug.Transform.Cover",
    "ImagePlug.Transform.Crop",
    "ImagePlug.Transform.Focus"
  ]

  test "runtime does not depend on concrete transform modules" do
    for glob <- @runtime_globs,
        file <- Path.wildcard(glob),
        body = File.read!(file),
        concrete_transform <- @concrete_transforms do
      refute body =~ concrete_transform,
             "#{file} must not name #{concrete_transform}; use ImagePlug.Transform dispatch instead"
    end
  end
end
```

Keep this test unless it is replaced by an AST-based check. Boundary cannot express this rule directly once both parser and runtime depend on the exported `ImagePlug.Transform` boundary.

- [ ] **Step 2: Run architecture test**

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: pass.

- [ ] **Step 3: Run compile with warnings as errors**

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add test/image_plug/architecture_boundary_test.exs
git commit -m "test: replace parser leak scan with boundary enforcement"
```

## Task 12: Full Verification and Cleanup

**Files:**
- Modify: `README.md` if examples still mention old names
- Modify: docs if any old module names remain
- Test: full suite and lint

- [ ] **Step 1: Search for old namespaces**

Run:

```bash
rg "ImagePlug\\.(ParamParser|Pipeline|OutputPlan|Source\\.Plain|RequestRunner|Processor|ResponseCache|Origin|ImageFormat|OutputPolicy|OutputEncoder|OutputNegotiation|TransformState|TransformChain|DecodePlanner|ImageMaterializer|Utils|Cache\\.Material)" lib test dev README.md
```

Expected: no matches except intentional changelog/plan text.

- [ ] **Step 2: Search for removed transform params modules**

Run:

```bash
rg "(ScaleParams|ContainParams|CoverParams|CropParams|FocusParams)" lib test dev README.md
```

Expected: no matches.

- [ ] **Step 3: Search for runtime concrete transform references**

Run:

```bash
rg "ImagePlug\\.Transform\\.(Scale|Contain|Cover|Crop|Focus)" lib/image_plug/runtime
```

Expected: no runtime matches.

- [ ] **Step 4: Remove transitional parser architecture tests**

Remove parser-specific string scans that only existed to guide the migration, such as checks for tuple construction in `PlanBuilder`. Keep the runtime concrete-transform architecture test.

- [ ] **Step 5: Run full tests**

```bash
mise exec -- mix test
```

Expected: pass.

- [ ] **Step 6: Run compile with warnings as errors**

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

- [ ] **Step 7: Run Credo strict**

```bash
mise exec -- mix credo --strict
```

Expected: no actionable findings.

- [ ] **Step 8: Commit cleanup**

```bash
git add lib test dev README.md
git commit -m "chore: clean up namespace migration"
```

## Self-Review

- Spec coverage: The plan covers dependency addition, namespace migration, struct-based transform operations, parser constructor migration, runtime extraction, Boundary declarations, architecture test replacement, option normalization, response sending extraction, and verification.
- Placeholder scan: No unresolved implementation placeholders remain.
- Type consistency: The plan consistently uses `ImagePlug.Plan.Output`, `ImagePlug.Plan.Pipeline`, `ImagePlug.Plan.Source.Plain`, `ImagePlug.Output.*`, `ImagePlug.Runtime.*`, and `ImagePlug.Transform.*`.
- Risk: The largest risks are Task 2, because it changes the transform operation representation and cache material projection, and Task 8C, because it extracts response sending from the Plug facade. Both tasks include focused tests and compile checkpoints before commit.
