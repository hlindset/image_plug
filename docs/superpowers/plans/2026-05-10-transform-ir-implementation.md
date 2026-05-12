# Transform IR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. If Superpowers is unavailable in the execution environment, execute sequentially with the same verification gates and commit/checkpoint boundaries. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current overloaded executable transform structs with a narrow semantic Plan IR for the current imgproxy-compatible behavior, while keeping final output cache lookup source-fetch-free.

**Architecture:** Add a small canonical Plan operation set under `ImagePlug.Plan.Operation.*`, keep parser quirks in the renamed `ImagePlug.Parser.Imgproxy`, and execute Plans through `ImagePlug.Transform.execute_plan/4`. Cache keys are built from prefetch-safe semantic key data, source freshness identity, output/config key data, and the cache key's transform key data version; source-aware execution choices stay internal to ordered Plan execution and never mutate final cache keys.

**Tech Stack:** Elixir 1.17, ExUnit, StreamData, Boundary, Plug, Vix/Image, existing `ImagePlug.Transform` facade.

---

## File Structure

Create these semantic Plan files:

- `lib/image_plug/plan/operation.ex` - exported constructor/validation facade for Plan operations.
- `lib/image_plug/plan/operation/resize.ex` - one resize operation with `mode: :fit | :cover | :stretch | :auto`.
- `lib/image_plug/plan/operation/crop_region.ex` - exact current-image region crop at this operation point.
- `lib/image_plug/plan/operation/crop_guided.ex` - size-plus-guide crop operation.
- `lib/image_plug/plan/operation/canvas.ex` - place current image onto an explicit canvas.
- `lib/image_plug/transform/key_data.ex` - plain module that converts supported Plan/executable operations to cache key data.

Do not create Plan geometry structs in the first slice unless a tagged tuple is proven insufficient. Represent small geometry values directly:

```elixir
:auto
:full_axis
{:px, pos_integer()}
{:ratio, non_neg_integer(), pos_integer()}
:center
:top_left
{:fp, {:ratio, x_num, x_den}, {:ratio, y_num, y_den}}
```

Use the narrow existing executable orientation operations directly in Plans when needed:

- `ImagePlug.Transform.Operation.AutoOrient`
- `ImagePlug.Transform.Operation.Rotate`
- `ImagePlug.Transform.Operation.Flip`

Create these Transform execution files only if the logic does not fit cleanly in `ImagePlug.Transform`:

- `lib/image_plug/transform/source_metadata.ex` - minimal source metadata struct passed to Plan execution.
- `lib/image_plug/transform/plan_executor.ex` - optional private/internal implementation of `Transform.execute_plan/4`.
- `lib/image_plug/transform/plan_executor/geometry.ex` - optional shared integer geometry helpers for ordered Plan execution.

Do not create:

- `ImagePlug.Transform.ResolvedPlan`
- `ImagePlug.Transform.Resolver`
- `ImagePlug.Transform.Resolver.Lowering`
- `ImagePlug.Transform.Resolver.Geometry`

Rename these parser files:

- `lib/image_plug/parser/native.ex` -> `lib/image_plug/parser/imgproxy.ex`
- `lib/image_plug/parser/native/*.ex` -> `lib/image_plug/parser/imgproxy/*.ex`
- `test/parser/native_test.exs` -> `test/parser/imgproxy_test.exs`
- `test/parser/native_property_test.exs` -> `test/parser/imgproxy_property_test.exs`
- `test/parser/native/plan_builder_test.exs` -> `test/parser/imgproxy/plan_builder_test.exs`
- `docs/native_path_api.md` -> `docs/imgproxy_path_api.md`

Modify these existing files:

- `lib/image_plug/plan.ex` - export new Plan operation/value modules and validate semantic operations.
- `lib/image_plug/plan/pipeline.ex` - type operations as the small Plan operation set plus the narrow orientation primitive allowlist.
- `lib/image_plug/parser.ex` - export `Imgproxy`, not `Native`.
- `lib/image_plug/parser/imgproxy/plan_builder.ex` - emit semantic Plan operations through constructors.
- `lib/image_plug/cache/key.ex` - collect semantic Plan operation key data and include output/config key data plus the cache key's transform key data version.
- `lib/image_plug/runtime/request_runner.ex` - build cache key before source fetch; execute the Plan only on cache miss or uncached execution.
- `lib/image_plug/runtime/processor.ex` - call `ImagePlug.Transform.execute_plan/4` after source fetch/decode.
- `lib/image_plug/transform.ex` - add `execute_plan/4` and remove defensive operation duck-typing once Plan validation replaces it.
- `lib/image_plug/transform/decode_planner.ex` - use resolved executable work for decode/open planning after cache miss.
- `docs/transform_operations.md` - update parser author guidance from executable operations to Plan operations plus `Transform.execute_plan/4`.
- `mix.exs` - point docs extras at `docs/imgproxy_path_api.md`.
- `test/image_plug/architecture_boundary_test.exs` - update concrete operation deny-list and parser namespace checks.

Keep these existing executable modules in the first slice as execution targets:

- `ImagePlug.Transform.Operation.Resize`
- `ImagePlug.Transform.Operation.AdaptiveResize`
- `ImagePlug.Transform.Operation.Crop`
- `ImagePlug.Transform.Operation.ExtendCanvas`
- `ImagePlug.Transform.Operation.AutoOrient`
- `ImagePlug.Transform.Operation.Rotate`
- `ImagePlug.Transform.Operation.Flip`

Do not introduce backend operation structs in this plan unless an executable operation cannot represent the resolved work correctly.

---

## Ruthless Simplification Amendment

This amendment supersedes any older snippets in this plan that still mention resolver plans, geometry structs, coordinate spaces, selections, or split resize modules.

Cut these concepts from the target implementation:

- No `%ImagePlug.Transform.ResolvedPlan{}`. `Transform.execute_plan/4` returns `{:ok, %State{}} | {:error, reason}`.
- No `ImagePlug.Transform.Resolver.*` namespace. If a helper module is needed, use an internal Plan execution name such as `ImagePlug.Transform.PlanExecutor`.
- No `selections`, `resolver_material`, or `resolver_key_data` fields. Future work can add a concrete field when a real caller consumes it.
- No `space: :source | :current | :post_orient` on Transform-facing crop or guide data. Parser/planner canonicalization owns coordinate semantics before Plan construction.
- No separate `Dimension`, `Size`, or `Region` structs unless tagged tuples become demonstrably inadequate.
- No split resize operation modules. Prefer one `%ImagePlug.Plan.Operation.Resize{mode: ...}`.
- No Plan wrappers for one-to-one orientation primitives. Allow only the narrow product-neutral executable primitives `AutoOrient`, `Rotate`, and `Flip` directly in Plan pipelines.
- No `ImagePlug.Transform.KeyData` protocol unless open polymorphism is truly needed. Prefer a plain module with pattern-matched `data/1` clauses over protocol dispatch for this closed set.
- No defensive revalidation of trusted constructed internals. Validate external parser/constructor input once, then trust the narrower structs/tuples inside Transform.

Target Plan operation shape:

```elixir
%ImagePlug.Plan.Operation.Resize{
  mode: :fit | :cover | :stretch | :auto,
  width: :auto | {:px, pos_integer()},
  height: :auto | {:px, pos_integer()},
  dpr: pos_integer() | float(),
  enlargement: :allow | :deny,
  guide: :center | :top_left | {:fp, ratio(), ratio()},
  min_width: nil | {:px, pos_integer()},
  min_height: nil | {:px, pos_integer()},
  zoom_x: pos_integer() | float(),
  zoom_y: pos_integer() | float()
}

%ImagePlug.Plan.Operation.CropRegion{
  x: {:px, non_neg_integer()} | ratio(),
  y: {:px, non_neg_integer()} | ratio(),
  width: {:px, pos_integer()} | ratio(),
  height: {:px, pos_integer()} | ratio()
}

%ImagePlug.Plan.Operation.CropGuided{
  width: :full_axis | {:px, pos_integer()} | ratio(),
  height: :full_axis | {:px, pos_integer()} | ratio(),
  guide: :center | :top_left | {:fp, ratio(), ratio()},
  x_offset: number() | {:pixels, number()} | {:scale, number()},
  y_offset: number() | {:pixels, number()} | {:scale, number()}
}

%ImagePlug.Plan.Operation.Canvas{
  width: :auto | {:px, pos_integer()} | ratio(),
  height: :auto | {:px, pos_integer()} | ratio(),
  placement: :center | :top_left | {:fp, ratio(), ratio()},
  background: :white,
  overflow: :reject
}
```

where:

```elixir
@type ratio :: {:ratio, non_neg_integer(), pos_integer()}
```

`ratio()` is unsigned. Signed scale offsets are not represented as `ratio()` in
the first slice; they remain offset fields and are normalized separately.

Normalize DPR key data so equivalent inputs such as `1`, `1.0`, and `1.00`
produce identical key data, for example:

```elixir
dpr: [unit: :ratio, numerator: 1, denominator: 1]
```

Constructor facade shape:

```elixir
Operation.resize(mode, width, height, opts \\ [])
Operation.crop_region(x, y, width, height)
Operation.crop_guided(width, height, guide, opts \\ [])
Operation.canvas(width, height, placement, opts \\ [])
```

Use keyword options only for genuinely optional fields. Do not accept multiple equivalent input shapes in internal constructors.

---

## Terminology Decisions

- The runtime entry point is `ImagePlug.Transform.execute_plan/4`. Do not add `execute_semantic_plan/4`; older design notes used that name.
- Cache key inputs are called key data. Old `material` naming should be renamed or treated as legacy during migration.
- A unified semantic resize operation uses key data `op: :resize, mode: ...`. Do not introduce `op: :resize_auto`.
- `ratio()` is unsigned and canonicalized with `Integer.gcd/2`. Signed offsets are separate offset fields, not `ratio()`.
- `SourceMetadata` does not carry current width/height in the first slice; Plan execution reads dimensions from `State.image`.
- Parsed plans may contain only semantic Plan operations plus the explicit orientation primitive allowlist: `AutoOrient`, `Rotate`, and `Flip`.
- Before Task 7, existing tests may use `key.material`. Task 7 is the migration point to `key.data`; update characterization tests during Task 7 if the key struct field is renamed.

---

## Implementation Guardrails

- Safe execution order is Tasks 0 through 12 as written. Task 9 switches Imgproxy parser output; Tasks 7 and 8 must pass before Task 9 starts.
- Cache key construction must not call `Transform.resolve/3`, origin fetch, metadata extraction, image decode/open, or source-aware geometry helpers.
- The final output cache key must be built before origin fetch and must not be rebuilt or mutated after post-fetch source-aware resolution.
- On cache miss, runtime must store under the same cache key returned by the prefetch-safe lookup; it must not build a resolved-operation key after source-aware resolution.
- Runtime may call generic Plan/Transform validation and execution facades, but it must not pattern-match on concrete `ImagePlug.Plan.Operation.*` or `ImagePlug.Transform.Operation.*` modules.
- Runtime may carry executable transform structs opaquely through `ImagePlug.Transform.Chain`, but must not branch on their concrete modules.
- Semantic Plan constructor APIs must return `{:ok, value}` or `{:error, reason}`. Do not introduce public bang constructors for semantic Plan values or operations; local test helpers such as `build_key!/3` or `execute!/2` are fine when they wrap assertions.
- Parser defaults that affect output, such as center gravity, DPR `1.0`, and enlargement policy, must be explicit in canonical Plan key data.
- `ResizeAuto` and cover behavior must be verified against current parser/request-level behavior before Plan execution is finalized.
- Do not model first-slice selections, resolver key data, or derivations. Execution choices are reflected in executed work and tests, not stored in a separate data structure.
- Parser output must eventually contain only canonical `ImagePlug.Plan.Operation.*` structs plus the explicit orientation primitive allowlist: `AutoOrient`, `Rotate`, and `Flip`.
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

Use that test to reconcile current behavior with the design rule before implementing `ResizeAuto` Plan execution. Do not leave this as a placeholder test.

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
      notes: "branch is source-aware execution state, not cache key data"
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
      notes: "IIIF parser must emit ordinary crop before resize"
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

### Task 4: Add Simplified Plan Operation Constructors And Prefetch-Safe Key Data

