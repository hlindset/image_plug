# Imgproxy Native Processing Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Native path API to accept the imgproxy-compatible processing options in the design spec while projecting everything below the parser into product-neutral ImagePlug plan, output, cache, response, policy, and transform concepts.

**Architecture:** Native remains a parser-boundary grammar: URL segments parse into `ImagePlug.Parser.Native.ParsedRequest` facets, and `PlanBuilder` projects those facets into `ImagePlug.Plan` facets before runtime, cache, output, response, and transform code see the request. Runtime validates product-neutral plan shape before source identity, cache lookup, origin fetch, or decode, then dispatches through generic `ImagePlug.Transform` behaviour only.

**Tech Stack:** Elixir, Mix, Plug, NimbleOptions, ExUnit, StreamData, Boundary, Image/Vix, Req.

For all `rg` checks where the expected result is "no matches", an exit code of 1 from `rg` is success.

---

## Current Repo Structure Observed

The relevant current files are:

- Native parser: `lib/image_plug/parser/native.ex`
- Native IR: `lib/image_plug/parser/native/parsed_request.ex`, `lib/image_plug/parser/native/pipeline_request.ex`
- Native planner: `lib/image_plug/parser/native/plan_builder.ex`
- Product-neutral plan: `lib/image_plug/plan.ex`, `lib/image_plug/plan/pipeline.ex`, `lib/image_plug/plan/output.ex`, `lib/image_plug/plan/source/plain.ex`
- Runtime side effects: `lib/image_plug.ex`, `lib/image_plug/runtime/request_runner.ex`, `lib/image_plug/runtime/response_sender.ex`, `lib/image_plug/runtime/response_cache.ex`, `lib/image_plug/runtime/source_identity.ex`, `lib/image_plug/runtime/options.ex`
- Output: `lib/image_plug/output/policy.ex`, `lib/image_plug/output/encoder.ex`, `lib/image_plug/output/format.ex`, `lib/image_plug/output/negotiation.ex`
- Cache key material: `lib/image_plug/cache/key.ex`
- Transform contract and operations: `lib/image_plug/transform.ex`, `lib/image_plug/transform/*.ex`, `lib/image_plug/transform/material/*.ex`
- Boundary tests: `test/image_plug/architecture_boundary_test.exs`
- Parser tests: `test/parser/native_test.exs`, `test/parser/native_property_test.exs`, `test/parser/native/plan_builder_test.exs`
- Runtime/cache/output tests: `test/image_plug/request_runner_test.exs`, `test/image_plug/response_cache_test.exs`, `test/image_plug/cache/key_test.exs`, `test/image_plug/output_policy_test.exs`, `test/image_plug/output_encoder_test.exs`, `test/image_plug/output_negotiation_test.exs`, `test/image_plug_test.exs`
- Geometry/decode/transform tests: `test/image_plug/decode_planner_test.exs`, `test/image_plug/transform/material_test.exs`, `test/transform_chain_test.exs`, `test/image_plug/image_materializer_test.exs`, `test/image_plug/processor_test.exs`
- Existing static fixtures include `priv/static/images/cat-300.jpg`, which is already used by runtime tests.

Existing parser tests call `Native.parse(conn)`. This plan changes the parser behaviour to `parse(conn, opts)` as required by the spec and updates direct tests to call `Native.parse(conn, [])`. A private convenience `parse(conn)` may be kept only if it delegates to `parse(conn, [])`; it must not be part of the behaviour contract.

## Target File Map

Create Native IR facet modules:

- `lib/image_plug/parser/native/output_request.ex`: Native output grammar intent: format, quality, format qualities.
- `lib/image_plug/parser/native/request_policy.ex`: Native request validity intent: expiration.
- `lib/image_plug/parser/native/cache_request.ex`: Native cache key modifiers: cachebuster.
- `lib/image_plug/parser/native/response_request.ex`: Native response delivery metadata: filename and attachment option.
- `lib/image_plug/parser/native/crop_request.ex`: Native pre-resize crop intent, independent from pipeline gravity.

Create product-neutral plan facets:

- `lib/image_plug/plan/policy.ex`: normalized request validity policy.
- `lib/image_plug/plan/cache.ex`: normalized cache key modifiers.
- `lib/image_plug/plan/response.ex`: normalized delivery metadata.
- `lib/image_plug/plan/response/filename.ex`: normalized filename stem plus rendering helpers.
- `lib/image_plug/plan/orientation.ex`: normalized orientation intent.

Create product-neutral output/runtime helpers:

- `lib/image_plug/output/resolved.ex`: resolved format, quality, and representation headers.
- `lib/image_plug/runtime/response_disposition.ex`: content-disposition rendering from `ImagePlug.Plan.Response`.

Create product-neutral transform helpers and operations:

- `lib/image_plug/transform/geometry/dimension_rule.ex`: pre-origin serializable dimension request rule.
- `lib/image_plug/transform/geometry/dimension_resolver.ex`: source-dimension-aware zoom/dpr/min-size resolution.
- `lib/image_plug/transform/geometry/crop_coordinate_mapper.ex`: pure crop/orientation coordinate mapping.
- `lib/image_plug/transform/resize.ex`: neutral resize operation for fit/fill/fill-down/force rules.
- `lib/image_plug/transform/adaptive_resize.ex`: neutral auto resize operation.
- `lib/image_plug/transform/rotate.ex`: neutral explicit rotation operation.
- `lib/image_plug/transform/flip.ex`: neutral explicit flip operation.
- `lib/image_plug/transform/auto_orient.ex`: neutral auto-orientation operation if decode/open options alone are not enough.
- `lib/image_plug/transform/extend_canvas.ex`: neutral canvas extension and aspect-ratio canvas operation.
- Matching material protocol files under `lib/image_plug/transform/material/`.

Modify existing modules:

- `lib/image_plug/parser.ex`: behaviour callback becomes `parse(Plug.Conn.t(), keyword())`.
- `lib/image_plug/parser/native.ex`: refactor parser accumulators, option grammar, option scope, and `parse/2`.
- `lib/image_plug/parser/native/parsed_request.ex`: replace `output_format` with facet fields.
- `lib/image_plug/parser/native/pipeline_request.ex`: add pipeline-only fields for min size, crop, orientation, zoom, dpr, extend-aspect-ratio.
- `lib/image_plug/parser/native/plan_builder.ex`: project Native facets into product-neutral plan facets and operations.
- `lib/image_plug/plan.ex`: include and validate `policy`, `cache`, and `response`.
- `lib/image_plug/plan/output.ex`: include quality and per-format quality intent.
- `lib/image_plug.ex`: pass opts to parser and validate product-neutral plan before `SourceIdentity.resolve/2`.
- `lib/image_plug/cache/key.ex`: include `Plan.Cache`, output quality key material, and dimension-rule material; exclude `Plan.Response`.
- `lib/image_plug/output/policy.ex`: resolve `%ImagePlug.Output.Resolved{}` including quality.
- `lib/image_plug/output/encoder.ex`: encode from `ImagePlug.Output.Resolved`.
- `lib/image_plug/runtime/request_runner.ex`: carry `%ImagePlug.Plan.Response{}` through delivery tuples and resolved output through cache/stream paths.
- `lib/image_plug/runtime/response_cache.ex`: store with resolved output, not a bare format atom.
- `lib/image_plug/runtime/response_sender.ex`: apply `Content-Disposition` on cache hits and misses.
- `lib/image_plug/transform/decode_planner.ex`: keep random access for crop, cover/fill, focus, extend, output-only, unknown transforms, and no-geometry requests; allow sequential only for proven one-pass chains.
- `lib/image_plug/transform.ex`: export new neutral operations and helpers.
- `README.md`: document supported Native/imgproxy-compatible options and declarative ordering.
- `test/image_plug/architecture_boundary_test.exs`: include new concrete transforms in the runtime boundary rule.

## Slice Order

Implement in this order so each slice is reviewable:

1. Plan facets and parser behaviour shape.
2. Native parser accumulators and global-vs-pipeline scope.
3. Output request quality and resolved output carrier.
4. Cache key cachebuster and output key material.
5. Response filename/disposition parsing and pure rendering.
6. Response delivery propagation through cache hits and misses.
7. Expiration policy with injectable `:now` and pre-side-effect validation.
8. Geometry/orientation/min-size/zoom/dpr/extend/fill-down/auto transform semantics.
9. Runtime ordering, decode planning, architecture, and README.

## Implementation Guardrails

- Do not use broad throwaway operation structs to satisfy early tests. If a slice is parser-only, test parser/IR fields directly. If a slice creates product-neutral operations, test their canonical material and runtime dispatch in the same slice.
- Keep `ImagePlug.Plan.Response.filename` nullable at the product-neutral struct level. Starting in Task 5A, Native `PlanBuilder` must always populate it from `fn` or the source-derived default stem before returning a Native plan; before Task 5A, the facet exists but the filename invariant is not complete.
- Explicit filename stems and source-derived filename stems have different extension handling: explicit `fn:cat.jpg` keeps `cat.jpg` as the stem and renders `cat.jpg.webp` when the resolved output is WebP; source-derived defaults strip the source extension and output override suffix, so `/plain/images/cat.jpg` renders `cat.webp`.
- Parser option validation should include arity errors for every option added in this plan. Extra arguments must not be silently accepted or ignored.
- Use structured cache-key material assertions. Avoid `inspect(material) =~ "field"` checks unless the task explicitly says the material format is not available yet.
- Avoid whole-plan equality in property tests once plan facets grow. Compare the invariant fields directly or compare canonical cache key material.
- Before each commit step, run the focused test command for that task and `mise exec -- mix compile --warnings-as-errors`. For broad parser/runtime/output contract changes, also run the affected broader focused suites named in that task before committing.
- Plain `git` commands in commit steps are intentionally not wrapped in `mise exec --`; the `mise exec -- ...` project rule applies to repo toolchain commands such as `mix`, not to Git itself.

## Task 1: Introduce Plan Facets And Parser Callback Shape

