# Transform IR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. If Superpowers is unavailable in the execution environment, execute sequentially with the same verification gates and commit/checkpoint boundaries. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current overloaded executable transform structs with a narrow semantic Plan IR for the current imgproxy-compatible behavior, while keeping final output cache lookup source-fetch-free.

**Architecture:** Add canonical semantic operation structs under `ImagePlug.Plan.Operation.*`, keep parser quirks in the renamed `ImagePlug.Parser.Imgproxy`, and resolve semantic plans to executable transform work inside `ImagePlug.Transform`. Cache keys are built from prefetch-safe semantic material, source freshness identity, output/config material, and backend/profile material; source-aware lowering facts are derivations and never mutate final cache keys.

**Tech Stack:** Elixir 1.17, ExUnit, StreamData, Boundary, Plug, Vix/Image, existing `ImagePlug.Transform` facade.

---

## File Structure

Create these semantic Plan files:

- `lib/image_plug/plan/operation.ex` - exported constructor/validation facade for semantic operations.
- `lib/image_plug/plan/operation/crop_region.ex` - exact region crop semantic operation.
- `lib/image_plug/plan/operation/crop_guided.ex` - size-plus-guide crop semantic operation.
- `lib/image_plug/plan/operation/resize_fit.ex` - fit resize semantic operation.
- `lib/image_plug/plan/operation/resize_cover.ex` - cover/fill semantic operation.
- `lib/image_plug/plan/operation/resize_stretch.ex` - force/stretch semantic operation.
- `lib/image_plug/plan/operation/resize_auto.ex` - imgproxy-compatible source-dependent auto resize semantic operation.
- `lib/image_plug/plan/operation/canvas.ex` - place current image onto an explicit canvas.
- `lib/image_plug/plan/operation/auto_orient.ex` - semantic auto-orient operation.
- `lib/image_plug/plan/operation/rotate.ex` - semantic right-angle rotate operation.
- `lib/image_plug/plan/operation/flip.ex` - semantic flip operation.
- `lib/image_plug/plan/geometry/dimension.ex` - `:auto`, `:full_axis`, logical pixels, and ratio dimension values.
- `lib/image_plug/plan/geometry/size.ex` - width/height value pair with DPR.
- `lib/image_plug/plan/geometry/region.ex` - explicit x/y/width/height region with space/unit.
- `lib/image_plug/plan/guide/gravity.ex` - anchor/focal guide value for guided crop and cover.

Create these Transform resolver files:

- `lib/image_plug/transform/source_metadata.ex` - minimal source metadata struct passed to resolver.
- `lib/image_plug/transform/resolved_plan.ex` - resolved executable work plus diagnostics, derivations, selections.
- `lib/image_plug/transform/derivation.ex` - typed derivation struct for source-aware lowering facts.
- `lib/image_plug/transform/backend_profile.ex` - first-slice backend/profile material.
- `lib/image_plug/transform/resolver.ex` - orchestration for semantic validation, source-aware lowering, support checks, and derivation recording.
- `lib/image_plug/transform/resolver/geometry.ex` - shared integer geometry, orientation, DPR, and ResizeAuto branch helpers.
- `lib/image_plug/transform/resolver/lowering.ex` - lowers semantic operations to existing executable `ImagePlug.Transform.Operation.*` structs.

Rename these parser files:

- `lib/image_plug/parser/native.ex` -> `lib/image_plug/parser/imgproxy.ex`
- `lib/image_plug/parser/native/*.ex` -> `lib/image_plug/parser/imgproxy/*.ex`
- `test/parser/native_test.exs` -> `test/parser/imgproxy_test.exs`
- `test/parser/native_property_test.exs` -> `test/parser/imgproxy_property_test.exs`
- `test/parser/native/plan_builder_test.exs` -> `test/parser/imgproxy/plan_builder_test.exs`
- `docs/native_path_api.md` -> `docs/imgproxy_path_api.md`

Modify these existing files:

- `lib/image_plug/plan.ex` - export new Plan operation/value modules and validate semantic operations.
- `lib/image_plug/plan/pipeline.ex` - type operations as semantic Plan operations instead of executable transform chains.
- `lib/image_plug/parser.ex` - export `Imgproxy`, not `Native`.
- `lib/image_plug/parser/imgproxy/plan_builder.ex` - emit semantic Plan operations through constructors.
- `lib/image_plug/cache/key.ex` - materialize semantic Plan operations and include backend/profile/config material.
- `lib/image_plug/runtime/request_runner.ex` - build cache key before source fetch; resolve semantic plan only on cache miss or uncached execution.
- `lib/image_plug/runtime/processor.ex` - accept resolved executable work from `ImagePlug.Transform.resolve/3`.
- `lib/image_plug/transform.ex` - add semantic `resolve/3`, backend profile/material helpers, and remove defensive operation duck-typing once semantic validation replaces it.
- `lib/image_plug/transform/decode_planner.ex` - use resolved executable work for decode/open planning after cache miss.
- `docs/transform_operations.md` - update parser author guidance from executable operations to semantic Plan operations plus Transform resolver.
- `mix.exs` - point docs extras at `docs/imgproxy_path_api.md`.
- `test/image_plug/architecture_boundary_test.exs` - update concrete operation deny-list and parser namespace checks.

Keep these existing executable modules in the first slice as lowering targets:

- `ImagePlug.Transform.Operation.Resize`
- `ImagePlug.Transform.Operation.AdaptiveResize`
- `ImagePlug.Transform.Operation.Crop`
- `ImagePlug.Transform.Operation.ExtendCanvas`
- `ImagePlug.Transform.Operation.AutoOrient`
- `ImagePlug.Transform.Operation.Rotate`
- `ImagePlug.Transform.Operation.Flip`

Do not introduce backend operation structs in this plan unless an executable operation cannot represent the resolved work correctly.

---

## Implementation Guardrails

- Safe execution order is Tasks 0 through 12 as written. Task 9 switches Imgproxy parser output; Tasks 7 and 8 must pass before Task 9 starts.
- Cache key construction must not call `Transform.resolve/3`, origin fetch, metadata extraction, image decode/open, or source-aware geometry helpers.
- The final output cache key must be built before origin fetch and must not be rebuilt or mutated after post-fetch source-aware resolution.
- On cache miss, runtime must store under the same cache key returned by the prefetch-safe lookup; it must not build a resolved-operation key after source-aware resolution.
- Runtime may call generic Plan/Transform validation and execution facades, but it must not pattern-match on concrete `ImagePlug.Plan.Operation.*` or `ImagePlug.Transform.Operation.*` modules.
- Runtime may carry executable transform structs opaquely through `ImagePlug.Transform.Chain`, but must not branch on their concrete modules.
- Semantic Plan constructor APIs must return `{:ok, value}` or `{:error, reason}`. Do not introduce public bang constructors for semantic Plan values or operations; local test helpers such as `build_key!/3` or `execute!/2` are fine when they wrap assertions.
- Parser defaults that affect output, such as center gravity, DPR `1.0`, and enlargement policy, must be explicit in canonical Plan material.
- `ResizeAuto` and `ResizeCover` behavior must be verified against current parser/request-level behavior before lowering is finalized.
- First-slice resolver output is expected to contain derivations and no selections. Add selections only if current imgproxy-compatible behavior proves a prefetch-safe output-affecting choice that is not already materialized elsewhere.
- Parser output must eventually contain only canonical `ImagePlug.Plan.Operation.*` structs, never executable `ImagePlug.Transform.Operation.*` structs.
- Commit steps are checkpoints when git identity is available. If commits are unavailable in the execution environment, leave changes staged or report the intended commit boundary.

---

### Task 0: Inspect Current Shapes And Test Scaffolding

**Files:**
- Modify: none

- [ ] **Step 1: Inspect current APIs before writing exact scaffolding**

Inspect the existing runtime, cache, transform, and image test helpers. Do not change behavior in this task.

Run:

```bash
rg "defmodule ImagePlug.Cache.Entry|defmodule ImagePlug.Cache.Key|defmodule ImagePlug.Runtime.RequestRunner|defmodule ImagePlug.Runtime.ResponseCache|defmodule ImagePlug.Transform.State" lib test
rg "def run\\(|def build|def get\\(|def put\\(|Image\\.new|Vix" lib test
```

Record the actual shapes for:

- `ImagePlug.Cache.Entry`
- `ImagePlug.Cache.Key`
- runtime request runner entry point
- response cache callback return values
- origin/cache test probes
- `ImagePlug.Transform.State`
- image creation/dimension helpers used in existing tests

- [ ] **Step 2: Run current focused tests**