**Files:**
- Create: Plan operation/value files listed in File Structure
- Modify: `lib/image_plug/plan.ex`
- Modify: `lib/image_plug/plan/pipeline.ex`
- Rename/modify: `lib/image_plug/transform/material.ex` -> `lib/image_plug/transform/key_data.ex`
- Create: `test/image_plug/plan/operation_test.exs`
- Create: `test/image_plug/plan/operation_key_data_test.exs`

Execute this task as vertical subtasks, not one large commit. Use the simplified target from the Ruthless Simplification Amendment, even where older examples below still show split resize or geometry value modules.

- 4A: tagged geometry values and key data helpers.
- 4B: one resize operation struct/constructor/key data.
- 4C: crop operation structs/constructors/key data.
- 4D: canvas operation struct/constructor/key data.
- 4E: orientation primitive allowlist key data.

Each subtask should add tagged-tuple constructors, validation, key data, focused tests, `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, and the relevant focused ExUnit file before moving on. Commit each subtask separately when git identity is available:

- `feat: add semantic geometry key data`
- `feat: add semantic resize operation`
- `feat: add semantic crop operations`
- `feat: add semantic canvas operation`
- `feat: add semantic orientation operations`

- [ ] **Step 1: Write failing constructor tests**

Create `test/image_plug/plan/operation_test.exs` for the simplified constructor facade:

```elixir
defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation

  test "builds resize operations through one constructor" do
    assert {:ok, %Operation.Resize{mode: :fit}} =
             Operation.resize(:fit, {:px, 300}, :auto, enlargement: :allow)

    assert {:ok, %Operation.Resize{mode: :cover, guide: :center}} =
             Operation.resize(:cover, {:px, 300}, {:px, 200},
               enlargement: :deny,
               guide: :center
             )

    assert {:ok, %Operation.Resize{mode: :stretch}} =
             Operation.resize(:stretch, :auto, {:px, 100}, enlargement: :allow)

    assert {:ok, %Operation.Resize{mode: :auto}} =
             Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)
  end

  test "builds crop and canvas operations through narrow constructors" do
    assert {:ok, %Operation.CropRegion{}} =
             Operation.crop_region({:ratio, 1, 10}, {:ratio, 1, 10}, {:ratio, 1, 2}, {:ratio, 1, 2})

    assert {:ok, %Operation.CropGuided{}} =
             Operation.crop_guided({:px, 120}, :full_axis, :center)

    assert {:ok, %Operation.Canvas{}} =
             Operation.canvas({:px, 120}, {:px, 50}, :center,
               background: :white,
               overflow: :reject
             )
  end

  test "rejects malformed external construction input" do
    assert {:error, _reason} = Operation.resize(:fit, {:px, 0}, :auto, enlargement: :allow)
    assert {:error, _reason} = Operation.crop_region({:ratio, 1, 0}, {:px, 0}, {:px, 10}, {:px, 10})
  end
end
```

- [ ] **Step 2: Write failing key data tests**

Create `test/image_plug/plan/operation_key_data_test.exs`:

```elixir
defmodule ImagePlug.Plan.OperationKeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.KeyData

  test "resize auto key data is unresolved semantic intent" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 300}, {:px, 200},
               dpr: 2.0,
               enlargement: :deny
             )

    assert KeyData.data(operation) == [
             op: :resize,
             mode: :auto,
             width: [unit: :logical_px, value: 300],
             height: [unit: :logical_px, value: 200],
             dpr: [unit: :ratio, numerator: 2, denominator: 1],
             enlargement: :deny,
             guide: :center,
             rule: :imgproxy_orientation_match_v1
           ]
  end

  test "crop region key data has no source/current coordinate space" do
    assert {:ok, operation} =
             Operation.crop_region({:ratio, 1, 10}, {:ratio, 1, 10}, {:ratio, 1, 2}, {:ratio, 1, 2})

    assert KeyData.data(operation) == [
             op: :crop_region,
             x: [unit: :ratio, numerator: 1, denominator: 10],
             y: [unit: :ratio, numerator: 1, denominator: 10],
             width: [unit: :ratio, numerator: 1, denominator: 2],
             height: [unit: :ratio, numerator: 1, denominator: 2]
           ]
  end

  test "ratio key data is canonicalized" do
    assert KeyData.data({:ratio, 2, 4}) ==
             [unit: :ratio, numerator: 1, denominator: 2]
  end
end
```

- [ ] **Step 3: Implement tagged geometry validation and normalization**

Do not add `Dimension`, `Size`, `Region`, or `Gravity` structs. Keep geometry values as tagged tuples/atoms and normalize them once at the constructor boundary:

```elixir
:auto
:full_axis
{:px, pos_integer()}
{:ratio, non_neg_integer(), pos_integer()}
:center | :top_left | :top | :top_right | :left | :right | :bottom_left | :bottom | :bottom_right
{:fp, {:ratio, x_num, x_den}, {:ratio, y_num, y_den}}
```

Normalize ratios with `Integer.gcd/2` so equivalent ratios produce identical key data. Reject `{:px, 0}` where the axis must be positive; parser code must translate imgproxy zero tokens to `:auto` or `:full_axis` before calling constructors.

- [ ] **Step 4: Add simplified operation structs and constructors**

Add:

```elixir
Operation.resize(:fit | :cover | :stretch | :auto, width, height, opts \\ [])
Operation.crop_region(x, y, width, height)
Operation.crop_guided(width, height, guide, opts \\ [])
Operation.canvas(width, height, placement, opts \\ [])
```

Use keyword options only for real optional fields. Do not accept both maps and keywords, existing structs, or broad coercions. Do not add `SetFocus`, `SetGravity`, `StrategyList`, `ResizeContain`, backend operation structs, or Plan wrappers for one-to-one orientation primitives.

- [ ] **Step 5: Rename material terminology to key data and implement `ImagePlug.Transform.KeyData`**

Rename the transform cache-key facade from `ImagePlug.Transform.Material` to `ImagePlug.Transform.KeyData`, with `KeyData.data/1` as the preferred API. Implement it as a plain module with pattern-matched clauses unless existing code proves protocol dispatch is necessary.

Key data must be keyword lists and source-fetch-free. `Resize` with `mode: :auto` key data must not contain the selected fit/cover branch.

- [ ] **Step 6: Export only the simplified operation modules**

Update `lib/image_plug/plan.ex` Boundary exports to include:

```elixir
Operation,
Operation.Resize,
Operation.CropRegion,
Operation.CropGuided,
Operation.Canvas
```

Update `lib/image_plug/plan/pipeline.ex` type to include the simplified Plan operations plus the narrow executable orientation primitive allowlist:

```elixir
@type operation() ::
        ImagePlug.Plan.Operation.Resize.t()
        | ImagePlug.Plan.Operation.CropRegion.t()
        | ImagePlug.Plan.Operation.CropGuided.t()
        | ImagePlug.Plan.Operation.Canvas.t()
        | ImagePlug.Transform.Operation.AutoOrient.t()
        | ImagePlug.Transform.Operation.Rotate.t()
        | ImagePlug.Transform.Operation.Flip.t()