**Files:**
- Modify: `lib/image_plug/parser.ex`
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/parsed_request.ex`
- Create: `lib/image_plug/parser/native/output_request.ex`
- Create: `lib/image_plug/parser/native/request_policy.ex`
- Create: `lib/image_plug/parser/native/cache_request.ex`
- Create: `lib/image_plug/parser/native/response_request.ex`
- Modify: `lib/image_plug/plan.ex`
- Create: `lib/image_plug/plan/policy.ex`
- Create: `lib/image_plug/plan/cache.ex`
- Create: `lib/image_plug/plan/response.ex`
- Modify: `lib/image_plug.ex`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/parser/native_test.exs`
- Test: `test/image_plug/request_safety_test.exs`

- [x] **Step 1: Write failing facet projection tests**

Add tests in `test/parser/native/plan_builder_test.exs` that construct the new Native facets directly:

```elixir
test "projects native request facets into product-neutral plan facets" do
  request = %ParsedRequest{
    signature: "_",
    source_kind: :plain,
    source_path: ["images", "cat.jpg"],
    pipelines: [%PipelineRequest{width: {:pixels, 300}}],
    output: %ImagePlug.Parser.Native.OutputRequest{format: :webp},
    policy: %ImagePlug.Parser.Native.RequestPolicy{},
    cache: %ImagePlug.Parser.Native.CacheRequest{cachebuster: "v1"},
    response: %ImagePlug.Parser.Native.ResponseRequest{filename: "cat", disposition: :attachment}
  }

  assert {:ok,
          %Plan{
            output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}},
            policy: %ImagePlug.Plan.Policy{expires: 0},
            cache: %ImagePlug.Plan.Cache{cachebuster: "v1"},
            response: %ImagePlug.Plan.Response{disposition: :attachment}
          }} = PlanBuilder.to_plan(request, now: ~U[2026-05-05 12:00:00Z])
end
```

Update existing direct `ParsedRequest` literals in this file to use:

```elixir
output: %ImagePlug.Parser.Native.OutputRequest{}
```

instead of `output_format: nil`, and use `PlanBuilder.to_plan(request, [])`.

- [x] **Step 2: Write failing parser callback tests**

Update `test/parser/native_test.exs` direct parser calls to use `Native.parse(conn, [])`, then add:

```elixir
test "parse/2 accepts parser options and keeps no-option parse/1 as a delegating helper" do
  conn = conn(:get, "/_/plain/images/cat.jpg")

  assert Native.parse(conn, []) == Native.parse(conn)
end
```

- [x] **Step 3: Write failing pre-source-identity plan validation test**

Create `test/image_plug/request_safety_test.exs`:

```elixir
defmodule ImagePlug.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  defmodule InvalidPlanParser do
    @behaviour ImagePlug.Parser

    def parse(_conn, _opts) do
      {:ok,
       %ImagePlug.Plan{
         source: :invalid_source,
         pipelines: [%ImagePlug.Plan.Pipeline{operations: []}],
         output: %ImagePlug.Plan.Output{mode: :automatic},
         policy: %ImagePlug.Plan.Policy{},
         cache: %ImagePlug.Plan.Cache{},
         response: %ImagePlug.Plan.Response{}
       }}
    end

    def handle_error(conn, {:error, reason}) do
      Plug.Conn.send_resp(conn, 400, inspect(reason))
    end
  end

  test "plug validates product-neutral plan shape before source identity resolution" do
    conn =
      ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        root_url: "http://origin.test"
      )

    assert conn.status == 400
    assert conn.resp_body =~ "unsupported_source"
  end
end
```

- [x] **Step 4: Run focused tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native/plan_builder_test.exs test/parser/native_test.exs test/image_plug/request_safety_test.exs
```

Expected: FAIL with compile errors for missing facet modules, missing plan fields, and `ImagePlug.Parser.parse/2`.

- [x] **Step 5: Implement minimal facet structs and callback shape**

Implement these public shapes:

```elixir
defmodule ImagePlug.Parser.Native.OutputRequest do
  @moduledoc false
  defstruct format: nil, quality: :default, format_qualities: %{}
end

defmodule ImagePlug.Parser.Native.RequestPolicy do
  @moduledoc false
  defstruct expires: 0
end

defmodule ImagePlug.Parser.Native.CacheRequest do
  @moduledoc false
  defstruct cachebuster: nil
end

defmodule ImagePlug.Parser.Native.ResponseRequest do
  @moduledoc false
  defstruct filename: nil, disposition: :default
end
```

```elixir
defmodule ImagePlug.Plan.Policy do
  @moduledoc false
  defstruct expires: 0
end

defmodule ImagePlug.Plan.Cache do
  @moduledoc false
  defstruct cachebuster: nil
end

defmodule ImagePlug.Plan.Response do
  @moduledoc false
  defstruct disposition: :default, filename: nil
end
```

`filename: nil` remains valid for product-neutral non-Native callers. Native source-derived filename projection is intentionally deferred to Task 5A, where `%ImagePlug.Plan.Response.Filename{}` is introduced and Native planning begins always populating `response.filename`.

Change `ImagePlug.Parser` to:

```elixir
@callback parse(Plug.Conn.t(), keyword()) :: {:ok, ImagePlug.Plan.t()} | {:error, term()}
```

Change `ImagePlug.Parser.Native.parse/2` to pass opts into `PlanBuilder.to_plan/2`, and keep:

```elixir
def parse(%Plug.Conn{} = conn), do: parse(conn, [])
```

Change `ImagePlug.call/2` to call `parser.parse(conn, opts)`, validate `Plan.validate_shape/1` before `SourceIdentity.resolve/2`, and route plan validation errors through `parser.handle_error/2`.

Ensure the parser receives the already validated Plug init options returned by `ImagePlug.init/1`. Do not introduce `:now` option validation in this task; Task 6 owns the `:now` schema and expiration clock behavior.

Update the `ImagePlug.Plan` Boundary exports in `lib/image_plug/plan.ex` in this same task to include `Policy`, `Cache`, and `Response`. These modules are part of the product-neutral plan API as soon as they are created; do not defer their exports to the architecture cleanup task.

- [x] **Step 6: Run focused tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native/plan_builder_test.exs test/parser/native_test.exs test/image_plug/request_safety_test.exs
```

Expected: PASS.

- [x] **Step 7: Commit**

```bash
git add lib/image_plug/parser.ex lib/image_plug/parser/native.ex lib/image_plug/parser/native/parsed_request.ex lib/image_plug/parser/native/output_request.ex lib/image_plug/parser/native/request_policy.ex lib/image_plug/parser/native/cache_request.ex lib/image_plug/parser/native/response_request.ex lib/image_plug/plan.ex lib/image_plug/plan/policy.ex lib/image_plug/plan/cache.ex lib/image_plug/plan/response.ex lib/image_plug.ex test/parser/native/plan_builder_test.exs test/parser/native_test.exs test/image_plug/request_safety_test.exs
git commit -m "refactor: add product-neutral plan facets"
```

## Task 2: Refactor Native Parser Scope And Empty Pipeline Canonicalization

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/pipeline_request.ex`
- Modify: `lib/image_plug/parser/native/parsed_request.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/parser/native_property_test.exs`

- [x] **Step 1: Write failing parser scope tests**

Add these examples to `test/parser/native_test.exs`:

```elixir
test "global options may appear before and after pipeline separators" do
  assert_output_mode("/_/f:webp/-/w:100/plain/images/cat.jpg", {:explicit, :webp})
  assert_output_mode("/_/w:100/-/f:webp/plain/images/cat.jpg", {:explicit, :webp})

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
           Native.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

  assert operations == []
end

test "later global assignments win across groups" do
  assert_output_mode("/_/f:webp/-/f:jpeg/plain/images/cat.jpg", {:explicit, :jpeg})
end

test "global-only and empty groups do not become executable pipelines" do
  assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
           Native.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
           Native.parse(conn(:get, "/_/-/w:100/plain/images/cat.jpg"), [])

  assert length(operations) == 1
  assert [%{__struct__: _} = operation] = operations
  assert inspect(operation) =~ "100"
end
```

Update existing tests that currently expect `:empty_pipeline_group` for leading/trailing/repeated separators to the new harmless grouping behavior required by the spec.

- [x] **Step 2: Write failing canonicalization property**

Add to `test/parser/native_property_test.exs`:

```elixir
property "alias-equivalent and order-equivalent dimensions produce the same plan" do
  check all width <- integer(1..2000),
            height <- integer(1..2000) do
    assert {:ok, plan_a} =
             Native.parse(conn(:get, "/_/w:#{width}/h:#{height}/plain/images/cat.jpg"), [])

    assert {:ok, plan_b} =
             Native.parse(conn(:get, "/_/height:#{height}/width:#{width}/plain/images/cat.jpg"), [])

    assert plan_a.pipelines == plan_b.pipelines
    assert plan_a.output == plan_b.output
    assert plan_a.cache == plan_b.cache
  end
end
```

- [x] **Step 3: Run focused parser tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native_property_test.exs
```

Expected: FAIL because global options are still merged through per-pipeline keyword lists and empty groups are rejected.

- [x] **Step 4: Implement accumulator split**

Refactor parser walking into:

```elixir
%{
  current_pipeline: %PipelineRequest{},
  pipelines: [],
  output: %OutputRequest{},
  policy: %RequestPolicy{},
  cache: %CacheRequest{},
  response: %ResponseRequest{}
}
```

Rules:

- Pipeline options update only `current_pipeline`.
- Global options update only request-level facets.
- `"-"` finalizes `current_pipeline` only when it has executable pipeline intent.
- Leading, trailing, repeated, and global-only groups are dropped.
- If no executable groups remain, use one `%PipelineRequest{}` so no-transform requests still have a canonical empty pipeline.
- Source `@extension` is parsed after groups and overwrites `output.format`.

Add a private `pipeline_empty?/1` function based on fields that alter executable image processing. It must ignore output, cache, response, and policy fields.

- [x] **Step 5: Run focused parser tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native_property_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/pipeline_request.ex lib/image_plug/parser/native/parsed_request.ex test/parser/native_test.exs test/parser/native_property_test.exs
git commit -m "refactor: split native global and pipeline option scope"
```

## Task 3: Implement Output Quality And Resolved Output

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/output_request.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Modify: `lib/image_plug/plan/output.ex`
- Create: `lib/image_plug/output/resolved.ex`
- Modify: `lib/image_plug/output.ex`
- Modify: `lib/image_plug/output/policy.ex`
- Modify: `lib/image_plug/output/encoder.ex`
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/response_cache.ex`
- Modify: `lib/image_plug/runtime/response_sender.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/image_plug/output_policy_test.exs`
- Test: `test/image_plug/output_encoder_test.exs`
- Test: `test/image_plug/request_runner_test.exs`
- Test: `test/image_plug/response_cache_test.exs`