Run the smallest currently relevant tests that exist in this repo. If a listed file does not exist, replace it with the closest existing runtime/cache/transform test discovered in Step 1.

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/runtime/request_runner_test.exs test/transform_chain_test.exs test/image_plug/request_safety_test.exs
```

Expected: existing focused tests pass before plan changes. Later snippets in this plan may need minor scaffolding adjustments to match the actual APIs discovered here, but their assertions and architectural intent should not change.

---

### Task 1: Characterize Current Imgproxy-Compatible Behavior

**Files:**
- Create: `test/image_plug/transform_ir_characterization_test.exs`
- Create: `test/image_plug/transform_executable_characterization_test.exs`
- Modify: none

- [ ] **Step 1: Write current behavior characterization tests**

Split characterization into two files:

- `test/image_plug/transform_executable_characterization_test.exs` freezes existing executable operation behavior for later old-vs-new equivalence tests.
- `test/image_plug/transform_ir_characterization_test.exs` freezes parser/request/cache behavior through public-ish request paths and avoids asserting parser implementation structs.

Directly constructing executable operation structs is acceptable only in `transform_executable_characterization_test.exs`. Parser-facing behavior should parse real imgproxy-compatible requests or run the current request path.

Use the image library/helpers already used by existing transform tests. The shown `Image.new/3`, `Image.width/1`, and `Image.height/1` calls are illustrative and may need alias/import adjustment based on Task 0.

Before pasting this module, replace `Image.new/3`, `Image.width/1`, and `Image.height/1` with the actual image helper or alias found in Task 0.

```elixir
defmodule ImagePlug.TransformExecutableCharacterizationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AdaptiveResize
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.State

  defp generated_state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp execute!(state, operations) do
    assert {:ok, %State{} = state} = ImagePlug.Transform.Chain.execute(state, operations)
    state
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "existing executable resize modes preserve current dimensions" do
    fit =
      generated_state(300, 200)
      |> execute!([
        %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 100}, height: {:pixels, 100}}}
      ])

    fill =
      generated_state(300, 200)
      |> execute!([
        %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}},
        %Crop{
          width: :auto,
          height: :auto,
          crop_from: :gravity,
          gravity: {:anchor, :center, :center},
          x_offset: {:pixels, 0},
          y_offset: {:pixels, 0},
          target_rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}
        }
      ])

    force =
      generated_state(300, 200)
      |> execute!([
        %Resize{rule: %DimensionRule{mode: :force, width: :auto, height: {:pixels, 100}}}
      ])

    auto_landscape_intermediate =
      generated_state(300, 200)
      |> execute!([
        %AdaptiveResize{
          rule: %DimensionRule{mode: :auto, width: {:pixels, 100}, height: {:pixels, 50}}
        }
      ])

    auto_portrait =
      generated_state(300, 200)
      |> execute!([
        %AdaptiveResize{
          rule: %DimensionRule{mode: :auto, width: {:pixels, 50}, height: {:pixels, 100}}
        }
      ])

    assert dimensions(fit) == {100, 67}
    assert dimensions(fill) == {100, 100}
    assert dimensions(force) == {300, 100}
    # This is executable AdaptiveResize alone. Parser/request-level resize:auto may
    # currently emit additional result crop work to produce the visible cover output.
    assert dimensions(auto_landscape_intermediate) == {100, 67}
    assert dimensions(auto_portrait) == {50, 33}
  end

  test "canvas extension changes canvas dimensions independently from resize scale" do
    state =
      generated_state(100, 50)
      |> execute!([
        %ExtendCanvas{
          rule: {:dimensions, {:pixels, 120}, {:pixels, 80}},
          gravity: {:anchor, :center, :center},
          x_offset: 0.0,
          y_offset: 0.0,
          background: :white
        }
      ])

    assert dimensions(state) == {120, 80}
  end

end
```

Create `test/image_plug/transform_ir_characterization_test.exs` with cache and parser/request-level behavior. Use the existing helpers discovered in Task 0, and keep the origin probe simple: it should raise if called.

```elixir
defmodule ImagePlug.TransformIRCharacterizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AdaptiveResize

  defmodule CacheHitProbe do
    def get(key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def put(_key, _entry, _opts), do: raise("cache hit must not write")
  end

  defmodule OriginShouldNotFetch do
    def call(_conn, _opts), do: raise("origin should not fetch on cache hit")
  end

  test "cache hit returns before origin fetch for auto resize requests" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{
          operations: [
            %AdaptiveResize{
              rule: %DimensionRule{
                mode: :auto,
                width: {:pixels, 100},
                height: {:pixels, 100}
              }
            }
          ]
        }
      ],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHitProbe, entry: entry, test_pid: self()},
               origin_req_options: [plug: OriginShouldNotFetch]
             )

    assert_received {:cache_get, key}
    assert key.material[:origin_identity] == "http://origin.test/images/cat-300.jpg"
  end