@type t :: %__MODULE__{operations: [operation()]}
```

- [ ] **Step 7: Run focused tests**

Run:

```bash
mise exec -- mix format lib/image_plug/plan.ex lib/image_plug/plan/pipeline.ex lib/image_plug/plan/operation.ex lib/image_plug/plan/operation/*.ex lib/image_plug/transform/key_data.ex test/image_plug/plan/operation_test.exs test/image_plug/plan/operation_key_data_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/plan/operation_test.exs test/image_plug/plan/operation_key_data_test.exs test/image_plug/transform/key_data_test.exs
```

Expected: new Plan operation tests pass, and transform key data tests cover the renamed protocol/facade.

- [ ] **Step 8: Commit semantic operation key data**

If the 4A-4E subtasks were not already committed individually, run:

```bash
mise exec -- git add lib/image_plug/plan lib/image_plug/transform/key_data.ex test/image_plug/plan test/image_plug/transform/key_data_test.exs
mise exec -- git commit -m "feat: add semantic plan operation key data"
```

---

### Task 5: Add Transform Plan Execution Facade And ResizeAuto Execution

**Files:**
- Create: `lib/image_plug/transform/source_metadata.ex`
- Optional create: `lib/image_plug/transform/plan_executor.ex`
- Optional create: `lib/image_plug/transform/plan_executor/geometry.ex`
- Modify: `lib/image_plug/transform.ex`
- Test: `test/image_plug/transform/plan_executor_test.exs`

Do not create `ResolvedPlan` or `Resolver` modules in this task. The runtime-facing abstraction is `Transform.execute_plan/4`.

- [ ] **Step 1: Write failing ordered Plan execution tests**

Create `test/image_plug/transform/plan_executor_test.exs`:

```elixir
defmodule ImagePlug.Transform.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  test "resize auto executes against current image state" do
    assert {:ok, operation} = Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)
    state = state_with_image(1600, 900)
    metadata = metadata(1600, 900)

    assert {:ok, %State{} = state} = Transform.execute_plan(plan([operation]), state, metadata, [])
    assert dimensions(state.image) == {300, 200}
  end

  test "ordered resize then ratio crop uses actual post-resize dimensions" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 300}, {:px, 200}, enlargement: :deny)
    assert {:ok, crop} = Operation.crop_region({:ratio, 1, 10}, {:ratio, 1, 10}, {:ratio, 1, 2}, {:ratio, 1, 2})

    assert {:ok, %State{} = state} =
             Transform.execute_plan(plan([resize, crop]), state_with_image(600, 400), metadata(600, 400), [])

    assert dimensions(state.image) == {150, 100}
  end
end
```

Use the image helpers discovered in Task 0. The assertions should observe final image dimensions, not internal executable operation lists.

- [ ] **Step 2: Add `SourceMetadata` constructor**

Add `%ImagePlug.Transform.SourceMetadata{}` with only facts the current image cannot provide or that runtime/source opening already owns:

```elixir
%ImagePlug.Transform.SourceMetadata{
  orientation: :normal | :unknown | {:exif, 1..8},
  format: atom() | nil,
  source_type: :raster | :animated_raster | :vector,
  has_alpha?: boolean()
}
```

Do not duplicate current width/height here unless a current implementation path truly cannot read them from `State.image`. `Transform.execute_plan/4` should prefer current image facts from `State.image`.

Provide `SourceMetadata.new/1` for runtime construction. `execute_plan/4` may trust `%SourceMetadata{}` once runtime has constructed it; do not revalidate it on every internal operation.

- [ ] **Step 3: Add `Transform.execute_plan/4`**

`Transform.execute_plan/4` should:

1. Validate only source-independent Plan boundary invariants.
2. Walk pipelines in order.
3. Walk operations in order.
4. For each Plan operation, compute executable operations against the actual current `State.image`.
5. Immediately pass those executable operations to `ImagePlug.Transform.Chain.execute/2`.
6. Return `{:ok, %State{}} | {:error, reason}`.

Target shape:

```elixir
def execute_plan(%Plan{} = plan, %State{} = state, %SourceMetadata{} = metadata, opts \\ []) do
  with {:ok, pipelines} <- validate_prefetch_safe_plan(plan),
       {:ok, state} <- execute_pipelines(pipelines, state, metadata, opts) do
    {:ok, state}
  end
end
```

Use `with` only where it keeps the success path linear. Keep operation-specific dispatch in multi-clause private functions.

- [ ] **Step 4: Implement ResizeAuto branch selection inside Plan execution**

`Resize` with `mode: :auto` should:

- read current dimensions from the actual current image;
- compute target orientation from requested logical pixel width/height;
- select cover when both orientations are known and equal, including square-to-square;
- select fit otherwise;
- execute the existing executable sequence for that branch immediately;
- never write the selected branch into cache key data.

If Task 1 proves current request-visible cover/fill requires resize plus result crop, emit that executable sequence. If Task 1 proves `%Resize{mode: :fill}` alone already produces exact output dimensions, document that proof in the test and use the simpler sequence.

- [ ] **Step 5: Run Plan executor tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/source_metadata.ex lib/image_plug/transform/plan_executor*.ex test/image_plug/transform/plan_executor_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/transform/plan_executor_test.exs
```

Expected: `Transform.execute_plan/4` executes operations in order and `ResizeAuto` observes actual current image dimensions.

- [ ] **Step 6: Commit Plan executor foundation**

Run:

```bash
mise exec -- git add lib/image_plug/transform.ex lib/image_plug/transform/source_metadata.ex lib/image_plug/transform/plan_executor*.ex test/image_plug/transform/plan_executor_test.exs
mise exec -- git commit -m "feat: execute transform plans in order"
```

---

### Task 6: Execute MVP Plan Operations Through Existing Executable Operations

**Files:**
- Modify: `lib/image_plug/transform.ex`
- Optional modify: `lib/image_plug/transform/plan_executor.ex`
- Optional modify: `lib/image_plug/transform/plan_executor/geometry.ex`
- Test: `test/image_plug/transform/plan_executor_test.exs`

- [ ] **Step 1: Add operation-specific execution tests**

Add table-driven tests for:

- `Resize` mode `:fit` -> existing `%Resize{rule: %DimensionRule{mode: :fit}}`
- `Resize` mode `:cover` -> existing cover/fill sequence proven by Task 1
- `Resize` mode `:stretch` -> existing `%Resize{rule: %DimensionRule{mode: :force}}`
- `CropGuided` -> existing `%Crop{crop_from: :gravity}`
- `CropRegion` -> existing `%Crop{crop_from: %{left: x, top: y}}`, using actual current image dimensions for ratios
- `Canvas` -> existing `%ExtendCanvas{}` for supported geometry
- `AutoOrient`, `Rotate`, and `Flip` primitive allowlist -> direct execution through existing executable operations

Prefer final visible image dimensions over assertions on private executable operation lists. Assert the executable sequence only where visible dimensions cannot distinguish the behavior.

- [ ] **Step 2: Implement one operation at a time**

For each Plan operation, add one private multi-clause function that returns executable operations or executes the operation directly. Do not build a whole-plan executable trace.

Suggested private shape:

```elixir
defp execute_operation(operation, state, metadata, opts) do
  with {:ok, executable_operations} <- executable_operations(operation, state, metadata, opts),
       {:ok, state} <- Chain.execute(state, executable_operations) do
    {:ok, state}
  end
end
```

`executable_operations/4` is private implementation detail. Do not expose it as a stable API.

- [ ] **Step 3: Keep source-aware facts internal**

When execution resolves a source/current dependent value, reflect the result in executed work and focused tests. Do not add derivation structs, selections, resolver key data, or a resolved-plan trace.

Useful test labels for source-aware cases include `resize_auto_branch`, `dpr_applied`, `crop_region_resolved`, and `dimension_resolved`, but these are test names/diagnostic labels rather than cache key data.

- [ ] **Step 4: Run execution and characterization tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/plan_executor*.ex test/image_plug/transform/plan_executor_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/transform/plan_executor_test.exs test/image_plug/transform_ir_characterization_test.exs
```

Expected: MVP Plan operations execute through existing transform operations while preserving current imgproxy-compatible visible behavior.

- [ ] **Step 5: Commit MVP Plan execution**

Run:

```bash
mise exec -- git add lib/image_plug/transform.ex lib/image_plug/transform/plan_executor*.ex test/image_plug/transform/plan_executor_test.exs
mise exec -- git commit -m "feat: execute mvp plan operations"
```

---

### Task 7: Make Cache Key Construction Use Semantic Key Data Before Source Fetch

**Files:**
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/response_cache.ex`
- Test: `test/image_plug/cache/key_test.exs`
- Test: `test/image_plug/runtime/request_runner_test.exs`
- Test: `test/image_plug/response_cache_test.exs`

- [ ] **Step 1: Add ResizeAuto key data cache tests**

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "resize auto key data stays unresolved and source-metadata-free" do
  assert {:ok, operation} =
           ImagePlug.Plan.Operation.resize(:auto, {:px, 300}, {:px, 200},
             dpr: 1.0,
             enlargement: :deny
           )

  plan = plan(pipelines: [%Pipeline{operations: [operation]}])
  conn = conn(:get, "/_/rt:auto/w:300/h:200/f:jpeg/plain/images/cat.jpg")

  key_a = build_key!(conn, plan, "origin-version-a")
  key_b = build_key!(conn, plan, "origin-version-b")

  assert [[operation_key_data]] = key_a.data[:pipelines]
  assert operation_key_data[:op] == :resize
  assert operation_key_data[:mode] == :auto
  refute Keyword.has_key?(operation_key_data, :selected_branch)
  serialized = ImagePlug.Cache.Key.serialize_key_data(key_a.data)
  refute serialized =~ "source_width"
  refute serialized =~ "source_height"
  refute serialized =~ "selected_branch"
  refute key_a.hash == key_b.hash
end
```

Add a cache test that asserts `Cache.Key` includes its transform key data version directly, for example:

```elixir
assert key.data[:transform] == [key_data_version: 1]
```

Do not add a configurable backend profile option in the first slice. If transform key data semantics change later, bump the cache-owned transform key data version.

- [ ] **Step 2: Add cache-hit no-origin test for semantic ResizeAuto**

Add to `test/image_plug/runtime/request_runner_test.exs`:

```elixir
test "semantic resize auto cache hit does not fetch source or resolve operations" do
  entry = %Entry{
    body: "cached jpeg",
    content_type: "image/jpeg",
    headers: [],
    created_at: DateTime.utc_now()
  }

  assert {:ok, operation} =
           ImagePlug.Plan.Operation.resize(:auto, {:px, 100}, {:px, 100},
             dpr: 1.0,
             enlargement: :deny
           )

  assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
           RequestRunner.run(
             conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"),
             plan(pipelines: [%Pipeline{operations: [operation]}]),
             "origin-version-1",
             cache: {CacheReadProbe, entry: entry}
           )

  assert_received {:cache_lookup, key}
  assert key.data[:origin_identity] == "origin-version-1"
  refute ImagePlug.Cache.Key.serialize_key_data(key.data) =~ "selected_branch"
end
```

- [ ] **Step 3: Rename legacy cache material wording and add transform key data version**

Keep `Cache.Key.build/4` source-fetch-free. Rename cache-key internals from `material` to `data` where practical in this branch, including helper names such as `serialize_material/1` -> `serialize_key_data/1`. Add the cache-owned transform key data version directly to the key:

```elixir
transform: [key_data_version: 1]
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

Keep the orientation primitive allowlist in one place, either in this facade or in `ImagePlug.Plan.Pipeline.allowed_operation?/1`. Do not scatter `%AutoOrient{}`, `%Rotate{}`, or `%Flip{}` checks across parser, runtime, cache, and transform code.

Add focused tests, preferably in `test/image_plug/transform/prefetch_validation_test.exs`, proving:

- semantic Plan operations pass
- executable `ImagePlug.Transform.Operation.*` structs in a canonical Plan fail after Task 9/10
- parser-local command structs fail
- validation does not call Plan execution, source metadata, origin fetch, or decode/open code

- [ ] **Step 5: Ensure runtime does not second-lookup with derived key data**

`RequestRunner.run/4` must:

1. Validate parser/plan source-independent shape.
2. Call `ResponseCache.lookup/4`.
3. On cache hit, return cached entry.
4. On cache miss, fetch source and resolve semantic plan.
5. Store under the original key returned by lookup.

Do not rebuild a second final key after `Transform.resolve/3`.

If `ResponseCache.lookup/4` currently builds or rebuilds keys internally, change it to return or expose the original prefetch-safe key so miss-path storage reuses exactly the same key. It must not call Plan execution or accept post-fetch execution output for final output key construction.

Add a cache probe test that fails if lookup is called more than once. Prefer an existing test helper or `start_supervised!/1` process over process dictionary state if calls can cross processes.

- [ ] **Step 6: Run cache tests**

Run:

```bash
mise exec -- mix format lib/image_plug/cache/key.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_cache.ex test/image_plug/cache/key_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
```

Expected: semantic ResizeAuto stays unresolved in key data, origin identity changes key, and `Cache.Key` includes its transform key data version. Existing executable-operation cache tests should continue to pass where they still describe supported compatibility behavior; update tests that assert old material naming or old parser-surface behavior.

- [ ] **Step 7: Commit metadata-free cache lookup**

Run:

```bash
mise exec -- git add lib/image_plug/cache/key.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_cache.ex test/image_plug/cache test/image_plug/runtime/request_runner_test.exs test/image_plug/response_cache_test.exs
mise exec -- git commit -m "feat: key transform cache by semantic intent"
```

---

### Task 8: Route Runtime Execution Through `Transform.execute_plan/4` On Cache Miss

**Files:**
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/processor.ex`
- Modify: `lib/image_plug/transform/decode_planner.ex`
- Test: `test/image_plug/runtime/request_runner_test.exs`
- Test: current processor/decode planner test files discovered in Task 0

Runtime must be capable of accepting canonical Plans before Task 9 switches the Imgproxy parser to emit the simplified Plan operations.

- [ ] **Step 1: Add miss-path Plan execution test**

Add to `test/image_plug/runtime/request_runner_test.exs` a test that uses a semantic `Resize` with `mode: :auto`, cache miss, and an existing origin image. If Task 0 finds the runtime test at a different path, use that discovered path consistently in this task.

The test should prove:

- cache lookup happens before origin fetch;
- source is fetched only on miss;
- runtime calls `Transform.execute_plan/4` after source fetch/decode;
- miss-path storage uses the original prefetch-safe key from the lookup;
- runtime does not call `Transform.resolve/3` or build a `%ResolvedPlan{}`.

- [ ] **Step 2: Build `SourceMetadata` at the runtime/source boundary**

After cache miss and image open/decode, runtime/source code should construct `%ImagePlug.Transform.SourceMetadata{}` with facts that are not read from the current `State.image` during operation execution:

```elixir
%ImagePlug.Transform.SourceMetadata{
  orientation: discovered_orientation,
  has_alpha?: has_alpha?,
  format: source_format,
  source_type: source_type
}
```

Do not default unknown orientation to `:normal`. Use `:unknown` unless metadata reading has proven normal orientation.

- [ ] **Step 3: Route processor through `Transform.execute_plan/4`**

Replace any miss-path call shaped like:

```elixir
Transform.resolve(plan, metadata, opts)
Transform.executable_pipelines(plan, metadata, opts)
```

with:

```elixir
ImagePlug.Transform.execute_plan(plan, initial_state, source_metadata, opts)
```

Runtime may pass executable operation structs to `ImagePlug.Transform.Chain.execute/2` opaquely only where existing code still needs it, but request execution should not branch on concrete Plan or Transform operation modules. Any operation-specific behavior belongs in `ImagePlug.Transform.execute_plan/4` internals or existing transform callbacks.

- [ ] **Step 4: Keep decode planning conservative before metadata**

Before source metadata is available, `DecodePlanner` must treat unresolved source-dependent geometry conservatively. A semantic plan containing `Resize` mode `:auto`, cover/fill, guided crop, canvas, or `CropRegion` should choose random access unless proven safe for sequential reads.

Do not optimize decode planning by simulating Plan execution. Later optimization can be added with tests, but first-slice correctness should not depend on prediction.

- [ ] **Step 5: Run runtime tests**

Run:

```bash
mise exec -- mix format lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/processor.ex lib/image_plug/transform/decode_planner.ex test/image_plug/runtime/request_runner_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/runtime/request_runner_test.exs test/image_plug/request_safety_test.exs
```

Expected: semantic Plans execute on cache miss/uncached path, cache hit does not fetch/decode/execute, and runtime remains generic.

- [ ] **Step 6: Commit Plan runtime path**

Run:

```bash
mise exec -- git add lib/image_plug/runtime lib/image_plug/transform/decode_planner.ex test/image_plug/runtime test/image_plug/request_safety_test.exs
mise exec -- git commit -m "feat: execute transform plans on cache miss"
```

---

### Task 9: Switch Imgproxy PlanBuilder To Emit Simplified Plan Operations

**Files:**
- Modify: `lib/image_plug/parser/imgproxy/plan_builder.ex`
- Modify: `test/parser/imgproxy/plan_builder_test.exs`
- Modify: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Update parser tests to expect simplified Plan operations**

In `test/parser/imgproxy/plan_builder_test.exs` and `test/parser/imgproxy_test.exs`, replace expectations for executable operations with simplified Plan operations:

```elixir
%Transform.Operation.Resize{} -> %ImagePlug.Plan.Operation.Resize{mode: :fit | :cover | :stretch}
%Transform.Operation.AdaptiveResize{} -> %ImagePlug.Plan.Operation.Resize{mode: :auto}
%Transform.Operation.Crop{} -> %ImagePlug.Plan.Operation.CropGuided{} or %ImagePlug.Plan.Operation.CropRegion{}
%Transform.Operation.ExtendCanvas{} -> %ImagePlug.Plan.Operation.Canvas{}
%Transform.Operation.AutoOrient{} -> %ImagePlug.Transform.Operation.AutoOrient{}
%Transform.Operation.Rotate{} -> %ImagePlug.Transform.Operation.Rotate{}
%Transform.Operation.Flip{} -> %ImagePlug.Transform.Operation.Flip{}
```

Keep parser syntax, error, output, policy, cache, response, and order-insensitivity assertions intact.

- [ ] **Step 2: Update PlanBuilder aliases**

In `lib/image_plug/parser/imgproxy/plan_builder.ex`, replace broad executable transform aliases with:

```elixir
alias ImagePlug.Plan.Operation
alias ImagePlug.Transform.Operation.AutoOrient
alias ImagePlug.Transform.Operation.Rotate
alias ImagePlug.Transform.Operation.Flip
```

Do not alias `ImagePlug.Plan.Geometry.*` or guide structs; they should not exist in the simplified target.

- [ ] **Step 3: Replace resize construction**

Change resize planning to call one constructor:

```elixir
Operation.resize(mode, width, height,
  dpr: dpr,
  enlargement: enlargement,
  guide: guide,
  min_width: min_width,
  min_height: min_height,
  zoom_x: zoom_x,
  zoom_y: zoom_y
)
```

Use `:allow` when `request.enlarge == true`; use `:deny` otherwise. Parser defaults that affect output must be explicit, including center guide and DPR `1.0`.

- [ ] **Step 4: Replace dimension, crop, guide, and canvas construction**

Use context-specific parser helpers that return tagged values:

```elixir
defp imgproxy_resize_dimension(nil), do: {:ok, :auto}
defp imgproxy_resize_dimension(:auto), do: {:ok, :auto}
defp imgproxy_resize_dimension({:pixels, 0}), do: {:ok, :auto}
defp imgproxy_resize_dimension({:pixels, value}) when value > 0, do: {:ok, {:px, value}}
defp imgproxy_resize_dimension({:scale, value}), do: decimal_ratio(value)

defp imgproxy_crop_dimension(:auto), do: {:ok, :full_axis}
defp imgproxy_crop_dimension({:pixels, 0}), do: {:ok, :full_axis}
defp imgproxy_crop_dimension({:pixels, value}) when value > 0, do: {:ok, {:px, value}}
defp imgproxy_crop_dimension({:scale, value}), do: decimal_ratio(value)
```

Do not globally map `0`, `nil`, or `:auto` through one helper; resize and crop semantics differ.

Guides should be simple values such as `:center`, `:top_left`, or `{:fp, ratio_x, ratio_y}`. Do not add gravity/focus structs.

Canvas dimension helpers must reject zero dimensions or preserve current imgproxy validation behavior; they must not pass `{:px, 0}` into Plan constructors.

Prefer exact decimal-string-to-rational conversion when the raw token is available. If the current parser has already converted scale input to float, use a named helper such as `decimal_ratio/1` that reduces to `{:ratio, numerator, denominator}` and documents the compatibility rounding policy.

- [ ] **Step 5: Replace canvas and orientation construction**

Map:

- extend/extend-aspect-ratio -> `Operation.canvas/4`
- auto-orient -> `%ImagePlug.Transform.Operation.AutoOrient{}`
- rotate -> `%ImagePlug.Transform.Operation.Rotate{}`
- flip -> `%ImagePlug.Transform.Operation.Flip{}`

The orientation primitives are the only executable transform operations allowed directly in Plan pipelines.

- [ ] **Step 6: Run parser tests**

Run:

```bash
mise exec -- mix format lib/image_plug/parser/imgproxy/plan_builder.ex test/parser/imgproxy/plan_builder_test.exs test/parser/imgproxy_test.exs
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs
```

Expected: parser tests pass with simplified Plan operations.

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
- `ImagePlug.Transform.Operation.*` modules are executable targets for local backend work.
- `Resize` with `mode: :auto` is semantic Plan intent; existing `AdaptiveResize` is an executable compatibility target only during migration and should not be emitted by parsers.

- [ ] **Step 2: Update executable operation moduledocs**

In existing executable operation files, remove statements that say Native/Imgproxy parser directly emits them. Replace with wording like:

```elixir
Transform Plan execution may convert semantic Plan operations to this executable operation.
Parser modules should construct ImagePlug.Plan.Operation.* through Plan constructors.
```

- [ ] **Step 3: Tighten architecture boundary tests**

Update `test/image_plug/architecture_boundary_test.exs`:

- Runtime must not alias, import, construct, or pattern match on concrete `ImagePlug.Plan.Operation.*` modules.
- Runtime must not alias, import, construct, or pattern match on concrete `ImagePlug.Transform.Operation.*` modules.
- Parser-specific structs under `ImagePlug.Parser.Imgproxy.*` must not appear in runtime.
- Cache key construction must not reference `ImagePlug.Transform.SourceMetadata`, Plan execution internals, or post-fetch execution helpers.
- `ImagePlug.Parser.Imgproxy` must not reference executable `ImagePlug.Transform.Operation.*` modules after Task 9, except the explicit orientation primitive allowlist: `AutoOrient`, `Rotate`, and `Flip`.

Keep `ImagePlug.Transform.execute_plan/4` internals allowed to reference concrete semantic and executable operation modules. Runtime may pass opaque executable operation values to `Transform.Chain.execute/2` only through generic Transform facades.

Boundary tests should reject concrete module references, construction, and pattern matching in runtime code. They should not reject opaque transport of resolved executable work through generic Transform facades.

- [ ] **Step 4: Remove impossible internal misuse guards if exposed by refactor**

Review `ImagePlug.Transform.operation?/1`, `ensure_operation/1`, and `ensure_operation!/1`. If they now exist only for impossible internal misuse, remove them and the exact tests that assert tidy errors for malformed hand-built structs. Keep `Transform.validate/1`, `metadata/1`, and `execute/2` as trusted behaviour dispatch helpers for executable work.

Do not remove defensive behavior merely because it is untidy if current public-ish tests or runtime boundaries still rely on it. Prefer shrinking unsupported internal API surface when the code path is unreachable after semantic validation.

- [ ] **Step 5: Run boundary and docs-related tests**

Run:

```bash
mise exec -- mix format lib/image_plug/transform.ex lib/image_plug/transform/operation/*.ex test/image_plug/architecture_boundary_test.exs
mise exec -- mix test test/image_plug/architecture_boundary_test.exs test/image_plug/transform/key_data_test.exs test/transform_chain_test.exs
```

Expected: boundary tests enforce the new runtime shape; transform chain tests still pass.

- [ ] **Step 6: Commit boundary cleanup**

Run:

```bash
mise exec -- git add lib/image_plug/transform.ex lib/image_plug/transform/operation docs/transform_operations.md test/image_plug/architecture_boundary_test.exs
mise exec -- git commit -m "refactor: document semantic transform boundary"
```

---

### Task 11: Add Cache, Plan Execution, And Equivalence Regression Tests

**Files:**
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Modify: `test/image_plug/transform/plan_executor_test.exs`
- Modify: `test/image_plug/transform_ir_characterization_test.exs`
- Test: existing parser/runtime tests

- [ ] **Step 1: Add forbidden key mutation regression**

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "post-fetch resize auto branch is not accepted as final output cache key input" do
  key_before =
    build_key!(
      conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
      plan_with_resize_auto(),
      "origin-version-1"
    )

  key_after_resolve =
    build_key!(
      conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
      plan_with_resize_auto(),
      "origin-version-1"
    )

  serialized = ImagePlug.Cache.Key.serialize_key_data(key_before.data)

  assert key_before == key_after_resolve
  assert [[operation_key_data]] = key_before.data[:pipelines]
  assert operation_key_data[:op] == :resize
  assert operation_key_data[:mode] == :auto
  refute Keyword.has_key?(operation_key_data, :selected_branch)
  refute Keyword.has_key?(operation_key_data, :branch)
  refute serialized =~ "resize_auto_branch"
  refute serialized =~ "selected_branch"
  refute Keyword.has_key?(key_before.data, :resolver_key_data)
  refute Keyword.has_key?(key_before.data, :derivations)
end
```

Use a private `plan_with_resize_auto/0` helper in that test file. The assertion proves the cache key data does not include derived branch labels. Prefer structural key data assertions over broad substring checks; use serialization only as a fallback for absence checks when key data shape is opaque.

- [ ] **Step 2: Add ResizeAuto determinism examples**

In `test/image_plug/transform/plan_executor_test.exs`, add table-driven cases:

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

Generate source metadata and semantic operation per case. Assert final visible dimensions and, for cover cases, the expected result-crop behavior if characterization proved it matters.

- [ ] **Step 3: Add source freshness cache tests**

Add tests that show:

- same semantic key data + same source freshness identity -> same key
- same semantic key data + changed source freshness identity -> different key
- changed cachebuster -> different key without changing pipeline key data
- changed transform semantics -> bump `Cache.Key` transform key data version

Use `origin_identity` strings such as `"asset:cat:v1"` and `"asset:cat:v2"` to model strong source freshness data without origin fetch.

- [ ] **Step 4: Add old-vs-new executable equivalence tests**

Extend `test/image_plug/transform_ir_characterization_test.exs` to compare simplified Plan execution to the old executable operations for representative requests:

- `fit 300x200`
- `fill 100x100 center`
- `auto landscape target`
- `force width auto`
- explicit crop center `50x50`
- canvas extend to `320x240`

For each case:

1. Execute old executable operations against a generated image.
2. Execute the matching simplified Plan against the same generated image.
3. Assert final dimensions match.

- [ ] **Step 5: Add parser and cache boundary regressions**

Add focused regressions that prove:

- After Task 9, parsed plans contain no `ImagePlug.Transform.Operation.*` structs except the explicit orientation primitive allowlist: `AutoOrient`, `Rotate`, and `Flip`.
- A semantic `ResizeAuto` cache hit returns without origin fetch, metadata read, decode/open, or Plan execution.
- Cache key construction does not call `Transform.execute_plan/4`.
- Runtime does not perform a second lookup after Plan execution.

- [ ] **Step 6: Run regression suite**

Run:

```bash
mise exec -- mix format test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/transform/plan_executor_test.exs test/image_plug/transform_ir_characterization_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/transform/plan_executor_test.exs test/image_plug/transform_ir_characterization_test.exs
```

Expected: cache key data remains semantic and source-fetch-free; simplified Plan execution preserves current executable results for the first-slice examples.

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
- Final cache lookup is source-fetch-free and uses semantic key data.
- `ResizeAuto` is cache-keyed as semantic intent; selected fit/cover branch is source-aware execution state.

- [ ] **Step 2: Search for stale Native parser references**

Run:

```bash
rg "Parser.Native|ImagePlug.Parser.Native|Native Path API|native_path_api|native parser|Native parser" lib test docs README.md mix.exs
```

Expected: no stale references, except historical wording in the approved design spec if intentionally retained.

Also check for stale key-data naming:

```bash
rg "Transform.Material|serialize_material|material" lib test docs README.md mix.exs
```

Expected: no stale code references to `Transform.Material` or `serialize_material`; remaining `material` hits should be unrelated English prose or explicit migration notes.

- [ ] **Step 3: Run focused verification**

Run:

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_plug/transform/plan_executor_test.exs test/image_plug/cache/key_test.exs test/image_plug/runtime/request_runner_test.exs test/image_plug/request_safety_test.exs test/image_plug/architecture_boundary_test.exs
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
- Ordered Plan execution: Tasks 5, 6, and 8.
- Final output cache lookup source-fetch-free: Tasks 7 and 11.
- Runtime generic boundary: Tasks 8 and 10.
- No first-slice capability framework or strategy execution: File Structure, Task 3, Task 5, and Task 10 explicitly avoid them.
- Vendor fixtures before IR expansion: Task 3.
- Vertical operation slices: Tasks 4, 5, 6, 9, and 11 require constructor/key-data/execution/cache tests.

Placeholder scan:

- The plan contains no unbounded implementation steps.
- Each task has exact files, commands, and expected test outcomes.
- Deferred future behavior is explicitly excluded from the first slice instead of described as implementation work.

Type consistency:

- Semantic operations live under `ImagePlug.Plan.Operation.*`.
- Source metadata and Plan execution live under `ImagePlug.Transform.*`.
- Parser namespace is consistently `ImagePlug.Parser.Imgproxy` after Task 2.
- First-slice execution has no selections, derivations, resolved plans, or resolver key data.