- [x] **Step 1: Write failing output parser/planner tests**

Add parser examples:

```elixir
test "parses output quality and format quality as output request fields" do
  assert {:ok,
          %Plan{
            output: %ImagePlug.Plan.Output{
              quality: {:quality, 80},
              format_qualities: %{webp: {:quality, 70}}
            }
          }} = Native.parse(conn(:get, "/_/q:80/fq:webp:70/plain/images/cat.jpg"), [])
end

test "quality zero and format-quality zero normalize to default" do
  assert {:ok,
          %Plan{
            output: %ImagePlug.Plan.Output{
              quality: :default,
              format_qualities: %{webp: :default}
            }
          }} = Native.parse(conn(:get, "/_/q:0/fq:webp:0/plain/images/cat.jpg"), [])
end

test "repeated format quality assignments replace by normalized format" do
  assert {:ok,
          %Plan{output: %ImagePlug.Plan.Output{format_qualities: %{webp: {:quality, 60}}}}} =
           Native.parse(conn(:get, "/_/fq:webp:70/-/fq:webp:60/plain/images/cat.jpg"), [])
end

test "quality later assignment wins across groups" do
  assert {:ok, %Plan{output: %ImagePlug.Plan.Output{quality: {:quality, 70}}}} =
           Native.parse(conn(:get, "/_/q:80/-/q:70/plain/images/cat.jpg"), [])
end
```

Add `PlanBuilder` tests proving output quality does not change `pipelines`.

- [x] **Step 2: Write failing output policy tests**

Add to `test/image_plug/output_policy_test.exs`:

```elixir
test "explicit global quality wins over matching format quality regardless of URL order" do
  plan = %ImagePlug.Plan.Output{
    mode: {:explicit, :webp},
    quality: {:quality, 80},
    format_qualities: %{webp: {:quality, 70}}
  }

  policy = ImagePlug.Output.Policy.from_output_plan(conn(:get, "/image"), plan, [])
  assert ImagePlug.Output.Policy.resolve(policy, :jpeg) ==
           {:ok, %ImagePlug.Output.Resolved{format: :webp, quality: {:quality, 80}, representation_headers: []}}
end

test "format quality supplies default only when global quality is default" do
  plan = %ImagePlug.Plan.Output{
    mode: {:explicit, :webp},
    quality: :default,
    format_qualities: %{webp: {:quality, 70}}
  }

  policy = ImagePlug.Output.Policy.from_output_plan(conn(:get, "/image"), plan, [])
  assert ImagePlug.Output.Policy.resolve(policy, :jpeg) ==
           {:ok, %ImagePlug.Output.Resolved{format: :webp, quality: {:quality, 70}, representation_headers: []}}
end
```

- [x] **Step 3: Run focused output tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs
```

Expected: FAIL because `q`, `fq`, `ImagePlug.Output.Resolved`, and resolved quality do not exist.

- [x] **Step 4: Implement output request and resolved output**

Implement these shapes:

```elixir
defmodule ImagePlug.Plan.Output do
  @moduledoc "Requested output intent before runtime format negotiation."
  @enforce_keys [:mode]
  defstruct mode: :automatic, quality: :default, format_qualities: %{}
end
```

```elixir
defmodule ImagePlug.Output.Resolved do
  @moduledoc false
  @enforce_keys [:format, :quality, :representation_headers]
  defstruct @enforce_keys
end
```

Parser rules:

- `quality`, `q`: exactly one integer argument; `0` means `:default`; `1..100` means `{:quality, value}`; all other values return `{:invalid_option, :quality, value}` or the project-standard tagged equivalent.
- `format_quality`, `fq`: two arguments `format` and quality; normalize `jpg` to `:jpeg`; later assignment replaces the map value for that format.
- `quality` and `format_quality` are separate fields; URL order between them does not change final precedence.
- Add negative arity tests for `q`, `quality`, `fq`, and `format_quality`: missing values and extra arguments must return tagged parser errors.

Policy rules:

- `Policy.from_output_plan/3` keeps the same before-origin selection behavior.
- `Policy.resolve/2` returns `{:ok, %ImagePlug.Output.Resolved{}}`.
- Explicit global quality wins over matching format quality.
- When global quality is `:default`, matching format quality supplies the effective quality.
- Representation headers stay on the resolved value.

Runtime and encoder rules:

- Update the `ImagePlug.Output` Boundary exports in `lib/image_plug/output.ex` in this task to include `Resolved`.
- `ImagePlug.Output.Encoder.memory_output/3` and `limited_memory_output/4` accept `%ImagePlug.Output.Resolved{}`.
- Pass quality to `Image.write/3` / `Image.stream!/2` only when the resolved quality is `{:quality, value}`.
- `RequestRunner`, `ResponseCache`, and `ResponseSender` consume `%ImagePlug.Output.Resolved{}` instead of a bare output format atom, but delivery tuple arity stays unchanged in this task.
- `ResponseCache.store/5` receives the resolved output value and stores `resolved_output.representation_headers`.
- `ResponseSender` derives the response content type and encoder suffix from `resolved_output.format`.
- Do not add `Plan.Response` to runtime delivery tuples in this task; response delivery metadata is added in Task 5B.

- [x] **Step 5: Run focused output tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/output_request.ex lib/image_plug/parser/native/plan_builder.ex lib/image_plug/plan/output.ex lib/image_plug/output.ex lib/image_plug/output/resolved.ex lib/image_plug/output/policy.ex lib/image_plug/output/encoder.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_cache.ex lib/image_plug/runtime/response_sender.ex test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs
git commit -m "feat: resolve output quality at encoding boundary"
```

## Task 4: Implement Cachebuster And Output Cache Key Material

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/cache_request.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Modify: `lib/image_plug/cache/key.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/image_plug/cache/key_test.exs`
- Test: `test/image_plug/cache/key_property_test.exs`

- [x] **Step 1: Write failing cache key tests**

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "cachebuster changes cache keys without changing pipeline material" do
  base_plan = plan()
  busted_plan = plan(cache: %ImagePlug.Plan.Cache{cachebuster: "v2"})

  conn = conn(:get, "/_/plain/images/cat.jpg")
  base = build_key!(conn, base_plan, "https://origin.test/images/cat.jpg")
  busted = build_key!(conn, busted_plan, "https://origin.test/images/cat.jpg")

  assert base.material[:pipelines] == busted.material[:pipelines]
  assert busted.material[:cache] == [cachebuster: "v2"]
  refute base.hash == busted.hash
end

test "response delivery metadata is excluded from cache key material" do
  one = plan(response: %ImagePlug.Plan.Response{disposition: :attachment})
  two = plan(response: %ImagePlug.Plan.Response{disposition: :inline})

  conn = conn(:get, "/_/plain/images/cat.jpg")

  assert build_key!(conn, one, "https://origin.test/images/cat.jpg").hash ==
           build_key!(conn, two, "https://origin.test/images/cat.jpg").hash
end

test "output material includes normalized quality rules" do
  output = %Output{
    mode: :automatic,
    quality: :default,
    format_qualities: %{webp: {:quality, 70}}
  }

  key =
    conn(:get, "/_/plain/images/cat.jpg")
    |> put_req_header("accept", "image/webp")
    |> build_key!(plan(output: output), "https://origin.test/images/cat.jpg")

  assert key.material[:output][:quality] == :default
  assert key.material[:output][:format_qualities] == %{webp: {:quality, 70}}
end
```

Add parser tests for `cachebuster` and `cb`:

```elixir
test "parses cachebuster aliases as cache-only facets" do
  assert {:ok, %Plan{cache: %ImagePlug.Plan.Cache{cachebuster: "abc"}}} =
           Native.parse(conn(:get, "/_/cb:abc/plain/images/cat.jpg"), [])
end

test "cachebuster later assignment wins across groups" do
  assert {:ok, %Plan{cache: %ImagePlug.Plan.Cache{cachebuster: "b"}}} =
           Native.parse(conn(:get, "/_/cb:a/-/cachebuster:b/plain/images/cat.jpg"), [])
end
```

- [x] **Step 2: Run focused cache tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
```

Expected: FAIL because cachebuster is unknown and cache key material has no `:cache` or quality material.

- [x] **Step 3: Implement cache facet material**

Parser rules:

- `cachebuster`, `cb`: exactly one string argument.
- Empty cachebuster is invalid with a stable tagged parser error.
- Later assignment wins across groups.
- Add negative arity tests for `cachebuster` and `cb`: missing values and extra arguments must return tagged parser errors.

Cache key rules:

- Add `cache: [cachebuster: value_or_nil]` to material.
- Add `quality` and `format_qualities` to output material.
- Automatic output still uses normalized modern candidates.
- Explicit output still excludes raw `Accept` unless configured `key_headers` include it.
- Do not include `Plan.Response`.

- [x] **Step 4: Run focused cache tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/cache_request.ex lib/image_plug/parser/native/plan_builder.ex lib/image_plug/cache/key.ex test/parser/native_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
git commit -m "feat: include cachebuster in product-neutral cache keys"
```

## Task 5A: Implement Response Filename Parsing And Pure Rendering

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/response_request.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Modify: `lib/image_plug/plan/response.ex`
- Modify: `lib/image_plug/plan.ex`
- Create: `lib/image_plug/plan/response/filename.ex`
- Create: `lib/image_plug/runtime/response_disposition.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/image_plug/response_disposition_test.exs`

- [x] **Step 1: Write failing filename parser tests**

Add to `test/parser/native_test.exs`:

```elixir
test "parses filename and attachment aliases into response facet" do
  assert {:ok,
          %Plan{
            response: %ImagePlug.Plan.Response{
              disposition: :attachment,
              filename: %ImagePlug.Plan.Response.Filename{stem: "report"}
            }
          }} = Native.parse(conn(:get, "/_/fn:report/att:true/plain/images/cat.jpg"), [])

  assert {:ok, %Plan{response: %ImagePlug.Plan.Response{disposition: :inline}}} =
           Native.parse(conn(:get, "/_/return_attachment:false/plain/images/cat.jpg"), [])