end
```

Add a numbered request-level test, not a placeholder, that characterizes `resize:auto` through the real parser/request path using the helpers discovered in Task 0. It must assert final visible output dimensions, not emitted parser structs, for:

- source `300x200`, target `100x50`
- source `300x200`, target `50x100`
- source `100x100`, target `50x50`
- source `100x100`, target `50x80`

Use that test to reconcile current behavior with the design rule before implementing `ResizeAuto` lowering. Do not leave this as a placeholder test.

If current test infrastructure cannot easily execute a parsed request against generated images, add a helper local to the characterization test that parses/builds a plan, runs the current runtime/processor path, and reads encoded output dimensions using the same image library/helper used elsewhere in the test suite.

Do not proceed to Task 5 until these request-level `ResizeAuto` cases pass and the expected cover/fill executable sequence is written down in a test assertion or comment.

- [ ] **Step 2: Run the characterization tests**

Run:

```bash
mise exec -- mix test test/image_plug/transform_executable_characterization_test.exs test/image_plug/transform_ir_characterization_test.exs
```

Expected: all tests pass against the current implementation. If a dimension assertion fails, inspect the actual output and update the expected value only when the current code proves the documented behavior is different. Before leaving this task, explicitly answer whether current imgproxy-compatible cover/fill requires `Resize` plus result `Crop`, because Tasks 5 and 6 depend on that.

- [ ] **Step 3: Commit characterization coverage**

Run:

```bash
mise exec -- git add test/image_plug/transform_executable_characterization_test.exs test/image_plug/transform_ir_characterization_test.exs
mise exec -- git commit -m "test: characterize current transform behavior"
```

---

### Task 2: Rename Native Parser To Imgproxy Without Changing Behavior

**Files:**
- Move: `lib/image_plug/parser/native.ex` -> `lib/image_plug/parser/imgproxy.ex`
- Move: `lib/image_plug/parser/native/*.ex` -> `lib/image_plug/parser/imgproxy/*.ex`
- Move: `test/parser/native_test.exs` -> `test/parser/imgproxy_test.exs`
- Move: `test/parser/native_property_test.exs` -> `test/parser/imgproxy_property_test.exs`
- Move: `test/parser/native/plan_builder_test.exs` -> `test/parser/imgproxy/plan_builder_test.exs`
- Move: `docs/native_path_api.md` -> `docs/imgproxy_path_api.md`
- Modify: `lib/image_plug/parser.ex`
- Modify: `mix.exs`
- Modify: `docs/transform_operations.md`
- Modify: tests and docs that reference `ImagePlug.Parser.Native`

- [ ] **Step 1: Move files with git**

Run:

```bash
mise exec -- git mv lib/image_plug/parser/native.ex lib/image_plug/parser/imgproxy.ex
mise exec -- git mv lib/image_plug/parser/native lib/image_plug/parser/imgproxy
mise exec -- git mv test/parser/native_test.exs test/parser/imgproxy_test.exs
mise exec -- git mv test/parser/native_property_test.exs test/parser/imgproxy_property_test.exs
mkdir -p test/parser/imgproxy
mise exec -- git mv test/parser/native/plan_builder_test.exs test/parser/imgproxy/plan_builder_test.exs
mise exec -- git mv docs/native_path_api.md docs/imgproxy_path_api.md
```

If Task 0 finds more files under `test/parser/native`, move the whole directory with `mise exec -- git mv test/parser/native test/parser/imgproxy` instead of moving only `plan_builder_test.exs`.

- [ ] **Step 2: Rename modules and aliases**

Apply a narrow mechanical text replacement for module and docs path references only:

```bash
perl -pi -e 's/ImagePlug\\.Parser\\.Native/ImagePlug.Parser.Imgproxy/g; s/Parser\\.Native/Parser.Imgproxy/g; s/native_path_api/imgproxy_path_api/g' lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/*.ex test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_plug_test.exs test/image_plug/request_safety_test.exs test/image_plug/runtime_options_test.exs test/image_plug/cache_test.exs docs/imgproxy_path_api.md docs/transform_operations.md
```

Then search and manually review remaining uses:

```bash
rg "ImagePlug.Parser.Native|Parser.Native|\\bNative\\b|native_path_api|native parser|Native parser" lib test docs README.md mix.exs
```

Do not run a global `s/\bNative\b/Imgproxy/g` replacement. Keep human-facing prose as `imgproxy-compatible` where grammar needs it, and keep generic "native ImagePlug model" wording when it means the product-neutral `ImagePlug.Plan` model rather than the old parser namespace.

- [ ] **Step 3: Update parser boundary export**

In `lib/image_plug/parser.ex`, change:

```elixir
exports: [Native]
```

to:

```elixir
exports: [Imgproxy]
```

- [ ] **Step 4: Update docs extras**

In `mix.exs`, replace `"docs/native_path_api.md"` with `"docs/imgproxy_path_api.md"`.

- [ ] **Step 5: Update architecture boundary parser checks**

In `test/image_plug/architecture_boundary_test.exs`, rename the Native parser reference check to Imgproxy and update rejected module strings:

```elixir
@parser_namespace_name "ImagePlug.Parser.Imgproxy"
```

Use `imgproxy_parser_references/1` as the helper name. Keep the test purpose unchanged: runtime must not depend on parser-specific structs.

- [ ] **Step 6: Run focused parser and boundary tests**

Run:

```bash
mise exec -- mix format lib/image_plug/parser.ex lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/*.ex test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_plug/architecture_boundary_test.exs
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_plug/architecture_boundary_test.exs test/image_plug/request_safety_test.exs
```

Expected: all focused tests pass with only namespace and docs changes.

- [ ] **Step 7: Commit rename**

Run:

```bash
mise exec -- git add lib test docs mix.exs
mise exec -- git commit -m "refactor: rename native parser to imgproxy"
```

---

### Task 3: Add Vendor Mapping Fixtures Before Semantic Implementation

**Files:**
- Create: `test/image_plug/plan/vendor_mapping_fixture_test.exs`

- [ ] **Step 1: Add non-executing fixture classification tests**

Create `test/image_plug/plan/vendor_mapping_fixture_test.exs`:

```elixir
defmodule ImagePlug.Plan.VendorMappingFixtureTest do
  use ExUnit.Case, async: true

  @fixtures [
    %{
      vendor: :imgproxy,
      input: "rt:fill/w:300/h:200/g:fp:0.25:0.75",
      classification: :supported_now,
      semantic_shape: [:resize_cover],
      notes: "focal guide belongs on cover-style semantic operation"
    },
    %{
      vendor: :imgproxy,
      input: "c:100:50:ce",
      classification: :supported_now,
      semantic_shape: [:crop_guided],
      notes: "guided crop with center gravity"
    },
    %{
      vendor: :imgproxy,
      input: "rt:auto/w:300/h:200",
      classification: :supported_now,
      semantic_shape: [:resize_auto],
      notes: "branch is a source-aware derivation, not cache key material"
    },
    %{
      vendor: :twicpics,
      input: "focus=auto/crop=300x200",
      classification: :representable_not_executable,
      semantic_shape: [:crop_guided, :strategy_guide],
      notes: "strategy guide is future-facing and not first-slice execution"
    },
    %{
      vendor: :twicpics,
      input: "crop=300x200@10,20",
      classification: :representable_not_executable,
      semantic_shape: [:crop_region],
      notes: "coordinate crop pressures explicit region space"
    },
    %{
      vendor: :iiif,
      input: "pct:10,10,80,80/300,",
      classification: :representable_not_executable,
      semantic_shape: [:crop_region, :resize_fit],
      notes: "IIIF region is source-space before size"
    }
  ]

  test "first-wave vendor fixtures are explicit and shallow" do
    assert Enum.map(@fixtures, & &1.vendor) == [
             :imgproxy,
             :imgproxy,
             :imgproxy,
             :twicpics,
             :twicpics,
             :iiif
           ]

    assert Enum.all?(@fixtures, &(&1.classification in [
             :supported_now,
             :representable_not_executable,
             :intentionally_unsupported,
             :lossy_approximation
           ]))

    assert Enum.all?(@fixtures, fn fixture ->
             is_binary(fixture.input) and
               is_list(fixture.semantic_shape) and
               is_binary(fixture.notes)
           end)
  end

  test "non-imgproxy fixtures do not expand first-slice parser scope" do
    assert Enum.all?(@fixtures, fn
             %{vendor: :imgproxy} -> true
             %{classification: classification} -> classification != :supported_now
           end)
  end
end
```

- [ ] **Step 2: Run fixture tests**

Run:

```bash
mise exec -- mix test test/image_plug/plan/vendor_mapping_fixture_test.exs
```

Expected: pass. These fixtures are constraints, not parser implementations.

- [ ] **Step 3: Commit fixture tests**

Run:

```bash
mise exec -- git add test/image_plug/plan/vendor_mapping_fixture_test.exs
mise exec -- git commit -m "test: add transform IR vendor mapping fixtures"
```

---

### Task 4: Add Semantic Operation Constructors And Prefetch-Safe Material

**Files:**
- Create: Plan operation/value files listed in File Structure
- Modify: `lib/image_plug/plan.ex`
- Modify: `lib/image_plug/plan/pipeline.ex`
- Modify: `lib/image_plug/transform/material.ex`
- Create: `test/image_plug/plan/operation_test.exs`
- Create: `test/image_plug/plan/operation_material_test.exs`

Execute this task as vertical subtasks, not one large commit:

- 4A: `Dimension`, `Size`, `Region`, `Gravity`, and value material tests.
- 4B: resize operation structs/constructors/material.
- 4C: crop operation structs/constructors/material.
- 4D: canvas operation struct/constructor/material.
- 4E: orientation operation structs/constructors/material.

Each subtask should add tagged-tuple constructors, validation, material, focused tests, `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, and the relevant focused ExUnit file before moving on. Commit each subtask separately when git identity is available:

- `feat: add semantic geometry values`
- `feat: add semantic resize operations`
- `feat: add semantic crop operations`
- `feat: add semantic canvas operation`
- `feat: add semantic orientation operations`

- [ ] **Step 1: Write failing constructor tests**

Create `test/image_plug/plan/operation_test.exs`:

```elixir
defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation

  test "builds resize operations through exported constructors" do
    assert {:ok, width} = Dimension.pixels(300)
    assert {:ok, height} = Dimension.auto()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, guide} = Gravity.anchor(:center, :center)

    assert {:ok, %Operation.ResizeFit{size: ^size, enlargement: :allow}} =
             Operation.resize_fit(size: size, enlargement: :allow)

    assert {:ok, %Operation.ResizeCover{size: ^size, enlargement: :deny, guide: ^guide}} =
             Operation.resize_cover(size: size, enlargement: :deny, guide: guide)

    assert {:ok, %Operation.ResizeStretch{size: ^size}} =
             Operation.resize_stretch(size: size, enlargement: :allow)

    assert {:ok, %Operation.ResizeAuto{size: ^size}} =
             Operation.resize_auto(size: size, enlargement: :deny)
  end

  test "builds guided crop and canvas operations through exported constructors" do
    assert {:ok, width} = Dimension.pixels(120)
    assert {:ok, height} = Dimension.pixels(50)
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, guide} = Gravity.anchor(:center, :center)

    assert {:ok, %Operation.CropGuided{}} = Operation.crop_guided(size: size, guide: guide)

    assert {:ok, %Operation.Canvas{}} =
             Operation.canvas(
               size: size,
               placement: guide,
               background: :white,
               overflow: :reject
             )
  end

  test "size rejects invalid DPR values" do
    assert {:ok, dimension} = Dimension.pixels(100)

    assert {:error, {:invalid_size, _attrs}} =
             Size.new(width: dimension, height: dimension, dpr: 0)

    assert {:error, {:invalid_size, _attrs}} =
             Size.new(width: dimension, height: dimension, dpr: -1)
  end
end
```

- [ ] **Step 2: Write failing semantic material tests**

Create `test/image_plug/plan/operation_material_test.exs`:

```elixir
defmodule ImagePlug.Plan.OperationMaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Material

  test "resize auto material is unresolved semantic intent" do
    operation =
      with {:ok, width} <- Dimension.pixels(300),
           {:ok, height} <- Dimension.pixels(200),
           {:ok, size} <- Size.new(width: width, height: height, dpr: 2.0),
           {:ok, operation} <- Operation.resize_auto(size: size, enlargement: :deny) do
        operation
      end

    assert Material.material(operation) == [
             op: :resize_auto,
             size: [
               width: [unit: :logical_px, value: 300],
               height: [unit: :logical_px, value: 200],
               dpr: 2.0
             ],
             enlargement: :deny,
             rule: :imgproxy_orientation_match_v1
           ]
  end

  test "source-space crop region material stays source-metadata-free" do
    operation =
      with {:ok, x} <- Dimension.ratio(1, 10),
           {:ok, y} <- Dimension.ratio(1, 10),
           {:ok, width} <- Dimension.ratio(1, 2),
           {:ok, height} <- Dimension.ratio(1, 2),
           {:ok, region} <- Region.new(x: x, y: y, width: width, height: height, space: :source),
           {:ok, operation} <- Operation.crop_region(region: region) do
        operation
      end

    assert Material.material(operation) == [
             op: :crop_region,
             region: [
               space: :source,
               x: [unit: :ratio, numerator: 1, denominator: 10],
               y: [unit: :ratio, numerator: 1, denominator: 10],
               width: [unit: :ratio, numerator: 1, denominator: 2],
               height: [unit: :ratio, numerator: 1, denominator: 2]
             ]
           ]
  end

  test "ratio material is canonicalized" do
    assert {:ok, ratio} = Dimension.ratio(2, 4)

    assert Material.material(ratio) ==
             [unit: :ratio, numerator: 1, denominator: 2]
  end

  test "guided crop material contains explicit guide and no parser syntax" do
    operation =
      with {:ok, width} <- Dimension.pixels(50),
           {:ok, height} <- Dimension.pixels(50),
           {:ok, size} <- Size.new(width: width, height: height, dpr: 1.0),
           {:ok, guide} <- Gravity.anchor(:center, :center),
           {:ok, operation} <- Operation.crop_guided(size: size, guide: guide) do
        operation
      end

    material = Material.material(operation)

    assert material[:op] == :crop_guided
    assert material[:guide] == [type: :anchor, x: :center, y: :center, space: :current]
    refute inspect(material) =~ "imgproxy"
    refute inspect(material) =~ "gravity:"
  end
end
```

- [ ] **Step 3: Add minimal value structs**

Add `ImagePlug.Plan.Geometry.Dimension`, `Size`, `Region`, and `ImagePlug.Plan.Guide.Gravity` with these public constructors:

```elixir
Dimension.auto()
Dimension.full_axis()
Dimension.pixels(pos_integer())
Dimension.ratio(pos_integer(), pos_integer())
Size.new(width: dimension, height: dimension, dpr: pos_number)
Region.new(x: dimension, y: dimension, width: dimension, height: dimension, space: :source | :current | :post_orient)
Gravity.anchor(:left | :center | :right, :top | :center | :bottom)
Gravity.focal_point(x_numerator, x_denominator, y_numerator, y_denominator, space \\ :current)
```

Constructors return `{:ok, value}` or `{:error, reason}`. Do not make public bang constructors the primary Plan API: these constructors are used by parser/adapter translation, where malformed syntax is external input and should compose with `with`. `Dimension.pixels/1` must reject `0`; resize auto-axis and crop full-axis semantics must be represented explicitly by `Dimension.auto/0` and `Dimension.full_axis/0`.

`Dimension.ratio/2` must reduce ratios with `Integer.gcd/2` so equivalent ratios materialize identically.

Dimension material must be exact and source-fetch-free:

```elixir
Dimension.auto() -> {:ok, dimension}; material(dimension) -> [unit: :auto]
Dimension.full_axis() -> {:ok, dimension}; material(dimension) -> [unit: :full_axis]
Dimension.pixels(n) -> {:ok, dimension}; material(dimension) -> [unit: :logical_px, value: n]
Dimension.ratio(a, b) -> {:ok, dimension}; material(dimension) -> [unit: :ratio, numerator: reduced_a, denominator: reduced_b]
```

`Dimension.pixels/1` represents logical pixels in canonical material. DPR conversion to physical integer pixels is owned by lowering.

Operation constructors should accept the exact semantic value structs they require, such as `%Size{}` and `%Gravity{}`, plus primitive arguments. Do not accept arbitrary maps, keyword-shaped pseudo-values, existing executable transform structs, or broad coercions.

`Gravity.anchor/2` should default to `space: :current`. If a future caller needs another space, add an explicit constructor or option and materialize that default.

- [ ] **Step 4: Add semantic operation structs and constructors**

Add `ImagePlug.Plan.Operation` as the only parser-facing constructor facade. Each constructor returns a narrow struct with enforced keys:

```elixir
Operation.crop_region(region: region)
Operation.crop_guided(size: size, guide: guide)
Operation.resize_fit(size: size, enlargement: :allow | :deny)
Operation.resize_cover(size: size, enlargement: :allow | :deny, guide: guide)
Operation.resize_stretch(size: size, enlargement: :allow | :deny)
Operation.resize_auto(size: size, enlargement: :allow | :deny)
Operation.canvas(size: size, placement: gravity, background: :white, overflow: :reject)
Operation.auto_orient()
Operation.rotate(0 | 90 | 180 | 270)
Operation.flip(:horizontal | :vertical | :both)
```

Do not add `SetFocus`, `SetGravity`, `StrategyList`, `ResizeContain`, or backend operation structs.

- [ ] **Step 5: Implement `ImagePlug.Transform.Material` for semantic operations**

Implement material in one focused file first: `lib/image_plug/plan/operation/material.ex`. Split later only if the implementation becomes unwieldy.

Preserve the existing public API and dispatch style of `ImagePlug.Transform.Material`. If it is a protocol, add `defimpl`s for semantic operation/value structs rather than replacing protocol semantics. This is a first-slice compatibility bridge for cache material; semantic material must remain source-fetch-free and must not depend on resolver state.

Material must be keyword lists and source-fetch-free. `ResizeAuto` material must not contain selected fit/cover branch.

- [ ] **Step 6: Export Plan operation modules**

Update `lib/image_plug/plan.ex` Boundary exports to include:

```elixir
Operation,
Operation.CropRegion,
Operation.CropGuided,
Operation.ResizeFit,
Operation.ResizeCover,
Operation.ResizeStretch,
Operation.ResizeAuto,
Operation.Canvas,
Operation.AutoOrient,
Operation.Rotate,
Operation.Flip,
Geometry.Dimension,
Geometry.Size,
Geometry.Region,
Guide.Gravity
```

Update `lib/image_plug/plan/pipeline.ex` type to include semantic operations. During the migration, keep executable operations in the type if current parser/runtime still emits them before Task 9; narrow the type to semantic-only in Task 10 after parser output is switched.

If this exact semantic-only type breaks compilation, docs, or specs before Task 9, temporarily union the existing executable operation type and remove that temporary union in Task 10.

```elixir
# Final type after Task 10:
@type operation() ::
        ImagePlug.Plan.Operation.CropRegion.t()
        | ImagePlug.Plan.Operation.CropGuided.t()
        | ImagePlug.Plan.Operation.ResizeFit.t()
        | ImagePlug.Plan.Operation.ResizeCover.t()
        | ImagePlug.Plan.Operation.ResizeStretch.t()
        | ImagePlug.Plan.Operation.ResizeAuto.t()
        | ImagePlug.Plan.Operation.Canvas.t()
        | ImagePlug.Plan.Operation.AutoOrient.t()
        | ImagePlug.Plan.Operation.Rotate.t()
        | ImagePlug.Plan.Operation.Flip.t()

@type t :: %__MODULE__{operations: [operation()]}
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
mise exec -- mix format lib/image_plug/plan.ex lib/image_plug/plan/pipeline.ex lib/image_plug/plan/operation.ex lib/image_plug/plan/operation/*.ex lib/image_plug/plan/geometry/*.ex lib/image_plug/plan/guide/*.ex test/image_plug/plan/operation_test.exs test/image_plug/plan/operation_material_test.exs
mise exec -- mix test test/image_plug/plan/operation_test.exs test/image_plug/plan/operation_material_test.exs test/image_plug/transform/material_test.exs
```

Expected: new Plan operation tests pass, existing transform material tests still pass.

- [ ] **Step 8: Commit semantic operation material**

If the 4A-4E subtasks were not already committed individually, run:

```bash
mise exec -- git add lib/image_plug/plan lib/image_plug/transform/material.ex test/image_plug/plan
mise exec -- git commit -m "feat: add semantic plan operations"
```

---

### Task 5: Add Transform Resolver And ResizeAuto Derivations

**Files:**
- Create: `lib/image_plug/transform/source_metadata.ex`
- Create: `lib/image_plug/transform/resolved_plan.ex`
- Create: `lib/image_plug/transform/derivation.ex`
- Create: `lib/image_plug/transform/backend_profile.ex`
- Create: `lib/image_plug/transform/resolver.ex`
- Create: `lib/image_plug/transform/resolver/geometry.ex`
- Create: `lib/image_plug/transform/resolver/lowering.ex`
- Modify: `lib/image_plug/transform.ex`
- Test: `test/image_plug/transform/resolver_test.exs`

- [ ] **Step 1: Write failing ResizeAuto resolver tests**

Create `test/image_plug/transform/resolver_test.exs`:

```elixir
defmodule ImagePlug.Transform.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.SourceMetadata

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end

  test "resize auto derives cover for matching current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])

    assert [[
              %Resize{rule: %DimensionRule{mode: :fill}},
              %Crop{target_rule: %DimensionRule{mode: :fill}, crop_from: :gravity}
            ]] = resolved.pipelines

    assert [%{code: :resize_auto_branch, value: :cover, material?: false}] =
             resolved.derivations

    assert resolved.selections == []
    assert resolved.resolver_material == []
  end

  test "resize auto derives fit for differing current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(200, 300), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])
    assert [[%Resize{rule: %DimensionRule{mode: :fit}}]] = resolved.pipelines

    assert [%{code: :resize_auto_branch, value: :fit, material?: false}] =
             resolved.derivations
  end

  test "resize auto derives fit when target orientation is unknown" do
    assert {:ok, width} = Dimension.pixels(300)
    assert {:ok, height} = Dimension.auto()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, operation} = Operation.resize_auto(size: size, enlargement: :deny)

    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])
    assert [[%Resize{rule: %DimensionRule{mode: :fit}}]] = resolved.pipelines
  end
end
```

If Task 1 proves current request-visible cover/fill does not require a result crop, update the expected cover pipeline shape in these tests before implementing. Do not let this test override characterization findings.

- [ ] **Step 2: Add resolver data structs**

Add:

```elixir
%ImagePlug.Transform.SourceMetadata{
  width: pos_integer(),
  height: pos_integer(),
  orientation: :normal | :unknown | {:exif, 1..8},
  has_alpha?: boolean(),
  format: atom() | nil,
  source_type: :raster | :animated_raster | :vector
}
```

Defaults: `orientation: :normal`, `has_alpha?: false`, `source_type: :raster`.

Provide `SourceMetadata.new/1`, and have the resolver entrypoint validate raw struct literals as a backstop. Invalid width, height, orientation, format, or source type should fail before lowering. Tests may use raw struct literals when clearer, but production code should have one obvious constructor path.

First-slice resolver may treat non-`:normal` orientation conservatively unless current imgproxy-compatible behavior already exposes and tests EXIF-aware geometry. Do not overbuild EXIF coordinate handling in this task.

Add:

```elixir
%ImagePlug.Transform.Derivation{
  code: atom(),
  value: term(),
  pipeline_index: non_neg_integer(),
  operation_index: non_neg_integer(),
  material?: false,
  details: map()
}
```

Add:

```elixir
%ImagePlug.Transform.ResolvedPlan{
  pipelines: [[ImagePlug.Transform.operation()]],
  diagnostics: [],
  derivations: [],
  selections: [],
  resolver_material: [],
  backend_profile_material: []
}
```

First-slice `ResolvedPlan.pipelines` is a nested list of executable transform operations, preserving the same pipeline grouping as `Plan.pipelines`. Return shape is always `{:ok, %ResolvedPlan{}} | {:error, diagnostics}`; do not add polymorphic success tuples.

- [ ] **Step 3: Add backend profile material**

Add `ImagePlug.Transform.BackendProfile.default/0` and `material/1`:

```elixir
[
  backend: :vips,
  material_version: 1,
  geometry_rules_version: 1,
  orientation_policy_version: 1,
  dpr_policy_version: 1,
  smart_strategy_support: :none
]
```

- [ ] **Step 4: Implement resolver orchestration**

Expose in `ImagePlug.Transform`:

```elixir
@spec resolve(ImagePlug.Plan.t(), SourceMetadata.t(), keyword()) ::
        {:ok, ResolvedPlan.t()} | {:error, term()}
def resolve(%ImagePlug.Plan{} = plan, %SourceMetadata{} = source_metadata, opts \\ []) do
  ImagePlug.Transform.Resolver.resolve(plan, source_metadata, opts)
end
```

`ImagePlug.Transform.Resolver.resolve/3` should:

1. Validate source-independent semantic operation shapes.
2. Iterate pipelines in order.
3. Maintain current dimensions in resolver state.
4. Lower each semantic operation through `Resolver.Lowering`.
5. Append derivations for ResizeAuto, DPR conversion, and source-aware dimensions when implemented.
6. Return no selections in first slice.

- [ ] **Step 5: Implement ResizeAuto orientation helper**

In `ImagePlug.Transform.Resolver.Geometry`, add:

```elixir
orientation(width, height) :: :landscape | :portrait | :square | :unknown
resize_auto_branch(current_width, current_height, target_width, target_height) :: :cover | :fit
```

Rules:

- landscape/landscape -> `:cover`
- portrait/portrait -> `:cover`
- square/square -> `:cover`
- any known mismatch -> `:fit`
- unknown target width or height -> `:fit`

- [ ] **Step 6: Implement first ResizeAuto lowering**

Lower `Operation.ResizeAuto` to the existing executable sequence required to preserve current imgproxy-compatible visible behavior:

- `:cover` -> `%Resize{rule: %DimensionRule{mode: :fill}}` plus the result crop sequence that current fill/cover behavior requires
- `:fit` -> `mode: :fit`
- `enlargement: :allow` -> `enlarge: true`
- `enlargement: :deny` -> `enlarge: false`
- requested logical size and DPR are carried into the `DimensionRule`

If Task 1 proves that `%Resize{mode: :fill}` alone already produces exact cover output, document that proof in the test and simplify this lowering. Otherwise default to resize-plus-result-crop.

Record a `%Derivation{code: :resize_auto_branch, value: :cover | :fit, material?: false}`.

- [ ] **Step 7: Run resolver tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/source_metadata.ex lib/image_plug/transform/resolved_plan.ex lib/image_plug/transform/derivation.ex lib/image_plug/transform/backend_profile.ex lib/image_plug/transform/resolver.ex lib/image_plug/transform/resolver/*.ex test/image_plug/transform/resolver_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/transform/resolver_test.exs
```

Expected: ResizeAuto branch derivations are recorded and `resolver_material` remains empty.

- [ ] **Step 8: Commit resolver foundation**

Run:

```bash
mise exec -- git add lib/image_plug/transform test/image_plug/transform/resolver_test.exs
mise exec -- git commit -m "feat: add transform resolver foundation"
```

---

### Task 6: Lower MVP Semantic Operations To Existing Executable Operations

**Files:**
- Modify: `lib/image_plug/transform/resolver/lowering.ex`
- Modify: `lib/image_plug/transform/resolver/geometry.ex`
- Test: `test/image_plug/transform/resolver_lowering_test.exs`

- [ ] **Step 1: Write lowering tests for each MVP operation**

Create `test/image_plug/transform/resolver_lowering_test.exs`:

```elixir
defmodule ImagePlug.Transform.ResolverLoweringTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.SourceMetadata

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp metadata, do: %SourceMetadata{width: 300, height: 200, orientation: :normal, format: :jpeg}

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end

  test "resize fit, cover, and stretch lower to existing resize rules" do
    assert {:ok, guide} = Gravity.anchor(:center, :center)
    assert {:ok, fit} = Operation.resize_fit(size: size(100, 80), enlargement: :deny)
    assert {:ok, cover} = Operation.resize_cover(size: size(50, 50), enlargement: :allow, guide: guide)
    assert {:ok, stretch} = Operation.resize_stretch(size: size(20, 10), enlargement: :allow)
    operations = [fit, cover, stretch]

    assert {:ok, resolved} = Transform.resolve(plan(operations), metadata(), [])

    assert [[
              %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 100}, height: {:pixels, 80}}},
              %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 50}, height: {:pixels, 50}}},
              %Crop{target_rule: %DimensionRule{mode: :fill}, crop_from: :gravity},
              %Resize{rule: %DimensionRule{mode: :force, width: {:pixels, 20}, height: {:pixels, 10}}}
            ]] = resolved.pipelines
  end

  test "guided crop lowers to existing gravity crop" do
    assert {:ok, width} = Dimension.pixels(50)
    assert {:ok, height} = Dimension.full_axis()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, guide} = Gravity.anchor(:center, :center)
    assert {:ok, operation} = Operation.crop_guided(size: size, guide: guide)

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])
    assert [[%Crop{width: {:pixels, 50}, height: :auto, crop_from: :gravity}]] = resolved.pipelines
  end

  test "canvas lowers to extend canvas without choosing resize scale" do
    assert {:ok, placement} = Gravity.anchor(:center, :center)
    assert {:ok, operation} =
             Operation.canvas(size: size(320, 240), placement: placement, background: :white, overflow: :reject)

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [[%ExtendCanvas{rule: {:dimensions, {:pixels, 320}, {:pixels, 240}}}]] =
             resolved.pipelines
  end

  test "source-space ratio crop resolves to integer backend crop and derivation" do
    assert {:ok, x} = Dimension.ratio(1, 10)
    assert {:ok, y} = Dimension.ratio(1, 10)
    assert {:ok, width} = Dimension.ratio(1, 2)
    assert {:ok, height} = Dimension.ratio(1, 2)
    assert {:ok, region} =
             ImagePlug.Plan.Geometry.Region.new(x: x, y: y, width: width, height: height, space: :source)
    assert {:ok, operation} = Operation.crop_region(region: region)

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])
    assert [%{code: :crop_region_resolved, material?: false}] = resolved.derivations
    assert [[%Crop{} = crop]] = resolved.pipelines
    assert_existing_crop_fields_encode(crop, left: 30, top: 20, width: 150, height: 100)
  end
end
```

Adapt `assert_existing_crop_fields_encode/2` to the existing executable `Crop` field shape discovered in Task 0. The required derived geometry for source `300x200`, region `x=1/10`, `y=1/10`, `width=1/2`, `height=1/2` is left `30`, top `20`, width `150`, height `100`.

- [ ] **Step 2: Implement lowering cases vertically**

For each semantic operation, add one lowering function and run the focused test before moving to the next operation:

- `ResizeFit` -> existing `%Resize{rule: %DimensionRule{mode: :fit}}`
- `ResizeCover` -> the existing executable sequence required to preserve current fill/cover behavior. If Task 1 proves current request-visible cover/fill uses resize plus result crop, lower to `%Resize{rule: %DimensionRule{mode: :fill}}` followed by `%Crop{target_rule: same_fill_rule, crop_from: :gravity}`. If Task 1 proves `%Resize{mode: :fill}` alone already produces final cover dimensions, assert only resize and update these tests accordingly.
- `ResizeStretch` -> existing `%Resize{rule: %DimensionRule{mode: :force}}`
- `CropGuided` -> existing `%Crop{crop_from: :gravity}`. `Dimension.full_axis()` lowers to the existing crop full-axis representation, such as `:auto`, only in this crop-axis context.
- `CropRegion` -> existing `%Crop{crop_from: %{left: x, top: y}}` only when exact current-space pixels can be resolved; source-space regions must use shared geometry derivation
- `Canvas` -> existing `%ExtendCanvas{}`
- `AutoOrient`, `Rotate`, `Flip` -> existing orientation operations

- [ ] **Step 3: Add derivations for source-aware values**

When lowering resolves a source/current dependent value, append a derivation with `material?: false`. Use these codes:

- `:resize_auto_branch`
- `:dpr_applied`
- `:crop_region_resolved`
- `:dimension_resolved`

First-slice resolved plans must keep `selections: []` and `resolver_material: []`.

- [ ] **Step 4: Run lowering and characterization tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform/resolver/*.ex test/image_plug/transform/resolver_lowering_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/transform/resolver_test.exs test/image_plug/transform/resolver_lowering_test.exs test/image_plug/transform_ir_characterization_test.exs
```

Expected: all tests pass. Characterization output dimensions remain unchanged.

- [ ] **Step 5: Commit lowering**

Run:

```bash
mise exec -- git add lib/image_plug/transform/resolver test/image_plug/transform/resolver_lowering_test.exs
mise exec -- git commit -m "feat: lower semantic operations to executable transforms"
```

---

### Task 7: Make Cache Key Construction Use Semantic Material Before Source Fetch

**Files:**
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/response_cache.ex`
- Test: `test/image_plug/cache/key_test.exs`
- Test: `test/image_plug/runtime/request_runner_test.exs`
- Test: `test/image_plug/response_cache_test.exs`

- [ ] **Step 1: Add ResizeAuto cache tests**

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "resize auto cache material stays unresolved and source-metadata-free" do
  assert {:ok, width} = ImagePlug.Plan.Geometry.Dimension.pixels(300)
  assert {:ok, height} = ImagePlug.Plan.Geometry.Dimension.pixels(200)
  assert {:ok, size} = ImagePlug.Plan.Geometry.Size.new(width: width, height: height, dpr: 1.0)
  assert {:ok, operation} = ImagePlug.Plan.Operation.resize_auto(size: size, enlargement: :deny)

  plan = plan(pipelines: [%Pipeline{operations: [operation]}])
  conn = conn(:get, "/_/rt:auto/w:300/h:200/f:jpeg/plain/images/cat.jpg")

  key_a = build_key!(conn, plan, "origin-version-a")
  key_b = build_key!(conn, plan, "origin-version-b")

  assert [[material]] = key_a.material[:pipelines]
  assert material[:op] == :resize_auto
  refute Keyword.has_key?(material, :selected_branch)
  serialized = ImagePlug.Cache.Key.serialize_material(key_a.material)
  refute serialized =~ "source_width"
  refute serialized =~ "source_height"
  refute serialized =~ "selected_branch"
  refute key_a.hash == key_b.hash
end
```

Add a second cache test that passes a non-default backend profile or backend material version and proves the final key changes while semantic pipeline material stays the same. This forces backend/profile material to be parameterized rather than hardcoded.

Implementation hint: the cache key builder should accept backend profile material through options/config, for example `backend_profile: custom_profile` or equivalent based on Task 0 findings, instead of hardcoding `BackendProfile.default/0` in a way callers cannot override.

When backend profile material is added, update existing cache key fixtures or snapshots intentionally. Do not weaken semantic cache assertions merely to make changed snapshots pass.

- [ ] **Step 2: Add cache-hit no-origin test for semantic ResizeAuto**

Add to `test/image_plug/runtime/request_runner_test.exs`:

```elixir
test "semantic resize auto cache hit does not fetch source or resolve derivations" do
  entry = %Entry{
    body: "cached jpeg",
    content_type: "image/jpeg",
    headers: [],
    created_at: DateTime.utc_now()
  }

  assert {:ok, width} = ImagePlug.Plan.Geometry.Dimension.pixels(100)
  assert {:ok, height} = ImagePlug.Plan.Geometry.Dimension.pixels(100)
  assert {:ok, size} = ImagePlug.Plan.Geometry.Size.new(width: width, height: height, dpr: 1.0)
  assert {:ok, operation} = ImagePlug.Plan.Operation.resize_auto(size: size, enlargement: :deny)

  assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
           RequestRunner.run(
             conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"),
             plan(pipelines: [%Pipeline{operations: [operation]}]),
             "origin-version-1",
             cache: {CacheReadProbe, entry: entry}
           )

  assert_received {:cache_lookup, key}
  assert key.material[:origin_identity] == "origin-version-1"
  refute ImagePlug.Cache.Key.serialize_material(key.material) =~ "selected_branch"
end
```

- [ ] **Step 3: Update `Cache.Key` material wording and backend profile material**

Keep `Cache.Key.build/4` source-fetch-free. Add backend/profile material to the key with default profile:

```elixir
backend: ImagePlug.Transform.BackendProfile.material(ImagePlug.Transform.BackendProfile.default())
```

Do not call `Transform.resolve/3`, image metadata readers, or origin fetch modules from cache key code.

- [ ] **Step 4: Add source-independent semantic validation facade**

Add a narrow source-independent validation facade such as `ImagePlug.Transform.validate_prefetch_safe_plan/1`.

This facade should:

- reject malformed semantic operation structs before cache lookup
- reject parser/adapter command structs in canonical `Plan`
- reject unsupported first-slice strategy guides or capability-only concepts
- avoid source metadata, origin fetch, decode/open, and `Transform.resolve/3`

`RequestRunner` may call this facade before cache lookup. It must not pattern-match on concrete `ImagePlug.Plan.Operation.*` modules itself.

Add focused tests, preferably in `test/image_plug/transform/prefetch_validation_test.exs`, proving:

- semantic Plan operations pass
- executable `ImagePlug.Transform.Operation.*` structs in a canonical Plan fail after Task 9/10
- parser-local command structs fail
- validation does not call resolver, source metadata, origin fetch, or decode/open code

- [ ] **Step 5: Ensure runtime does not second-lookup with derived material**

`RequestRunner.run/4` must:

1. Validate parser/plan source-independent shape.
2. Call `ResponseCache.lookup/4`.
3. On cache hit, return cached entry.
4. On cache miss, fetch source and resolve semantic plan.
5. Store under the original key returned by lookup.

Do not rebuild a second final key after `Transform.resolve/3`.

If `ResponseCache.lookup/4` currently builds or rebuilds keys internally, change it to return or expose the original prefetch-safe key so miss-path storage reuses exactly the same key. It must not call resolver or accept resolved plans for final output key construction.

Add a cache probe test that fails if lookup is called more than once. Prefer an existing test helper or `start_supervised!/1` process over process dictionary state if calls can cross processes.

- [ ] **Step 6: Run cache tests**

Run:

```bash
mise exec -- mix format lib/image_plug/cache/key.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_cache.ex test/image_plug/cache/key_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
```

Expected: semantic ResizeAuto stays unresolved in cache material, origin identity changes key, backend profile material changes key, cache hits return before source work, and existing executable-operation cache tests continue to pass until parser output is switched in Task 9.

- [ ] **Step 7: Commit metadata-free cache lookup**

Run:

```bash
mise exec -- git add lib/image_plug/cache/key.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_cache.ex test/image_plug/cache test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
mise exec -- git commit -m "feat: key transform cache by semantic intent"
```

---

### Task 8: Route Runtime Execution Through Resolver On Cache Miss

**Files:**
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/processor.ex`
- Modify: `lib/image_plug/transform/decode_planner.ex`
- Test: `test/image_plug/runtime/request_runner_test.exs`
- Test: `test/image_plug/decode_planner_test.exs`

Runtime must be capable of accepting semantic plans before Task 9 switches the Imgproxy parser to emit semantic operations.

- [ ] **Step 1: Add miss-path resolver test**

Add to `test/image_plug/runtime/request_runner_test.exs` a test that uses semantic operations, cache miss, and existing origin image. If Task 0 finds the runtime test at a different path, use that discovered path consistently in this task.

```elixir
test "cache miss resolves semantic operations after origin fetch and stores under original key" do
  assert {:ok, width} = ImagePlug.Plan.Geometry.Dimension.pixels(100)
  assert {:ok, height} = ImagePlug.Plan.Geometry.Dimension.auto()
  assert {:ok, size} = ImagePlug.Plan.Geometry.Size.new(width: width, height: height, dpr: 1.0)
  assert {:ok, operation} = ImagePlug.Plan.Operation.resize_fit(size: size, enlargement: :deny)

  assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, %ImagePlug.Plan.Response{}}} =
           RequestRunner.run(
             conn(:get, "/_/w:100/f:jpeg/plain/images/cat-300.jpg"),
             plan(pipelines: [%Pipeline{operations: [operation]}]),
             "http://origin.test/images/cat-300.jpg",
             cache: {CacheHitWriteProbe, entry: :miss},
             origin_req_options: [plug: OriginImage]
           )

  assert_received {:cache_lookup, key}
  assert_received {:cache_put, ^key, %Entry{}, _opts}
end
```

Adjust the local cache probe if it currently cannot return `:miss`; add a small `CacheMissWriteProbe` test module when clearer.

- [ ] **Step 2: Keep decode/open planning conservative before metadata**

On a cache miss, the first-slice sequence is:

1. origin fetch
2. conservative decode/open planning from source-fetch-free semantic operation metadata
3. image open and source metadata discovery
4. source-aware semantic resolution
5. executable transform execution

Do not imply that source metadata is available before decode/open planning unless the current code already has a metadata-only open path. The first slice can use conservative random access before metadata for correctness.

- [ ] **Step 3: Extract source metadata after image open**

In `Processor.decode_validate_origin_response/5`, after image open succeeds, derive:

```elixir
%ImagePlug.Transform.SourceMetadata{
  width: Image.width(image),
  height: Image.height(image),
  orientation: :normal,
  format: source_format,
  source_type: :raster
}
```

Store the metadata in `DecodedOrigin` if needed, or return it alongside decoded image. Prefer adding a `source_metadata` field to `ImagePlug.Runtime.DecodedOrigin`.

- [ ] **Step 4: Resolve before `Chain.execute/2`**

Change processor execution so semantic pipelines are resolved after source metadata is available:

```elixir
with {:ok, %ImagePlug.Transform.ResolvedPlan{} = resolved} <-
       ImagePlug.Transform.resolve(plan, decoded.source_metadata, opts),
     {:ok, final_state} <- execute_pipelines(%State{image: decoded.image}, resolved.pipelines, decoded, opts) do
  ...
end
```

`execute_pipelines/4` should continue to receive lists of executable transform operations.

- [ ] **Step 5: Keep runtime generic**

Runtime may pass executable operation structs to `ImagePlug.Transform.Chain.execute/2` opaquely, but it must not branch on concrete executable modules. Any operation-specific behavior belongs in `ImagePlug.Transform.Resolver`, `ImagePlug.Transform.Resolver.Lowering`, or existing transform callbacks.

- [ ] **Step 6: Keep decode planning conservative**

Decode planning can use semantic operation metadata before resolve only when source-fetch-free. For first slice, keep random access for semantic operation chains that have not been resolved. Add or update `DecodePlanner` so unknown semantic operation structs return random access until resolved executable work is available.

Add a decode planner test proving that a semantic plan containing unresolved source-dependent geometry, such as `ResizeAuto` or source-space `CropRegion`, chooses conservative/random access before source metadata exists.

- [ ] **Step 7: Run runtime and decode tests**

Run:

```bash
mise exec -- mix format lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/processor.ex lib/image_plug/runtime/decoded_origin.ex lib/image_plug/transform/decode_planner.ex test/image_plug/runtime/request_runner_test.exs test/image_plug/decode_planner_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/runtime/request_runner_test.exs test/image_plug/decode_planner_test.exs test/image_plug/request_safety_test.exs
```

Expected: cache hit still avoids origin; cache miss resolves and executes semantic operations; invalid parser/plan requests still fail before cache and origin.

- [ ] **Step 8: Commit resolver runtime path**

Run:

```bash
mise exec -- git add lib/image_plug/runtime lib/image_plug/transform/decode_planner.ex test/image_plug/runtime/request_runner_test.exs test/image_plug/decode_planner_test.exs test/image_plug/request_safety_test.exs
mise exec -- git commit -m "feat: resolve semantic operations on cache miss"
```

---

### Task 9: Switch Imgproxy PlanBuilder To Emit Semantic Operations

**Files:**
- Modify: `lib/image_plug/parser/imgproxy/plan_builder.ex`
- Modify: `test/parser/imgproxy/plan_builder_test.exs`
- Modify: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Update parser tests to expect semantic operations**

In `test/parser/imgproxy/plan_builder_test.exs` and `test/parser/imgproxy_test.exs`, replace expectations for executable operations with semantic operations:

```elixir
%Transform.Operation.Resize{} -> %ImagePlug.Plan.Operation.ResizeFit{}
%Transform.Operation.AdaptiveResize{} -> %ImagePlug.Plan.Operation.ResizeAuto{}
%Transform.Operation.Crop{} -> %ImagePlug.Plan.Operation.CropGuided{}
%Transform.Operation.ExtendCanvas{} -> %ImagePlug.Plan.Operation.Canvas{}
%Transform.Operation.AutoOrient{} -> %ImagePlug.Plan.Operation.AutoOrient{}
%Transform.Operation.Rotate{} -> %ImagePlug.Plan.Operation.Rotate{}
%Transform.Operation.Flip{} -> %ImagePlug.Plan.Operation.Flip{}
```

Keep parser syntax, error, output, policy, cache, response, and order-insensitivity assertions intact.

- [ ] **Step 2: Update PlanBuilder aliases**

In `lib/image_plug/parser/imgproxy/plan_builder.ex`, replace:

```elixir
alias ImagePlug.Transform
```

with:

```elixir
alias ImagePlug.Plan.Operation
alias ImagePlug.Plan.Geometry.Dimension
alias ImagePlug.Plan.Geometry.Size
alias ImagePlug.Plan.Guide.Gravity
```

- [ ] **Step 3: Replace resize construction**

Change resize planning to call:

- `Operation.resize_fit`
- `Operation.resize_cover`
- `Operation.resize_stretch`
- `Operation.resize_auto`

Use existing request fields to build `Size`:

```elixir
with {:ok, width} <- imgproxy_resize_dimension(request.width),
     {:ok, height} <- imgproxy_resize_dimension(request.height),
     {:ok, size} <- Size.new(width: width, height: height, dpr: request.dpr || 1.0) do
  ...
end
```

Use `:allow` when `request.enlarge == true`; use `:deny` otherwise.

- [ ] **Step 4: Replace crop and gravity construction**

Add private helpers:

```elixir
defp imgproxy_resize_dimension(nil), do: Dimension.auto()
defp imgproxy_resize_dimension(:auto), do: Dimension.auto()
defp imgproxy_resize_dimension({:pixels, 0}), do: Dimension.auto()
defp imgproxy_resize_dimension({:pixels, value}) when value > 0, do: Dimension.pixels(value)
defp imgproxy_resize_dimension({:scale, value}), do: decimal_ratio(value)

defp imgproxy_crop_dimension(:auto), do: Dimension.full_axis()
defp imgproxy_crop_dimension({:pixels, 0}), do: Dimension.full_axis()
defp imgproxy_crop_dimension({:pixels, value}) when value > 0, do: Dimension.pixels(value)
defp imgproxy_crop_dimension({:scale, value}), do: decimal_ratio(value)
```

Use `Operation.crop_guided` with `Gravity.anchor/2` or `Gravity.focal_point/5`.

Preserve current imgproxy validation behavior. Do not globally map `0`, `nil`, or `:auto` through one helper; resize and crop semantics differ. Parser defaults that affect output must be explicit, including center gravity when syntax omits guide/focus.

No parser path may call `Dimension.pixels(0)`. Zero must be normalized to the context-specific semantic value before constructor calls.

Canvas dimension helpers must reject zero dimensions or preserve current imgproxy validation behavior; they must not pass zero to `Dimension.pixels/1`.

Prefer exact decimal-string-to-rational conversion when the raw token is available. If the current parser has already converted scale input to float, use a named helper such as `decimal_ratio/1` that reduces through `Dimension.ratio/2` and documents the compatibility rounding policy.

- [ ] **Step 5: Replace canvas and orientation construction**

Map:

- extend/extend-aspect-ratio -> `Operation.canvas`
- auto-orient -> `Operation.auto_orient`
- rotate -> `Operation.rotate`
- flip -> `Operation.flip`

- [ ] **Step 6: Run parser tests**

Run:

```bash
mise exec -- mix format lib/image_plug/parser/imgproxy/plan_builder.ex test/parser/imgproxy/plan_builder_test.exs test/parser/imgproxy_test.exs
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs
```

Expected: parser tests pass with semantic Plan operations.

- [ ] **Step 7: Commit semantic parser output**

Run:

```bash
mise exec -- git add lib/image_plug/parser/imgproxy test/parser
mise exec -- git commit -m "feat: emit semantic operations from imgproxy parser"
```

---

### Task 10: Remove First-Slice Obsolete Executable Semantics From Parser Surface

**Files:**
- Modify: `docs/transform_operations.md`
- Modify: executable operation docs mentioning Native parser behavior
- Modify: `test/image_plug/architecture_boundary_test.exs`
- Modify: `lib/image_plug/transform.ex`

- [ ] **Step 1: Update transform operation docs**

In `docs/transform_operations.md`, change the operation catalog to explain:

- Parser authors construct `ImagePlug.Plan.Operation.*`.
- `ImagePlug.Transform.Operation.*` modules are executable lowering targets for local backend work.
- `ResizeAuto` is semantic Plan intent; existing `AdaptiveResize` is an executable compatibility target only during the migration and should not be emitted by parsers.

- [ ] **Step 2: Update executable operation moduledocs**

In existing executable operation files, remove statements that say Native/Imgproxy parser directly emits them. Replace with wording like:

```elixir
The Transform resolver may lower semantic Plan operations to this executable operation.
Parser modules should construct ImagePlug.Plan.Operation.* through Plan constructors.
```

- [ ] **Step 3: Tighten architecture boundary tests**

Update `test/image_plug/architecture_boundary_test.exs`:

- Runtime must not alias, import, construct, or pattern match on concrete `ImagePlug.Plan.Operation.*` modules.
- Runtime must not alias, import, construct, or pattern match on concrete `ImagePlug.Transform.Operation.*` modules.
- Parser-specific structs under `ImagePlug.Parser.Imgproxy.*` must not appear in runtime.
- Cache key construction must not reference `ImagePlug.Transform.Resolver`, `ImagePlug.Transform.SourceMetadata`, `ImagePlug.Transform.ResolvedPlan`, or `ImagePlug.Transform.Derivation`.
- `ImagePlug.Parser.Imgproxy` must not reference executable `ImagePlug.Transform.Operation.*` modules after Task 9.

Keep Transform resolver allowed to reference concrete semantic and executable operation modules:

- `ImagePlug.Transform.Resolver` may reference `ImagePlug.Plan.Operation.*`.
- `ImagePlug.Transform.Resolver.Lowering` may reference `ImagePlug.Transform.Operation.*`.
- Runtime may pass opaque executable operation values returned by `Transform.resolve/3` into `Transform.Chain.execute/2`.

Boundary tests should reject concrete module references, construction, and pattern matching in runtime code. They should not reject opaque transport of resolved executable work through generic Transform facades.

- [ ] **Step 4: Remove impossible internal misuse guards if exposed by refactor**

Review `ImagePlug.Transform.operation?/1`, `ensure_operation/1`, and `ensure_operation!/1`. If they now exist only for impossible internal misuse, remove them and the exact tests that assert tidy errors for malformed hand-built structs. Keep `Transform.validate/1`, `metadata/1`, and `execute/2` as trusted behaviour dispatch helpers for executable work.

Do not remove defensive behavior merely because it is untidy if current public-ish tests or runtime boundaries still rely on it. Prefer shrinking unsupported internal API surface when the code path is unreachable after semantic validation.

- [ ] **Step 5: Run boundary and docs-related tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/operation/*.ex test/image_plug/architecture_boundary_test.exs
mise exec -- mix test test/image_plug/architecture_boundary_test.exs test/image_plug/transform/material_test.exs test/transform_chain_test.exs
```

Expected: boundary tests enforce the new runtime shape; transform chain tests still pass.

- [ ] **Step 6: Commit boundary cleanup**

Run:

```bash
mise exec -- git add lib/image_plug/transform.ex lib/image_plug/transform/operation docs/transform_operations.md test/image_plug/architecture_boundary_test.exs
mise exec -- git commit -m "refactor: document semantic transform boundary"
```

---

### Task 11: Add Cache, Derivation, And Equivalence Regression Tests

**Files:**
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Modify: `test/image_plug/transform/resolver_test.exs`
- Modify: `test/image_plug/transform_ir_characterization_test.exs`
- Test: existing parser/runtime tests

- [ ] **Step 1: Add forbidden key mutation regression**

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "post-fetch derivations are not accepted as final output cache key inputs" do
  key_before =
    build_key!(
      conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
      plan_with_resize_auto(),
      "origin-version-1"
    )

  derivation = %ImagePlug.Transform.Derivation{
    code: :resize_auto_branch,
    value: :cover,
    pipeline_index: 0,
    operation_index: 0,
    material?: false,
    details: %{}
  }

  key_after_resolve =
    build_key!(
      conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
      plan_with_resize_auto(),
      "origin-version-1"
    )

  serialized = ImagePlug.Cache.Key.serialize_material(key_before.material)

  assert key_before == key_after_resolve
  assert [[material]] = key_before.material[:pipelines]
  assert material[:op] == :resize_auto
  refute Keyword.has_key?(material, :selected_branch)
  refute Keyword.has_key?(material, :branch)
  refute serialized =~ "resize_auto_branch"
  refute serialized =~ "selected_branch"
  refute serialized =~ "Derivation"
  refute Keyword.has_key?(key_before.material, :derivations)
  assert key_before.material[:resolver_material] in [nil, []]
end
```

Use a private `plan_with_resize_auto/0` helper in that test file. The assertion proves the cache key material does not include derivation structs or derived branch labels. Prefer structural material assertions over broad substring checks; use serialization only as a fallback for absence checks when material shape is opaque. If `Cache.Key` has a public builder, also add a negative test that it accepts a semantic `Plan` and does not accept `ResolvedPlan`.

- [ ] **Step 2: Add ResizeAuto determinism examples**

In `test/image_plug/transform/resolver_test.exs`, add table-driven cases:

```elixir
for {source, target, expected} <- [
      {{1600, 900}, {300, 200}, :cover},
      {{1600, 900}, {200, 300}, :fit},
      {{1000, 1000}, {300, 300}, :cover},
      {{1000, 1000}, {300, 200}, :fit}
    ] do
  test "resize auto #{inspect(source)} to #{inspect(target)} derives #{expected}" do
    ...
  end
end
```

Generate source metadata and semantic operation per case. Assert the derivation value and lowered resize mode.

- [ ] **Step 3: Add source freshness cache tests**

Add tests that show:

- same semantic material + same source freshness identity -> same key
- same semantic material + changed source freshness identity -> different key
- changed cachebuster -> different key without changing pipeline material
- changed backend profile/material version -> different key without changing pipeline material

Use `origin_identity` strings such as `"asset:cat:v1"` and `"asset:cat:v2"` to model strong freshness material without origin fetch.

- [ ] **Step 4: Add old-vs-new executable equivalence tests**

Extend `test/image_plug/transform_ir_characterization_test.exs` to compare semantic-resolved executable pipelines to the old executable operations for representative requests:

- `fit 300x200`
- `fill 100x100 center`
- `auto landscape target`
- `force width auto`
- explicit crop center `50x50`
- canvas extend to `320x240`

For each case:

1. Execute old executable operations against a generated image.
2. Resolve semantic operations against matching source metadata.
3. Execute resolved executable operations against the same generated image.
4. Assert final dimensions match.

- [ ] **Step 5: Add parser and cache boundary regressions**

Add focused regressions that prove:

- After Task 9, parsed plans contain no `ImagePlug.Transform.Operation.*` structs.
- A semantic `ResizeAuto` cache hit returns without origin fetch, metadata read, decode/open, or source-aware lowering.
- Cache key construction does not call `Transform.resolve/3`.
- Runtime does not perform a second lookup after source-aware resolution.

- [ ] **Step 6: Run regression suite**

Run:

```bash
mise exec -- mix format test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/transform/resolver_test.exs test/image_plug/transform_ir_characterization_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/transform/resolver_test.exs test/image_plug/transform_ir_characterization_test.exs
```

Expected: cache material remains semantic and source-fetch-free; semantic resolution preserves current executable results for the first-slice examples.

- [ ] **Step 7: Commit regression tests**

Run:

```bash
mise exec -- git add test/image_plug/cache test/image_plug/transform test/image_plug/transform_ir_characterization_test.exs
mise exec -- git commit -m "test: lock semantic transform cache invariants"
```

---

### Task 12: Final Documentation, Formatting, Boundary, And Full Verification

**Files:**
- Modify: `docs/imgproxy_path_api.md`
- Modify: `docs/transform_operations.md`
- Modify: `README.md` if it references Native parser docs or examples

- [ ] **Step 1: Update docs**

Update docs to reflect:

- `ImagePlug.Parser.Imgproxy` is the compatibility parser.
- The native ImagePlug model is `ImagePlug.Plan`, not a URL syntax.
- Parser syntax maps into `ImagePlug.Plan.Operation.*`.
- Final cache lookup is source-fetch-free and uses semantic material.
- `ResizeAuto` is cache-keyed as semantic intent; selected fit/cover branch is a derivation.

- [ ] **Step 2: Search for stale Native parser references**

Run:

```bash
rg "Parser.Native|ImagePlug.Parser.Native|Native Path API|native_path_api|native parser|Native parser" lib test docs README.md mix.exs
```

Expected: no stale references, except historical wording in the approved design spec if intentionally retained.

- [ ] **Step 3: Run focused verification**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_plug/transform/resolver_test.exs test/image_plug/cache/key_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/request_safety_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: all commands pass.

- [ ] **Step 4: Run full verification**

Run:

```bash
mise exec -- mix test
```

Expected: full suite passes.

- [ ] **Step 5: Commit final docs and verification cleanup**

Run:

```bash
mise exec -- git add README.md docs lib test mix.exs
mise exec -- git commit -m "docs: finalize transform ir implementation docs"
```

---

## Self-Review

Spec coverage:

- Current imgproxy-compatible behavior first: Tasks 1, 2, 9, and 11.
- Rename Native to Imgproxy: Task 2.
- Canonical Plan operations: Task 4.
- Resolver and source-aware derivations: Tasks 5, 6, and 8.
- Final output cache lookup source-fetch-free: Tasks 7 and 11.
- Runtime generic boundary: Tasks 8 and 10.
- No first-slice capability framework or strategy execution: File Structure, Task 3, Task 5, and Task 10 explicitly avoid them.
- Vendor fixtures before IR expansion: Task 3.
- Vertical operation slices: Tasks 4, 5, 6, 9, and 11 require constructor/material/lowering/derivation/cache tests.

Placeholder scan:

- The plan contains no unbounded implementation steps.
- Each task has exact files, commands, and expected test outcomes.
- Deferred future behavior is explicitly excluded from the first slice instead of described as implementation work.

Type consistency:

- Semantic operations live under `ImagePlug.Plan.Operation.*`.
- Source metadata, derivations, resolved plans, and backend profile live under `ImagePlug.Transform.*`.
- Parser namespace is consistently `ImagePlug.Parser.Imgproxy` after Task 2.
- First-slice resolver output uses derivations and empty selections/resolver material.