end

test "decodes base64url filenames when encoded flag is truthy" do
  encoded = Base.url_encode64("katt-æøå", padding: false)

  assert {:ok,
          %Plan{
            response: %ImagePlug.Plan.Response{
              filename: %ImagePlug.Plan.Response.Filename{stem: "katt-æøå"}
            }
          }} = Native.parse(conn(:get, "/_/fn:#{encoded}:true/plain/images/cat.jpg"), [])
end

test "rejects invalid filename values before planning succeeds" do
  for path <- [
        "/_/fn:/plain/images/cat.jpg",
        "/_/fn:a%2Fb/plain/images/cat.jpg",
        "/_/fn:a%5Cb/plain/images/cat.jpg",
        "/_/fn:a%0Ab/plain/images/cat.jpg",
        "/_/fn:not-base64:true/plain/images/cat.jpg",
        "/_/fn:#{Base.url_encode64(<<255>>, padding: false)}:true/plain/images/cat.jpg",
        "/_/fn:abcd:true:extra/plain/images/cat.jpg"
      ] do
    assert {:error, _reason} = Native.parse(conn(:get, path), [])
  end
end

test "explicit filename extensions are kept but source-derived extensions are stripped" do
  assert {:ok,
          %Plan{
            response: %ImagePlug.Plan.Response{
              filename: %ImagePlug.Plan.Response.Filename{stem: "cat.jpg"}
            }
          }} = Native.parse(conn(:get, "/_/fn:cat.jpg/plain/images/source.jpg@webp"), [])

  assert {:ok,
          %Plan{
            response: %ImagePlug.Plan.Response{
              filename: %ImagePlug.Plan.Response.Filename{stem: "source"}
            }
          }} = Native.parse(conn(:get, "/_/plain/images/source.jpg@webp"), [])
end

test "filename and attachment later assignments win across groups" do
  assert {:ok,
          %Plan{
            response: %ImagePlug.Plan.Response{
              disposition: :inline,
              filename: %ImagePlug.Plan.Response.Filename{stem: "two"}
            }
          }} =
           Native.parse(conn(:get, "/_/fn:one/att:true/-/filename:two/return_attachment:false/plain/images/source.jpg"), [])
end
```

- [x] **Step 2: Write failing response rendering tests**

Create `test/image_plug/response_disposition_test.exs`:

```elixir
defmodule ImagePlug.Runtime.ResponseDispositionTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Runtime.ResponseDisposition

  test "renders attachment with ASCII filename parameters" do
    response = %Response{disposition: :attachment, filename: %Filename{stem: "report"}}

    assert ResponseDisposition.render(response, "image/webp") ==
             {:ok, ~s(attachment; filename="report.webp"; filename*=UTF-8''report.webp)}
  end

  test "renders deterministic ASCII fallback and UTF-8 filename star" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "katt-æøå"}}

    assert ResponseDisposition.render(response, "image/webp") ==
             {:ok, ~s(inline; filename="katt-___.webp"; filename*=UTF-8''katt-%C3%A6%C3%B8%C3%A5.webp)}
  end

  test "uses download fallback when ASCII fallback becomes empty" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "東京"}}

    assert ResponseDisposition.render(response, "image/png") ==
             {:ok, ~s(inline; filename="download.png"; filename*=UTF-8''%E6%9D%B1%E4%BA%AC.png)}
  end

  test "rejects unsupported cached content type for delivery filename extension" do
    response = %Response{disposition: :inline, filename: %Filename{stem: "report"}}

    assert ResponseDisposition.render(response, "image/gif") ==
             {:error, {:unsupported_delivery_content_type, "image/gif"}}
  end
end
```

- [x] **Step 3: Run focused parser/rendering tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/response_disposition_test.exs
```

Expected: FAIL because response filename structs, parser options, source-derived filename planning, and pure content-disposition rendering do not exist.

- [x] **Step 4: Implement response normalization**

Rules:

- `filename`, `fn`: one or two arguments. The second argument uses Native boolean parsing and defaults to false.
- When encoded flag is truthy, decode first argument with `Base.url_decode64(padding: false)`.
- Reject padded Base64, malformed Base64, decoded invalid UTF-8, empty filename, CR/LF, NUL, control characters, `/`, and `\\`.
- Valid non-ASCII UTF-8 stems are allowed.
- Keep `ImagePlug.Plan.Response.filename` nullable in the struct and shape validator for product-neutral non-Native callers.
- Native planning always sets `Plan.Response.filename`: explicit filename wins; otherwise derive the stem from the source basename with extension removed; if unavailable use `"image"`.
- Source-derived examples: `cat.jpg` -> `cat`, `cat@webp` -> `cat`, empty source basename -> `image`.
- Explicit filename examples: `fn:cat` + WebP -> `cat.webp`; `fn:cat.jpg` + WebP -> `cat.jpg.webp`.
- `return_attachment`, `att`: no value means invalid; truthy -> `:attachment`; falsey -> `:inline`; omitted remains `:default`.
- `:default` resolves to inline in response rendering.
- Header rendering appends resolved output extension and emits both `filename` and `filename*`.
- `ResponseDisposition.render/2` maps `image/jpeg`, `image/png`, `image/webp`, and `image/avif` to `jpg`, `png`, `webp`, and `avif`.
- Unsupported content types return `{:error, {:unsupported_delivery_content_type, content_type}}`.
- Add negative arity tests for `fn`, `filename`, `att`, and `return_attachment`.
- `ResponseDisposition.render/2` must be capable of rendering Native response metadata for every successful image response. Actual runtime emission of the header is wired in Task 5B.
- Update the `ImagePlug.Plan` Boundary exports in `lib/image_plug/plan.ex` in this task to include `Response.Filename`.

- [x] **Step 5: Run focused parser/rendering tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/response_disposition_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/response_request.ex lib/image_plug/parser/native/plan_builder.ex lib/image_plug/plan.ex lib/image_plug/plan/response.ex lib/image_plug/plan/response/filename.ex lib/image_plug/runtime/response_disposition.ex test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/response_disposition_test.exs
git commit -m "feat: parse and render native response disposition"
```

## Task 5B: Propagate Response Delivery Through Runtime And Cache

**Files:**
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/runtime/response_sender.ex`
- Modify: `lib/image_plug/runtime/response_cache.ex`
- Modify: `lib/image_plug/output/encoder.ex`
- Test: `test/image_plug/response_sender_test.exs`
- Test: `test/image_plug/request_runner_test.exs`
- Test: `test/image_plug/response_cache_test.exs`
- Test: `test/image_plug/cache/key_test.exs`

- [x] **Step 1: Write failing runtime delivery tests**

Create `test/image_plug/response_sender_test.exs` with cache-hit sender tests plus one cache-miss image response integration. Keep filename escaping and fallback coverage in the pure `ResponseDisposition` tests from Task 5A:

```elixir
defmodule ImagePlug.Runtime.ResponseSenderTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Runtime.ResponseSender

  test "cache hits apply content disposition from plan response" do
    entry = %Entry{body: "body", content_type: "image/webp", headers: [], created_at: DateTime.utc_now()}
    response = %Response{disposition: :attachment, filename: %Filename{stem: "report"}}

    conn = ResponseSender.send_result(conn(:get, "/image"), {:ok, {:cache_entry, entry, response}}, [])

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="report.webp"; filename*=UTF-8''report.webp)]
  end

  test "image responses apply content disposition on cache misses" do
    {:ok, image} = Image.open("priv/static/images/cat-300.jpg")
    state = %ImagePlug.Transform.State{image: image}
    resolved = %ImagePlug.Output.Resolved{format: :webp, quality: :default, representation_headers: []}
    response = %Response{disposition: :inline, filename: %Filename{stem: "miss"}}

    conn =
      ResponseSender.send_result(
        conn(:get, "/image"),
        {:ok, {:image, state, resolved, response}},
        image_module: Image
      )

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(inline; filename="miss.webp"; filename*=UTF-8''miss.webp)]
  end
end
```

Add integration tests to `test/image_plug/request_runner_test.exs` or `test/image_plug/response_cache_test.exs`:

```elixir
test "cache hits and misses carry plan response delivery metadata" do
  response = %ImagePlug.Plan.Response{
    disposition: :attachment,
    filename: %ImagePlug.Plan.Response.Filename{stem: "carried"}
  }

  assert {:ok, {:image, %State{}, %ImagePlug.Output.Resolved{}, ^response}} =
           RequestRunner.run(
             conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
             plan(response: response),
             "http://origin.test/images/cat-300.jpg",
             origin_req_options: [plug: OriginImage]
           )

  entry = %Entry{
    body: "cached jpeg",
    content_type: "image/jpeg",
    headers: [],
    created_at: DateTime.utc_now()
  }

  assert {:ok, {:cache_entry, ^entry, ^response}} =
           RequestRunner.run(
             conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
             plan(response: response),
             "http://origin.test/images/cat-300.jpg",
             cache: {CacheHit, entry: entry}
           )
end

test "requests differing only by filename share cache key material" do
  one = plan(response: %ImagePlug.Plan.Response{disposition: :attachment, filename: %ImagePlug.Plan.Response.Filename{stem: "one"}})
  two = plan(response: %ImagePlug.Plan.Response{disposition: :inline, filename: %ImagePlug.Plan.Response.Filename{stem: "two"}})

  conn = conn(:get, "/_/plain/images/cat.jpg")

  assert build_key!(conn, one, "https://origin.test/images/cat.jpg").hash ==
           build_key!(conn, two, "https://origin.test/images/cat.jpg").hash
end

test "unsupported cached delivery content type fails open by default and fails closed when configured" do
  invalid_entry = %Entry{
    body: "cached gif",
    content_type: "image/gif",
    headers: [],
    created_at: DateTime.utc_now()
  }

  response = %ImagePlug.Plan.Response{
    disposition: :inline,
    filename: %ImagePlug.Plan.Response.Filename{stem: "report"}
  }

  assert {:ok, {:image, %State{}, %ImagePlug.Output.Resolved{}, ^response}} =
           RequestRunner.run(
             conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
             plan(response: response),
             "http://origin.test/images/cat-300.jpg",
             cache: {CacheHit, entry: invalid_entry},
             origin_req_options: [plug: OriginImage]
           )

  assert {:error, {:cache, {:unsupported_delivery_content_type, "image/gif"}}} =
           RequestRunner.run(
             conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
             plan(response: response),
             "http://origin.test/images/cat-300.jpg",
             cache: {CacheHit, entry: invalid_entry, fail_on_cache_error: true}
           )
end
```

- [x] **Step 2: Run focused runtime delivery tests and verify red**

Run:

```bash
mise exec -- mix test test/image_plug/response_sender_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs
```

Expected: FAIL because runtime delivery tuple arity, response sender, response cache storage, and cache-key exclusion are not wired for `Plan.Response`.

- [x] **Step 3: Carry response through runtime tuples**

Change delivery tuple shapes to:

```elixir
{:cache_entry, %ImagePlug.Cache.Entry{}, %ImagePlug.Plan.Response{}}
{:image, %ImagePlug.Transform.State{}, %ImagePlug.Output.Resolved{}, %ImagePlug.Plan.Response{}}
```

Runtime rules:

- `RequestRunner` attaches `plan.response` on cache hits, cache misses, and uncached image responses.
- `ResponseCache.store/5` stores only `resolved_output.representation_headers`, never `Content-Disposition`.
- `RequestRunner` validates cached `Entry.content_type` before returning a cache hit delivery. Unsupported cached delivery content types fail open as cache misses by default and fail closed with `fail_on_cache_error: true`.
- `ResponseSender` derives the delivery extension from cached `Entry.content_type` for cache hits that already passed runtime validation.
- `ResponseSender` derives the delivery extension from `%ImagePlug.Output.Resolved{}` for image responses.
- `ResponseSender` applies `Content-Disposition` from `Plan.Response` for every successful Native image response, on cache hits and cache misses.
- `ImagePlug.Output.Encoder` and runtime send paths consume `%ImagePlug.Output.Resolved{}` introduced in Task 3.
- `ImagePlug.Cache.Key` excludes `Plan.Response`.

- [x] **Step 4: Run focused runtime delivery tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug/response_sender_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug/runtime/request_runner.ex lib/image_plug/runtime/response_sender.ex lib/image_plug/runtime/response_cache.ex lib/image_plug/output/encoder.ex test/image_plug/response_sender_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs
git commit -m "feat: propagate response delivery through runtime"
```

## Task 6: Implement Expiration Policy Before Side Effects

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/request_policy.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Modify: `lib/image_plug/plan/policy.ex`
- Modify: `lib/image_plug/plan.ex`
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/runtime/options.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/image_plug/request_safety_test.exs`
- Test: `test/image_plug/runtime_options_test.exs`
- Test: `test/image_plug/request_runner_test.exs`

- [x] **Step 1: Write failing expiration parser tests**

Add to `test/parser/native_test.exs`:

```elixir
test "expires rejects expired requests with injectable now" do
  assert Native.parse(conn(:get, "/_/expires:100/plain/images/cat.jpg"), now: 101) ==
           {:error, {:expired_request, 100}}

  assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 100}}} =
           Native.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: 100)

  assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 0}}} =
           Native.parse(conn(:get, "/_/expires:0/plain/images/cat.jpg"), now: 999)
end

test "expires later assignment wins across groups" do
  assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 200}}} =
           Native.parse(conn(:get, "/_/exp:100/-/expires:200/plain/images/cat.jpg"), now: 100)
end

test "now function is called once and normalized once per parse attempt" do
  test_pid = self()

  now = fn ->
    send(test_pid, :now_called)
    100
  end

  assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 100}}} =
           Native.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: now)

  assert_received :now_called
  refute_received :now_called
end

test "expires rejects malformed values and invalid now values" do
  assert Native.parse(conn(:get, "/_/exp:not-int/plain/images/cat.jpg"), now: 100) ==
           {:error, {:invalid_expires, "not-int"}}

  assert Native.parse(conn(:get, "/_/exp:-1/plain/images/cat.jpg"), now: 100) ==
           {:error, {:invalid_expires, "-1"}}

  assert Native.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: :bad) ==
           {:error, {:invalid_now, :bad}}

  assert Native.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: fn -> :bad end) ==
           {:error, {:invalid_now, :bad}}
end
```

- [x] **Step 2: Write failing no-cache/no-origin safety tests**

Add to `test/image_plug/request_safety_test.exs`:

```elixir
defmodule CacheProbe do
  def get(_key, _opts), do: send(self(), :cache_lookup)
  def put(_key, _entry, _opts), do: send(self(), :cache_put)
end

test "expired native requests return before source identity and cache work" do
  conn =
    ImagePlug.call(conn(:get, "/_/exp:100/plain/images/cat.jpg"),
      parser: ImagePlug.Parser.Native,
      root_url: "not-a-valid-origin-url",
      now: 101,
      cache: {CacheProbe, []},
      origin_req_options: [plug: ImagePlug.ProcessorTest.OriginShouldNotFetch]
    )

  assert conn.status == 400
  assert conn.resp_body =~ "expired_request"
  refute_received :cache_lookup
  refute_received :cache_put
end
```

The invalid `root_url` is intentional: if `SourceIdentity.resolve/2` runs, this request will fail for the wrong reason. The origin plug is also intentional: if origin fetch runs, the support plug should raise or fail the test.

Add `test/image_plug/runtime_options_test.exs` coverage that `ImagePlug.Runtime.Options.validate!/1` accepts `:now` as an integer Unix timestamp, `DateTime`, and zero-arity function, and rejects malformed `:now` values before `ImagePlug.call/2` receives opts.

- [x] **Step 3: Run focused policy tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/image_plug/request_safety_test.exs test/image_plug/runtime_options_test.exs test/image_plug/request_runner_test.exs
```

Expected: FAIL because `expires` is unknown and `:now` is not normalized.

- [x] **Step 4: Implement expiration parsing and validation**

Rules:

- `expires`, `exp`: exactly one base-10 integer argument.
- Negative and non-integer values return `{:invalid_expires, value}`.
- `0` means no expiration.
- Add negative arity tests for `expires` and `exp`: missing values and extra arguments must return tagged parser errors.
- `:now` may be a `DateTime`, an integer Unix timestamp, or a zero-arity function returning either.
- If `:now` is a function, call it once per parse/planning attempt.
- Invalid `:now` returns `{:invalid_now, value}`.
- Normalize both values to Unix seconds.
- Expired when `expires > 0 and expires < now_unix_seconds`; equality is valid.
- Expiration must fail from `Native.parse(conn, opts)` before returning a plan.
- `Plan.Policy` stores the normalized expires value for product-neutral shape and defense in depth; no response headers are emitted for it.
- `ImagePlug.Runtime.Options` validates `:now` as an optional parser-visible init option so `ImagePlug.call/2` passes validated options to the parser.

- [x] **Step 5: Run focused policy tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/image_plug/request_safety_test.exs test/image_plug/runtime_options_test.exs test/image_plug/request_runner_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/request_policy.ex lib/image_plug/parser/native/plan_builder.ex lib/image_plug/plan/policy.ex lib/image_plug/plan.ex lib/image_plug.ex lib/image_plug/runtime/options.ex test/parser/native_test.exs test/image_plug/request_safety_test.exs test/image_plug/runtime_options_test.exs test/image_plug/request_runner_test.exs
git commit -m "feat: reject expired native requests before side effects"
```

## Task 7: Add Pipeline IR For Geometry, Crop, Orientation, Zoom, DPR, And Extend

**Files:**
- Modify: `lib/image_plug/parser/native.ex`
- Modify: `lib/image_plug/parser/native/pipeline_request.ex`
- Create: `lib/image_plug/parser/native/crop_request.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Modify: `lib/image_plug/plan.ex`
- Create: `lib/image_plug/plan/orientation.ex`
- Test: `test/parser/native_test.exs`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/parser/native_property_test.exs`

- [x] **Step 1: Write failing parser tests for new pipeline fields**

Add parser examples against an internal test helper `ImagePlug.Parser.Native.parse_request/2` (`@doc false`) that returns the Native `%ParsedRequest{}` before `PlanBuilder` projection:

```elixir
test "parses min size, zoom, dpr, crop, orientation, and extend-aspect-ratio" do
  assert {:ok, parsed} =
           Native.parse_request(
             conn(:get, "/_/rs:fit:100:0/mw:300/mh:200/z:2:3/dpr:2/c:0.5:0.25:nowe:10:-5/ar:true/rot:-90/fl:true:false/exar:16:9/plain/images/cat.jpg"),
             []
           )

  [pipeline] = parsed.pipelines
  assert pipeline.width == {:pixels, 100}
  assert pipeline.height == {:pixels, 0}
  assert pipeline.min_width == {:pixels, 300}
  assert pipeline.min_height == {:pixels, 200}
  assert pipeline.zoom_x == 2.0
  assert pipeline.zoom_y == 3.0
  assert pipeline.dpr == 2.0
  assert pipeline.crop.width == {:scale, 0.5}
  assert pipeline.crop.height == {:scale, 0.25}
  assert pipeline.crop.gravity == {:anchor, :left, :top}
  assert pipeline.orientation.auto_orient == true
  assert pipeline.orientation.rotate == 270
  assert pipeline.orientation.flip == :horizontal
  assert pipeline.extend_aspect_ratio == {16, 9}
end
```

Add direct `PipelineRequest` assertions in `test/parser/native/plan_builder_test.exs` for:

- crop gravity independent from top-level gravity.
- `rotate` normalizes any integer multiple of 90 to `0 | 90 | 180 | 270`.
- `flip:true:false` normalizes to `:horizontal`.
- one-argument `zoom` sets both axes; two-argument `zoom` sets independent axes.
- invalid dropped options `raw`, `max_bytes`, `mb`, `max_src_resolution`, `msr`, `max_src_file_size`, `msfs`, `crop_aspect_ratio`, `crop_ar`, `car` remain parser errors.
- dropped options with values also remain parser errors: `/raw:false`, `/max_bytes:100`, `/mb:100`, and `/crop_ar:1:1`.
- negative arity tests for `zoom`, `z`, `dpr`, `rotate`, `rot`, `flip`, `fl`, `extend_aspect_ratio`, `extend_ar`, `exar`, `crop`, and `c`.

- [x] **Step 2: Run focused parser tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/parser/native_property_test.exs
```

Expected: FAIL because these options are unknown or unsupported planner semantics.

- [x] **Step 3: Implement Native pipeline grammar only**

Parser rules:

- `min-width`, `mw`, `min-height`, `mh`: non-negative pixel dimensions where `0` is allowed only if the existing dimension semantics allow it; invalid negative values return tagged parser errors.
- `zoom`, `z`: one or two positive floats; one argument sets both axes.
- `dpr`: positive float.
- `enlarge`, `el`: boolean.
- `extend`, `ex`: boolean plus existing optional gravity tail.
- `extend_aspect_ratio`, `extend_ar`, `exar`: two positive numeric ratio arguments.
- `gravity`, `g`: keep top-level final/cover gravity fields.
- `crop`, `c`: width, height, optional crop-specific gravity, optional crop-specific x/y offsets. Numeric crop dimension `0` becomes `:auto`; greater than 0 and less than 1 becomes `{:scale, value}`; greater than or equal to 1 becomes `{:pixels, value}`.
- `auto_rotate`, `ar`: optional boolean, default true when present without argument.
- `rotate`, `rot`: integer multiple of 90; normalize modulo 360.
- `flip`, `fl`: optional booleans for horizontal and vertical; absent values default true for imgproxy-compatible grammar where appropriate.
- Boolean parser modes must be explicit per option: `return_attachment` requires a value, while `auto_rotate` may default when present without arguments. Do not make all booleans optional globally.
- Alias matching must be exact: `ar` is `auto_rotate`; `extend_ar` and `exar` are `extend_aspect_ratio` and must not collide with `ar`.
- Unknown and dropped options remain parser errors.
- Update the `ImagePlug.Plan` Boundary exports in `lib/image_plug/plan.ex` in this task to include `Orientation`.

Do not create executable imgproxy transforms or throwaway product-neutral operations in this task. Populate Native IR fields and, where needed for direct `PlanBuilder` tests, product-neutral plan fields such as `%ImagePlug.Plan.Orientation{}` only. Save concrete neutral operation assertions for Tasks 8 through 10.

Public `Native.parse/2` must not silently accept geometry options whose execution and cache material are not implemented yet. Until Tasks 8 through 10 wire executable neutral operations, `PlanBuilder.to_plan/2` should return stable planner errors such as `{:unsupported_pipeline_semantic, :zoom}` for public parse paths that contain not-yet-planned fields. Parser-only coverage for the grammar should use `parse_request/2`.

- [x] **Step 4: Run focused parser tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/parser/native_property_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug/parser/native.ex lib/image_plug/parser/native/pipeline_request.ex lib/image_plug/parser/native/crop_request.ex lib/image_plug/parser/native/plan_builder.ex lib/image_plug/plan.ex lib/image_plug/plan/orientation.ex test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/parser/native_property_test.exs
git commit -m "feat: parse native geometry and orientation intent"
```

## Task 8: Implement Product-Neutral Dimension Resolution

**Files:**
- Create: `lib/image_plug/transform/geometry/dimension_rule.ex`
- Create: `lib/image_plug/transform/geometry/dimension_resolver.ex`
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Test: `test/image_plug/transform/dimension_resolver_test.exs`

- [x] **Step 1: Write failing dimension-resolution tests**

Create `test/image_plug/transform/dimension_resolver_test.exs`:

```elixir
defmodule ImagePlug.Transform.DimensionResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule

  test "min width interacts with fit without zoom" do
    rule = %DimensionRule{mode: :fit, width: {:pixels, 100}, height: :auto, min_width: {:pixels, 300}, enlarge: false}

    assert {:ok, result} = DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)
    assert result.requested_width == 100
    assert result.requested_height == 100
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "zoom scales requested dimensions but not min constraints" do
    rule = %DimensionRule{mode: :fit, width: {:pixels, 100}, height: :auto, min_width: {:pixels, 300}, zoom_x: 2.0, zoom_y: 2.0, enlarge: false}

    assert {:ok, result} = DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)
    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "dpr scales requested dimensions and participates in min-limited scale" do
    rule = %DimensionRule{mode: :fit, width: {:pixels, 100}, height: :auto, min_width: {:pixels, 300}, dpr: 2.0, enlarge: false}

    assert {:ok, result} = DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)
    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 600
    assert result.intermediate_height == 600
  end

  test "effective dpr clamps below requested dpr for small non-vector sources when enlarge is false" do
    rule = %DimensionRule{mode: :fit, width: {:pixels, 500}, height: :auto, dpr: 3.0, enlarge: false}

    assert {:ok, result} = DimensionResolver.resolve(rule, source_width: 800, source_height: 800)
    assert result.effective_dpr < 3.0
    assert result.requested_width <= 800
  end
end
```

- [x] **Step 2: Run dimension tests and verify red**

Run:

```bash
mise exec -- mix test test/image_plug/transform/dimension_resolver_test.exs
```

Expected: FAIL because `DimensionRule` and `DimensionResolver` do not exist.

- [x] **Step 3: Implement rule and resolver**

Implement `DimensionRule` as a product-neutral, pre-origin serializable struct:

```elixir
defstruct mode: :fit,
          width: :auto,
          height: :auto,
          min_width: nil,
          min_height: nil,
          zoom_x: 1.0,
          zoom_y: 1.0,
          dpr: 1.0,
          enlarge: false
```

Implement `DimensionResolver.resolve/2` to return:

```elixir
%{
  requested_width: pos_integer() | :auto,
  requested_height: pos_integer() | :auto,
  intermediate_width: pos_integer(),
  intermediate_height: pos_integer(),
  effective_dpr: float()
}
```

Resolution rules:

- Apply `zoom_x` to requested width and `zoom_y` to requested height.
- Do not apply zoom to `min_width`, `min_height`, crop dimensions, offsets, focal points, cache, response, or output.
- Compute effective dpr before min constraints for non-vector images with `enlarge: false`.
- Apply effective dpr to requested width and height.
- Use min constraints as scale constraints; do not pre-multiply them by raw dpr.
- Normalize transform-bound pixel dimensions to positive integers.
- Use nearest-integer rounding for positive dimension scaling.

Do not add cache key tests in this task: `DimensionRule` is not an executable operation by itself. Cache material coverage belongs to Task 9, where `ImagePlug.Transform.Resize` is introduced as the operation that carries the rule. That material must include requested dpr and the fact that effective dpr is runtime-resolved, not source-specific effective dpr.

Do not weaken the exact 1000x1000 assertions above to `>=` checks. If the exact values are wrong after consulting the local imgproxy reference, update the test expectations and this plan note together with the documented rule; the helper is not implementation-ready until those examples are precise.

Update the `ImagePlug.Transform` Boundary exports in `lib/image_plug/transform.ex` in this task to include `Geometry.DimensionRule` and `Geometry.DimensionResolver` if those modules are referenced from parser/planner, cache material, or tests outside the transform boundary.

- [x] **Step 4: Run dimension tests and verify green**

Run:

```bash
mise exec -- mix test test/image_plug/transform/dimension_resolver_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug/transform/geometry/dimension_rule.ex lib/image_plug/transform/geometry/dimension_resolver.ex lib/image_plug/transform.ex lib/image_plug/parser/native/plan_builder.ex test/image_plug/transform/dimension_resolver_test.exs
git commit -m "feat: add product-neutral dimension resolution rules"
```

## Task 9: Implement Neutral Resize, Adaptive Resize, And Extend Canvas Operations

**Files:**
- Create: `lib/image_plug/transform/resize.ex`
- Create: `lib/image_plug/transform/adaptive_resize.ex`
- Create: `lib/image_plug/transform/extend_canvas.ex`
- Create: `lib/image_plug/transform/material/resize.ex`
- Create: `lib/image_plug/transform/material/adaptive_resize.ex`
- Create: `lib/image_plug/transform/material/extend_canvas.ex`
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/image_plug/transform/material_test.exs`
- Test: `test/transform_chain_test.exs`
- Test: `test/image_plug/cache/key_test.exs`

- [x] **Step 1: Write failing planner operation tests**

Add to `test/parser/native/plan_builder_test.exs`:

```elixir
test "plans fit, fill-down, force, and auto as product-neutral resize operations" do
  assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.Resize{} = resize]}]}} =
           plan_pipeline(resizing_type: :fit, width: {:pixels, 100}, height: {:pixels, 0})

  assert resize.rule.mode == :fit

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.Resize{} = down]}]}} =
           plan_pipeline(resizing_type: :fill_down, width: {:pixels, 100}, height: {:pixels, 100})

  assert down.rule.mode == :fill_down

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.AdaptiveResize{}]}]}} =
           plan_pipeline(resizing_type: :auto, width: {:pixels, 100}, height: {:pixels, 100})
end

test "plans extend and extend aspect ratio as neutral canvas operations" do
  assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
           plan_pipeline(width: {:pixels, 100}, height: {:pixels, 100}, extend: true)

  assert Enum.any?(operations, &match?(%ImagePlug.Transform.ExtendCanvas{}, &1))

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
           plan_pipeline(extend_aspect_ratio: {16, 9})

  assert Enum.any?(operations, &match?(%ImagePlug.Transform.ExtendCanvas{}, &1))
end
```

Add to `test/image_plug/cache/key_test.exs`:

```elixir
test "resize material includes requested zoom and dpr rule inputs" do
  operation = %ImagePlug.Transform.Resize{
    rule: %ImagePlug.Transform.Geometry.DimensionRule{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      zoom_x: 2.0,
      zoom_y: 1.5,
      dpr: 2.0,
      enlarge: false
    }
  }

  key =
    conn(:get, "/_/plain/images/cat.jpg")
    |> build_key!(plan(pipelines: [%Pipeline{operations: [operation]}]), "https://origin.test/images/cat.jpg")

  assert [[resize_material]] = key.material[:pipelines]
  assert resize_material[:op] == :resize
  assert resize_material[:rule][:zoom_x] == 2.0
  assert resize_material[:rule][:zoom_y] == 1.5
  assert resize_material[:rule][:dpr] == 2.0
  assert resize_material[:rule][:effective_dpr] == :runtime_resolved
end
```

- [x] **Step 2: Run focused transform planning tests and verify red**

Run:

```bash
mise exec -- mix test test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs test/transform_chain_test.exs test/image_plug/cache/key_test.exs
```

Expected: FAIL because neutral operations and material implementations are missing.

- [x] **Step 3: Implement neutral operations**

Rules:

- `Resize` carries a `DimensionRule` and executes through `DimensionResolver`.
- `AdaptiveResize` chooses fill/cover behavior when source and target orientation match and fit/contain behavior otherwise; choice depends on source dimensions and requested dimensions, not URL order.
- `ExtendCanvas` represents canvas extension or aspect-ratio canvas expansion, with neutral fields for canvas rule, gravity, x/y offsets, and background behavior.
- Runtime operations receive rule structs or concrete parameters, not parser structs.
- Operation material serializes rule parameters and mode.
- Resize material includes requested `zoom_x`, `zoom_y`, `dpr`, min constraints, and `effective_dpr: :runtime_resolved`; it must not serialize source-specific effective dpr values.
- Metadata for resize-only one-pass-safe operations may be sequential; cover/fill/adaptive/extend operations must be random unless proven safe.
- Update the `ImagePlug.Transform` Boundary exports in `lib/image_plug/transform.ex` in this task to include `Resize`, `AdaptiveResize`, and `ExtendCanvas`.

- [x] **Step 4: Run focused transform planning tests and verify green**

Run:

```bash
mise exec -- mix test test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs test/transform_chain_test.exs test/image_plug/cache/key_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug/transform/resize.ex lib/image_plug/transform/adaptive_resize.ex lib/image_plug/transform/extend_canvas.ex lib/image_plug/transform/material/resize.ex lib/image_plug/transform/material/adaptive_resize.ex lib/image_plug/transform/material/extend_canvas.ex lib/image_plug/transform.ex lib/image_plug/parser/native/plan_builder.ex test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs test/transform_chain_test.exs test/image_plug/cache/key_test.exs
git commit -m "feat: plan neutral resize and canvas operations"
```

## Task 10: Implement Orientation And Crop Coordinate Mapping

**Files:**
- Create: `lib/image_plug/transform/rotate.ex`
- Create: `lib/image_plug/transform/flip.ex`
- Create: `lib/image_plug/transform/auto_orient.ex`
- Create: `lib/image_plug/transform/material/rotate.ex`
- Create: `lib/image_plug/transform/material/flip.ex`
- Create: `lib/image_plug/transform/material/auto_orient.ex`
- Create: `lib/image_plug/transform/geometry/crop_coordinate_mapper.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/material/crop.ex`
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/parser/native/plan_builder.ex`
- Test: `test/image_plug/transform/crop_coordinate_mapper_test.exs`
- Test: `test/parser/native/plan_builder_test.exs`
- Test: `test/image_plug/transform/material_test.exs`

- [x] **Step 1: Write failing pure geometry tests**

Create `test/image_plug/transform/crop_coordinate_mapper_test.exs`:

```elixir
defmodule ImagePlug.Transform.CropCoordinateMapperTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry.CropCoordinateMapper

  test "maps center crop without orientation exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert %{left: 150, top: 125, width: 100, height: 50} = mapped
  end

  test "maps center crop through rotate 90 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 90, flip: :none}
             )

    assert %{left: 175, top: 100, width: 50, height: 100} = mapped
  end

  test "maps center crop through rotate 180 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 180, flip: :none}
             )

    assert %{left: 150, top: 125, width: 100, height: 50} = mapped
  end

  test "maps center crop through rotate 270 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 270, flip: :none}
             )

    assert %{left: 175, top: 100, width: 50, height: 100} = mapped
  end

  test "horizontal flip mirrors anchor and absolute offset" do
    assert {:ok, left} =
             CropCoordinateMapper.map(source_width: 400, source_height: 300, crop_width: {:pixels, 100}, crop_height: {:pixels, 100}, gravity: {:anchor, :left, :center}, x_offset: 10.0, y_offset: 0.0, orientation: %{auto_orient: false, rotate: 0, flip: :horizontal})

    assert {:ok, right} =
             CropCoordinateMapper.map(source_width: 400, source_height: 300, crop_width: {:pixels, 100}, crop_height: {:pixels, 100}, gravity: {:anchor, :right, :center}, x_offset: -10.0, y_offset: 0.0, orientation: %{auto_orient: false, rotate: 0, flip: :none})

    assert left.left == right.left
  end

  test "auto crop dimensions expand to oriented source bounds" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(source_width: 400, source_height: 300, crop_width: :auto, crop_height: {:pixels, 200}, gravity: {:anchor, :center, :center}, x_offset: 0.0, y_offset: 0.0, orientation: %{auto_orient: false, rotate: 0, flip: :none})

    assert mapped.width == 400
    assert mapped.height == 200
  end
end
```

- [x] **Step 2: Write failing planner ordering tests**

Add to `test/parser/native/plan_builder_test.exs`:

```elixir
test "planner emits fixed crop orientation resize order independent of URL order" do
  one = plan_pipeline(crop: %ImagePlug.Parser.Native.CropRequest{width: {:pixels, 100}, height: {:pixels, 100}}, rotate: 90, width: {:pixels, 200})
  two = plan_pipeline(width: {:pixels, 200}, rotate: 90, crop: %ImagePlug.Parser.Native.CropRequest{width: {:pixels, 100}, height: {:pixels, 100}})

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: one_ops}]}} = one
  assert {:ok, %Plan{pipelines: [%Pipeline{operations: two_ops}]}} = two
  assert Enum.map(one_ops, &ImagePlug.Transform.transform_name/1) ==
           Enum.map(two_ops, &ImagePlug.Transform.transform_name/1)
end
```

- [x] **Step 3: Run focused crop/orientation tests and verify red**

Run:

```bash
mise exec -- mix test test/image_plug/transform/crop_coordinate_mapper_test.exs test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs
```

Expected: FAIL because mapper and orientation operations do not exist.

- [x] **Step 4: Implement mapper and neutral orientation operations**

Rules:

- `CropCoordinateMapper` is pure and accepts source dimensions, crop dimensions, semantic gravity, offsets, and product-neutral orientation intent.
- It returns physical `left`, `top`, `width`, and `height` for crop-before-orientation execution.
- It handles rotate 0/90/180/270, horizontal flip, vertical flip, combined rotate+flip, auto dimensions, compass anchors, focal-point gravity if supported, absolute offsets, relative offsets, and negative absolute offsets.
- It uses ties-to-even rounding for positioning values.
- `Transform.Crop` executes crop-before-resize and receives either concrete physical coordinates or a semantic request plus mapper result from runtime dimension resolution.
- `Rotate`, `Flip`, and `AutoOrient` are product-neutral operation modules.
- `PlanBuilder` fixed operation order is crop, auto-orient, rotate, flip, resize/adaptive, cover/fill result crop, extend canvas.
- Operation material includes canonical orientation fields and crop request fields.
- Update the `ImagePlug.Transform` Boundary exports in `lib/image_plug/transform.ex` in this task to include `Rotate`, `Flip`, `AutoOrient`, and `Geometry.CropCoordinateMapper`.

- [x] **Step 5: Run focused crop/orientation tests and verify green**

Run:

```bash
mise exec -- mix test test/image_plug/transform/crop_coordinate_mapper_test.exs test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/transform/rotate.ex lib/image_plug/transform/flip.ex lib/image_plug/transform/auto_orient.ex lib/image_plug/transform/material/rotate.ex lib/image_plug/transform/material/flip.ex lib/image_plug/transform/material/auto_orient.ex lib/image_plug/transform/geometry/crop_coordinate_mapper.ex lib/image_plug/transform/crop.ex lib/image_plug/transform/material/crop.ex lib/image_plug/transform.ex lib/image_plug/parser/native/plan_builder.ex test/image_plug/transform/crop_coordinate_mapper_test.exs test/parser/native/plan_builder_test.exs test/image_plug/transform/material_test.exs
git commit -m "feat: add neutral orientation and crop mapping"
```

## Task 11: Tighten Decode Planning And Safety Regression Coverage

**Files:**
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/runtime/request_runner.ex`
- Modify: `lib/image_plug/transform/decode_planner.ex`
- Modify: `test/support/image_plug/processor_test/origin_should_not_fetch.ex`
- Test: `test/image_plug/request_safety_test.exs`
- Test: `test/image_plug/request_runner_test.exs`
- Test: `test/image_plug/decode_planner_test.exs`
- Test: `test/image_plug/sequential_compatibility_test.exs`

- [x] **Step 1: Add safety regression and decode-planner tests**

Extend `test/image_plug/request_safety_test.exs` with regression tests for the safety behavior introduced in Tasks 1 and 6:

```elixir
test "invalid product-neutral plan fails before source identity and cache lookup" do
  conn =
    ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
      parser: InvalidPlanParser,
      root_url: "http://origin.test",
      cache: {CacheProbe, []}
    )

  assert conn.status == 400
  refute_received :cache_lookup
end

test "parser validation failures return before origin fetch" do
  conn =
    ImagePlug.call(conn(:get, "/_/raw/plain/images/cat.jpg"),
      parser: ImagePlug.Parser.Native,
      root_url: "http://origin.test",
      origin_req_options: [plug: ImagePlug.ProcessorTest.OriginShouldNotFetch]
    )

  assert conn.status == 400
end
```

Extend `test/image_plug/decode_planner_test.exs` with cases asserting random access for crop, cover/fill, focus, extend canvas, output-only empty chains, and unknown metadata.

- [x] **Step 2: Verify safety regressions stay green; decode planner may be red**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
```

Expected: plan-validation safety tests should already PASS if Task 1 was implemented correctly; expiration safety tests should already PASS if Task 6 was implemented correctly. The expected red cases in this task are decode-planner access cases that are still too permissive.

- [x] **Step 3: Implement boundary behavior**

Rules:

- Keep the `ImagePlug.call/2` safety behavior from Tasks 1 and 6 intact: parser/planner/plan-shape failures must return before `SourceIdentity.resolve/2`, cache lookup, origin fetch, or decode.
- `RequestRunner.run/4` keeps its validation as defense in depth for non-Plug callers.
- `DecodePlanner.access/1` returns random access for empty/no-geometry plans, crop, focus, cover/fill/adaptive, extend canvas, unknown transforms, and metadata failures.
- Sequential access is allowed only for transform chains proven one-pass safe, such as simple proportional resize without crop/cover/focus/extend/output-only ambiguity.

- [x] **Step 4: Run focused safety tests and verify green**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add lib/image_plug.ex lib/image_plug/runtime/request_runner.ex lib/image_plug/transform/decode_planner.ex test/support/image_plug/processor_test/origin_should_not_fetch.ex test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
git commit -m "fix: validate client plans before runtime side effects"
```

## Task 12: Add Remaining End-To-End Native Cache And Negotiation Behavior

**Files:**
- Modify: `test/image_plug_test.exs`
- Modify: `test/image_plug/response_cache_test.exs`
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/output_negotiation_test.exs`

- [x] **Step 1: Write failing plug-level cache and negotiation tests**

Add plug-level tests in `test/image_plug_test.exs` or adapter-level tests in `test/image_plug/response_cache_test.exs` that prove:

```elixir
test "cachebuster changes cache key but not transform operations" do
  key_a =
    conn(:get, "/_/cb:a/w:100/plain/images/cat.jpg")
    |> build_key!(plan(cache: %ImagePlug.Plan.Cache{cachebuster: "a"}), "https://origin.test/images/cat.jpg")

  key_b =
    conn(:get, "/_/cb:b/w:100/plain/images/cat.jpg")
    |> build_key!(plan(cache: %ImagePlug.Plan.Cache{cachebuster: "b"}), "https://origin.test/images/cat.jpg")

  assert key_a.material[:pipelines] == key_b.material[:pipelines]
  assert key_a.material[:cache] == [cachebuster: "a"]
  assert key_b.material[:cache] == [cachebuster: "b"]
  refute key_a.hash == key_b.hash
end

test "automatic output normalizes equivalent Accept headers in cache material" do
  automatic_plan = plan(output: %ImagePlug.Plan.Output{mode: :automatic})

  first =
    conn(:get, "/_/plain/images/cat.jpg")
    |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.5")
    |> build_key!(automatic_plan, "https://origin.test/images/cat.jpg")

  second =
    conn(:get, "/_/plain/images/cat.jpg")
    |> put_req_header("accept", "image/avif,image/webp")
    |> build_key!(automatic_plan, "https://origin.test/images/cat.jpg")

  assert first.material[:output][:modern_candidates] == [:avif, :webp]
  assert first.hash == second.hash
end
```

Response delivery cache-hit/cache-miss integration belongs in Task 5B and must already be green before this task starts. Use the existing cache probe patterns from `test/image_plug/request_runner_test.exs` and `test/image_plug/response_cache_test.exs`; do not introduce sleeps.

- [x] **Step 2: Run end-to-end tests and verify red or green**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs test/image_plug/output_negotiation_test.exs
```

Expected: FAIL if any cache key or output negotiation edge is incomplete; PASS if earlier slices already completed these behaviors.

- [x] **Step 3: Implement missing integration fixes**

Fix only integration gaps revealed by these tests:

- Cache key material must not include filename or disposition.
- Cache key material must include cachebuster.
- Automatic output material must include normalized candidate formats and feature flags, not raw Accept.
- Explicit output material must not include normalized Accept candidates.

- [x] **Step 4: Run end-to-end tests and verify green**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs test/image_plug/output_negotiation_test.exs
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add test/image_plug_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs test/image_plug/output_negotiation_test.exs lib/image_plug lib/image_plug.ex
git commit -m "test: cover native response cache integration"
```

## Task 13: Update Architecture Boundaries And Documentation

**Files:**
- Modify: `test/image_plug/architecture_boundary_test.exs`
- Modify: `README.md`
- Test: `test/image_plug/architecture_boundary_test.exs`

- [x] **Step 1: Write failing architecture boundary checks**

Update `@concrete_transform_names` in `test/image_plug/architecture_boundary_test.exs` to include:

```elixir
[:Scale, :Contain, :Cover, :Crop, :Focus, :Resize, :AdaptiveResize, :Rotate, :Flip, :AutoOrient, :ExtendCanvas]
```

Add checks that runtime source does not reference `ImagePlug.Parser.Native` or Native parser structs:

```elixir
test "runtime does not depend on native parser structs" do
  violations =
    for file <- runtime_files(),
        source = File.read!(file),
        source =~ "ImagePlug.Parser.Native" do
      file
    end

  assert violations == []
end
```

Add a broader AST-backed runtime transform boundary check. The current concrete-transform check catches grouped aliases and direct aliases; extend it so any runtime reference whose alias starts with `[:ImagePlug, :Transform, concrete]` is rejected, while `ImagePlug.Transform` itself remains allowed for behaviour dispatch.

- [x] **Step 2: Run boundary tests and verify red or green**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: FAIL if runtime references new concrete transforms or Native structs; PASS if prior slices kept boundaries clean.

- [x] **Step 3: Verify boundary exports and update docs**

Rules:

- `ImagePlug.Transform` exports for new transform modules and geometry helpers should already have been added in the tasks that introduced those modules.
- `ImagePlug.Plan` exports for new plan facets should already have been added in the tasks that introduced those modules.
- Runtime modules use `ImagePlug.Transform` dispatch and `ImagePlug.Plan.*` structs only.
- Runtime modules never name `ImagePlug.Parser.Native.*`.

README updates must state:

- Native URLs are path-oriented and declarative.
- imgproxy-compatible option names are Native grammar only.
- URL option order does not define processing order.
- Later assignments to the same canonical field win.
- `quality`, `format_quality`, `cachebuster`, `expires`, `filename`, and `return_attachment` are not transforms.
- Dropped options in this slice are not accepted.
- Native emits `Content-Disposition` for successful image responses.

- [x] **Step 4: Run boundary and docs-adjacent checks**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
rg -n "ImagePlug.Parser.Native" lib/image_plug/runtime lib/image_plug/cache lib/image_plug/output
rg -n "Transform\\.(Scale|Contain|Cover|Crop|Focus|Resize|AdaptiveResize|Rotate|Flip|AutoOrient|ExtendCanvas)" lib/image_plug/runtime
rg -n "ImagePlug\\.Transform\\.(Scale|Contain|Cover|Crop|Focus|Resize|AdaptiveResize|Rotate|Flip|AutoOrient|ExtendCanvas)" lib/image_plug/runtime
```

Expected:

- `mix test` PASS.
- All `rg` commands produce no matches and exit 1. The AST-backed test is the enforcement source of truth; the `rg` checks are a fast smoke check.

- [x] **Step 5: Commit**

```bash
git add test/image_plug/architecture_boundary_test.exs README.md
git commit -m "docs: describe declarative native processing options"
```

## Task 14: Full Verification

**Files:**
- No planned source edits unless verification exposes a focused defect.

- [x] **Step 1: Run parser and planner focused suite**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native_property_test.exs test/parser/native/plan_builder_test.exs
```

Expected: PASS.

- [x] **Step 2: Run runtime/cache/output focused suite**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_disposition_test.exs test/image_plug/response_sender_test.exs test/image_plug/response_cache_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs test/image_plug/output_policy_test.exs test/image_plug/output_encoder_test.exs test/image_plug/output_negotiation_test.exs
```

Expected: PASS.

- [x] **Step 3: Run transform focused suite**

Run:

```bash
mise exec -- mix test test/image_plug/transform/dimension_resolver_test.exs test/image_plug/transform/crop_coordinate_mapper_test.exs test/image_plug/transform/material_test.exs test/transform_chain_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
```

Expected: PASS.

- [x] **Step 4: Run whole test suite**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [x] **Step 5: Run deterministic seed suite**

Run:

```bash
mise exec -- mix test --seed 0
```

Expected: PASS.

- [x] **Step 6: Run test compilation with warnings as errors**

Run:

```bash
mise exec -- mix test --warnings-as-errors
```

Expected: PASS with no test compilation warnings.

- [x] **Step 7: Run warnings-as-errors compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS with no warnings.

- [x] **Step 8: Run formatter**

Run:

```bash
mise exec -- mix format
```

Expected: command exits 0. If it changes files, inspect `git diff` and include formatting-only changes in the final commit.

- [x] **Step 9: Run strict lint**

Run:

```bash
mise exec -- mix credo --strict
```

Expected: PASS.

- [x] **Step 10: Commit final verification fixes**

If verification required source changes:

```bash
git add lib test README.md
git commit -m "fix: complete native processing option verification"
```

If verification required no changes, record the passing command output in the implementation handoff.

## Self-Review

**Spec coverage:** Covered. Tasks address parser-boundary imgproxy-compatible grammar, ParsedRequest facets, product-neutral Plan facets, output/cache/response/policy behavior, geometry/orientation/min-size/zoom/dpr helpers, request safety before source identity/cache/origin, cache key canonicalization, response headers on hits and misses, and architecture boundaries. Review changes split response parsing/rendering from runtime propagation, moved response/cache integration earlier, removed brittle early assertions against old transform modules, and tightened geometry tests to exact expected values.

**Placeholder scan:** Clean. Each task names exact files, focused tests, focused commands, and expected red/green outcomes.

**Type consistency:** The plan consistently uses `ImagePlug.Parser.Native.OutputRequest`, `RequestPolicy`, `CacheRequest`, `ResponseRequest`, `CropRequest`, `ImagePlug.Plan.Policy`, `Plan.Cache`, `Plan.Response`, `Plan.Response.Filename`, `Plan.Orientation`, `ImagePlug.Output.Resolved`, `ImagePlug.Transform.Geometry.DimensionRule`, `DimensionResolver`, `CropCoordinateMapper`, and the neutral operation modules listed in the target file map.

**Risk notes for implementers:**

- The geometry/orientation slice is the highest-risk section. Keep it isolated and pure-test-heavy before wiring into runtime image operations.
- Existing transform modules may be replaced or heavily reshaped because this is a greenfield library, but runtime code must continue dispatching through `ImagePlug.Transform`.
- Expiration validation belongs to Native parsing/planning and must fail before a successful `ImagePlug.Plan` is returned.
- `Content-Disposition` must not be cached, and filename/disposition must not affect encoded cache keys.
