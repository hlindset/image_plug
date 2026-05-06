# Transform Documentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-facing Native path API docs, contributor-facing transform operation docs, and ExDoc module docs that match the current imgproxy Native implementation after `5b9eeff`.

**Architecture:** Keep user-facing URL grammar in `docs/native_path_api.md`, parser/dialect mapping guidance in `docs/transform_operations.md`, and field-level transform contracts in module `@moduledoc`. Add docs to ExDoc extras and verify examples against parser, planner, and transform tests so URL grammar and operation contracts do not drift.

**Tech Stack:** Elixir, ExDoc, ExUnit, StreamData, Boundary, `mise exec -- ...` for repo commands.

---

## Implementation Protocol

Use this plan in the existing `imgproxy-native-processing-options` branch and worktree. Do not create a new branch for the documentation implementation.

For each task:

1. Dispatch a fresh implementer subagent for only that task.
2. Have the implementer update that task's checkboxes as steps are completed.
3. After the implementer finishes, run a spec compliance reviewer subagent. The reviewer must compare the task diff against `docs/superpowers/specs/2026-05-06-transform-documentation-design.md`, `AGENTS.md`, and the current parser/planner tests.
4. Fix all Critical, Important, and spec-compliance findings before continuing.
5. Run a code quality reviewer subagent after spec issues are fixed. The reviewer must check clarity, doc accuracy, examples, ExDoc links, test duplication, and whether docs accidentally imply runtime depends on concrete transform modules.
6. Fix all Critical and Important code-quality findings before moving to the next task.
7. Run the focused command listed in the task. Use `mise exec -- ...` exactly.
8. Commit the task before starting the next task.

Tasks 4, 5, and 6 are module-documentation tasks and may run implementer subagents in parallel. Maximum concurrency is 2 implementers at a time. Parallel implementers must have disjoint file ownership exactly as listed in each task's parallel batches, and each implementer must know that other agents may be editing different files in the same worktree. After Batch A and Batch B finish, run the spec compliance reviewer over the combined task diff, fix all Critical, Important, and spec-compliance findings, run the code quality reviewer, fix all Critical and Important findings, then run the task's focused command with `mise exec -- ...`. If any reviewer fix happens after the focused command, rerun the focused command before committing.

Do not open a PR from this documentation plan until all tasks and final verification pass.

---

## File Map

- Create: `docs/native_path_api.md`
  - User-facing reference for Native URLs and current imgproxy-compatible option names.
  - Owns URL grammar, aliases, accepted values, rejection behavior, and examples.
- Create: `docs/transform_operations.md`
  - Contributor guide for parser/dialect authors translating external syntax into `ImagePlug.Plan`.
  - Owns operation-choice guidance and product-neutral mapping examples.
- Modify: `README.md`
  - Keep concise; link to the two new guides.
- Modify: `mix.exs`
  - Add both guide files to ExDoc `extras`.
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/transform/chain.ex`
- Modify: `lib/image_plug/transform/decode_planner.ex`
- Modify: `lib/image_plug/transform/materializer.ex`
- Modify: `lib/image_plug/transform/state.ex`
- Modify: `lib/image_plug/transform/material.ex`
- Modify: `lib/image_plug/transform/geometry/dimension_rule.ex`
- Modify: `lib/image_plug/transform/geometry/dimension_resolver.ex`
- Modify: `lib/image_plug/transform/geometry/crop_coordinate_mapper.ex`
  - Shared transform contract docs.
- Modify: `lib/image_plug/transform/resize.ex`
- Modify: `lib/image_plug/transform/adaptive_resize.ex`
- Modify: `lib/image_plug/transform/extend_canvas.ex`
- Modify: `lib/image_plug/transform/auto_orient.ex`
- Modify: `lib/image_plug/transform/rotate.ex`
- Modify: `lib/image_plug/transform/flip.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `lib/image_plug/transform/contain.ex`
- Modify: `lib/image_plug/transform/cover.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/focus.ex`
  - Per-operation module docs.
- Modify: `test/parser/native_test.exs`
- Modify: `test/parser/native/plan_builder_test.exs`
- Modify: `test/image_plug/transform/material_test.exs`
  - Documentation example coverage.

---

### Task 1: Wire New Guides Into ExDoc And README

**Files:**
- Create: `docs/native_path_api.md`
- Create: `docs/transform_operations.md`
- Modify: `README.md`
- Modify: `mix.exs`

- [x] **Step 1: Create guide scaffolds**

Create `docs/native_path_api.md` with this top-level structure:

```markdown
# Native Path API

## Mental Model

## URL Shape

## Pipeline Groups

## Option Ordering And Conflict Resolution

## Resize And Dimensions

## Crop And Gravity

## Orientation

## Canvas Extension

## Output Format And Quality

## Cache And Expiration

## Response Filename And Disposition

## Unsupported And Rejected Options

## Examples
```

Create `docs/transform_operations.md` with this top-level structure:

```markdown
# Transform Operations

## Purpose

## Request Flow

## Operation Ordering

## Request Fields That Are Not Transform Operations

## Operation Catalog

## Choosing Resize-Like Operations

## Crop, Gravity, And Focus

## Orientation Operations

## Canvas Operations

## Decode Planning

## Cache Material

## Mapping Examples
```

- [x] **Step 2: Update ExDoc extras**

Change `mix.exs` docs config from:

```elixir
docs: [
  main: "ImagePlug",
  extras: ["README.md"]
],
```

to:

```elixir
docs: [
  main: "ImagePlug",
  extras: [
    "README.md",
    "docs/native_path_api.md",
    "docs/transform_operations.md"
  ]
],
```

- [x] **Step 3: Add README links**

In `README.md`, keep the existing Native overview concise and add links near the Native Path API section:

```markdown
For the complete user-facing URL reference, see [Native Path API](docs/native_path_api.md).

For parser and dialect-author guidance on mapping URL concepts to product-neutral transform operations, see [Transform Operations](docs/transform_operations.md).
```

- [x] **Step 4: Run docs generation**

Run:

```bash
mise exec -- mix docs
```

Expected: command exits 0 and generated docs include `Native Path API` and `Transform Operations` entries.

- [x] **Step 5: Commit**

```bash
git add README.md mix.exs docs/native_path_api.md docs/transform_operations.md
git commit -m "docs: add native and transform guide entry points"
```

### Task 2: Document Native Path API User Semantics

**Files:**
- Modify: `docs/native_path_api.md`
- Modify: `test/parser/native_test.exs`
- Modify: `test/parser/native/plan_builder_test.exs`
- Modify: `test/image_plug_test.exs`

- [x] **Step 1: Add Native mental model and URL shape**

Write these statements in `docs/native_path_api.md`:

```markdown
A Native URL describes desired output, not a step-by-step image pipeline.
ImagePlug normalizes aliases, resolves conflicts, builds a product-neutral plan, and executes transforms in Native canonical order.

The general shape is:

    /_/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]

`plain` source paths are path segments after the source marker. A plain source may end in `@extension` to request an explicit output format from the source path. The `@extension` form bypasses `Accept` negotiation like `format`, `f`, and `ext`.
```

- [x] **Step 2: Document pipeline groups and Native order**

Add:

```markdown
`-` separates Native pipeline groups. Non-empty groups execute in URL group order. Inside each group, URL option order still does not define transform order.

Native canonical operation order inside each pipeline group is:

1. orientation (`auto_orient`, `rotate`, `flip`)
2. explicit crop
3. resize or adaptive resize
4. result crop for fill/fill-down/auto target geometry
5. canvas extension

Orientation suborder is auto-orient, rotate, then flip.
```

- [x] **Step 3: Document conflict resolution**

Add:

```markdown
Aliases are normalized before conflict resolution. If multiple URL options map to the same canonical request field, the last occurrence in the URL wins.

Examples:

- `w:100/width:200` resolves width to `200`.
- `width:200/w:100` resolves width to `100`.
- `rt:fit/resizing_type:force` resolves resizing type to `force`.

Pipeline separators scope transform fields to each pipeline group. Global fields such as output format, quality, cachebuster, expiration, filename, and response disposition can appear across groups and still resolve by canonical field.
```

- [x] **Step 4: Document supported options and aliases**

Add a `Supported Options And Aliases` section before the behavior-specific sections. The table must list every currently supported Native option name from `ImagePlug.Parser.Native`, with aliases and accepted value shape:

```markdown
| Concept | Options | Accepted values |
| --- | --- | --- |
| Resize tuple | `resize`, `rs` | `:<resizing_type>:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Size tuple | `size`, `s` | `:<width>:<height>:<enlarge>:<extend>[:<extend_gravity>[:<x_offset>:<y_offset>]]` with trailing arguments optional |
| Resizing type | `resizing_type`, `rt` | `fit`, `fill`, `fill-down`, `force`, `auto` |
| Width | `width`, `w` | non-negative pixel integer; `0` means auto |
| Height | `height`, `h` | non-negative pixel integer; `0` means auto |
| Minimum width | `min-width`, `min_width`, `mw` | non-negative pixel integer |
| Minimum height | `min-height`, `min_height`, `mh` | non-negative pixel integer |
| Enlarge | `enlarge`, `el` | boolean: `1`, `t`, `true`, `0`, `f`, `false` |
| Zoom | `zoom`, `z` | positive number, or positive `x:y` numbers |
| DPR | `dpr` | positive number |
| Extend canvas | `extend`, `ex` | boolean, optionally followed by extend gravity and offsets |
| Extend aspect ratio | `extend_aspect_ratio`, `exar` | positive `<width>:<height>` ratio numbers |
| Crop | `crop`, `c` | `<width>:<height>`, optional gravity, optional offsets |
| Gravity | `gravity`, `g` | anchor, focal point `fp:<x>:<y>`, or unsupported smart gravity `sm` |
| Auto rotate | `auto_rotate`, `ar` | omitted for true, or boolean |
| Rotate | `rotate`, `rot` | integer degrees |
| Flip | `flip`, `fl` | omitted for both axes, one boolean for horizontal, or horizontal and vertical booleans |
| Quality | `quality`, `q` | integer quality; `0` means configured default |
| Format quality | `format_quality`, `fq` | `<format>:<quality>` |
| Format | `format`, `f`, `ext` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; `jpg` normalizes to JPEG |
| Cachebuster | `cachebuster`, `cb` | string value |
| Expires | `expires`, `exp` | Unix timestamp integer |
| Filename | `filename`, `fn` | filename stem, optional encoded flag |
| Attachment disposition | `return_attachment`, `att` | boolean |
| Plain source output extension | source path `@extension` | `webp`, `avif`, `jpeg`, `jpg`, `png`, `best`; `best` is rejected by planning |
```

Document the supported gravity anchors explicitly:

```markdown
Anchor gravity values are `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, and `sowe`.
Resize and size tuple extend-gravity tails accept anchor gravity alone or anchor gravity with `x_offset` and `y_offset`.
```

- [x] **Step 5: Document resize and dimension behavior**

Add accepted Native resize content covering:

```markdown
Supported resizing types are `fit`, `fill`, `fill-down`, `force`, and `auto`.

Zero dimensions map to `auto`. For `force`, an auto side preserves the source dimension. For `fit` and proportional resize rules, an auto side is resolved from source aspect ratio. Min dimensions, zoom, DPR, and `enlarge` are applied by ImagePlug's dimension resolver.

`rt:force/w:0/h:200` preserves source width and forces height to `200`.
`rt:force/w:300/h:0` forces width to `300` and preserves source height.
```

- [x] **Step 6: Document crop, gravity, offsets, and smart gravity rejection**

Add:

```markdown
Crop accepts dimensions and optional crop gravity. If an explicit crop omits gravity, it inherits top-level `g`/`gravity`.

Gravity supports anchors and focal points. Focal point gravity uses `fp:x:y`, where `x` and `y` are normalized coordinates from `0.0` to `1.0`.

Offsets use imgproxy-style parsing:

- `abs(offset) >= 1` means pixels.
- `abs(offset) < 1` means relative scale.

Top-level gravity offsets apply to result crops. Crop-specific offsets apply to explicit crop.
Absolute top-level gravity offsets are resolved by crop execution using the effective DPR. The planner should preserve pixel offsets in the result `Crop`; execution applies the DPR scale.

`g:sm` is intentionally unsupported in this Native slice and is rejected as `{:unsupported_gravity, :sm}`.
```

- [x] **Step 7: Document orientation and canvas behavior**

Add:

```markdown
Orientation options are `auto_rotate`/`ar`, `rotate`/`rot`, and `flip`/`fl`.

- `ar` with no argument enables auto-orient; `ar:false` disables it.
- `rot` accepts integer degrees and normalizes right-angle rotations.
- `fl` with no arguments flips both axes; `fl:true:false` flips horizontally; `fl:false:true` flips vertically; `fl:false:false` emits no flip operation.

Canvas options are `extend`/`ex`, resize-tail extend arguments, and `extend_aspect_ratio`/`exar`.

- `extend:true` requests canvas extension for the requested resize box.
- `extend:false` disables canvas extension even when resize-tail values are present.
- `exar:<width>:<height>` extends canvas to the requested aspect ratio.
- Extend gravity uses anchor values only, with optional numeric offsets.
```

- [x] **Step 8: Document output, quality, cache, and response behavior**

Add:

```markdown
Omitting an explicit output format enables automatic output negotiation.
`format:auto` is not accepted.

Explicit output formats can be requested with `format`, `f`, `ext`, or plain-source `@extension`. Explicit formats and `@extension` bypass `Accept` negotiation and do not set `Vary: Accept`.

When both an option format and source `@extension` are present, document the current precedence: source `@extension` overrides any explicit format option.

Supported explicit output extensions are `webp`, `avif`, `jpeg`, `jpg`, `png`, and `best`. `jpg` normalizes to JPEG. `best` parses but is rejected by planning in this Native slice.

`quality`/`q` set generic output quality. `format_quality`/`fq` set quality for one explicit format and should be documented separately from generic quality. `0` resets quality to the configured default.

`cachebuster`/`cb` changes cache key material without adding transform operations. `expires`/`exp` is a Unix timestamp request validity policy. `filename`/`fn` sets the delivery filename stem; `return_attachment`/`att` controls inline versus attachment `Content-Disposition`.
```

- [x] **Step 9: Document rejection table**

Add:

```markdown
| Case | Behavior |
| --- | --- |
| Unknown option | HTTP 400 before origin fetch/cache lookup |
| Known imgproxy option outside this Native slice | HTTP 400 before origin fetch/cache lookup |
| Supported option with invalid value | HTTP 400 before origin fetch/cache lookup |
| Valid syntax with unsupported combined semantics | HTTP 400 before origin fetch/cache lookup |
| Duplicate canonical field | Last value wins |

Unsupported examples include `raw`, `max_bytes`, `max_src_resolution`, `max_src_file_size`, `crop_aspect_ratio`, `format:auto`, `g:sm`, and `c:<width>:<height>:sm`.
```

- [x] **Step 10: Add common URL examples**

Add examples for these user-facing URL patterns:

```markdown
| Goal | Native URL |
| --- | --- |
| Fit within a width | `/_/w:300/plain/images/cat.jpg` |
| Fill a box from a focal point | `/_/rt:fill/w:300/h:200/g:fp:0.25:0.75/plain/images/cat.jpg` |
| Force one side and preserve the other | `/_/rt:force/w:0/h:200/plain/images/cat.jpg` |
| Explicit crop with focal gravity | `/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg` |
| Auto-orient then crop | `/_/ar/c:100:100/plain/images/cat.jpg` |
| Explicit output format | `/_/f:webp/plain/images/cat.jpg` |
| Source extension output format | `/_/plain/images/cat.jpg@png` |
```

- [x] **Step 11: Add or verify parser examples**

Add parser test cases only for examples that are not already covered. Use current tests before adding duplicates. Required covered examples:

```elixir
assert {:ok, _plan} = Native.parse(conn(:get, "/_/rt:force/w:0/h:200/plain/images/cat.jpg"), [])
assert {:ok, _plan} = Native.parse(conn(:get, "/_/g:fp:0.25:0.75/rs:fill:300:200/plain/images/cat.jpg"), [])
assert {:ok, _plan} = Native.parse(conn(:get, "/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg"), [])
assert {:ok, _plan} = Native.parse(conn(:get, "/_/ar/c:100:100/plain/images/cat.jpg"), [])
assert {:ok, _plan} = Native.parse(conn(:get, "/_/g:soea:12:-0.25/rs:fill:300:200/plain/images/cat.jpg"), [])

assert Native.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg"), []) ==
         {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}

assert Native.parse(conn(:get, "/_/g:sm/plain/images/cat.jpg"), []) == {:error, {:unsupported_gravity, :sm}}
assert Native.parse(conn(:get, "/_/c:100:100:sm/plain/images/cat.jpg"), []) == {:error, {:unsupported_gravity, :sm}}
```

- [x] **Step 12: Add or verify request-level rejection tests**

Verify or add `ImagePlug.call/2` tests proving parser and planner validation failures return HTTP 400 before origin fetch and before cache lookup. Current examples to keep covered:

```elixir
conn = ImagePlug.call(conn(:get, "/_/w:-1/plain/images/cat-300.jpg"),
  root_url: "http://origin.test",
  parser: ImagePlug.Parser.Native,
  cache: {CacheProbe, message_target: cache_probe},
  origin_req_options: [plug: OriginShouldNotBeCalled]
)

assert conn.status == 400
refute_received {:cache_get, _key}
refute_received :origin_was_called

conn = ImagePlug.call(conn(:get, "/_/g:sm/plain/images/cat-300.jpg"),
  root_url: "http://origin.test",
  parser: ImagePlug.Parser.Native,
  cache: {CacheProbe, message_target: cache_probe},
  origin_req_options: [plug: OriginShouldNotBeCalled]
)

assert conn.status == 400
refute_received {:cache_get, _key}
refute_received :origin_was_called
```

- [x] **Step 13: Run focused Native tests**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug_test.exs
```

Expected: PASS.

- [x] **Step 14: Commit**

```bash
git add docs/native_path_api.md test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/image_plug_test.exs
git commit -m "docs: describe native path api"
```

### Task 3: Document Transform Operations Guide

**Files:**
- Modify: `docs/transform_operations.md`
- Modify: `test/parser/native/plan_builder_test.exs`

- [x] **Step 1: Document request flow and ordering**

Add:

```markdown
Parser syntax is translated into parser-owned request structs, then into `ImagePlug.Plan`, then into ordered transform operation chains.

Native URLs are declarative; Native planner code emits operations in Native canonical order. Other dialects may have order-sensitive semantics. When the ordered semantics map cleanly, emit an ordered `ImagePlug.Plan`; otherwise keep dialect-specific quirks isolated in the parser/adapter layer.
```

- [x] **Step 2: Document non-transform request fields**

Add a section named `Request Fields That Are Not Transform Operations` with:

```markdown
- source path and source identity
- output format and automatic output negotiation
- quality and format-specific quality
- cachebuster
- expires
- filename
- attachment disposition
```

- [x] **Step 3: Document exported operation catalog**

List every exported operation module with one-sentence purpose:

```markdown
- `ImagePlug.Transform.Resize`: planned resize with a known dimension rule mode.
- `ImagePlug.Transform.AdaptiveResize`: runtime-dependent auto resize that chooses fit or fill from source and target orientation.
- `ImagePlug.Transform.Crop`: crop using gravity, offsets, optional orientation context, and optional target rule.
- `ImagePlug.Transform.Focus`: state-only focus operation for future parsers that separate focus from crop.
- `ImagePlug.Transform.ExtendCanvas`: canvas/letterbox expansion.
- `ImagePlug.Transform.AutoOrient`: EXIF-aware auto orientation.
- `ImagePlug.Transform.Rotate`: explicit right-angle rotation.
- `ImagePlug.Transform.Flip`: horizontal, vertical, or both-axis flip.
- `ImagePlug.Transform.Scale`: standalone scale operation.
- `ImagePlug.Transform.Contain`: standalone contain operation.
- `ImagePlug.Transform.Cover`: standalone cover operation.
```

- [x] **Step 4: Document resize-like taxonomy**

Add:

```markdown
Use `Resize` when the resize mode is known at planning time. Use `AdaptiveResize` for Native/imgproxy `auto` behavior, because execution chooses fit or fill after source dimensions are known.

`Scale`, `Contain`, and `Cover` remain exported standalone operations. Do not describe them as implementation details of `Resize`; document when parser authors should emit them directly versus using the newer `Resize` operation.
```

- [x] **Step 5: Document Native mapping examples**

Add mapping examples and ensure they match current planner tests:

```markdown
| Native URL concept | Operation chain |
| --- | --- |
| `w:300` | `Resize` |
| `rt:force/w:0/h:200` | `Resize` with force mode and auto width |
| `rt:auto/w:300/h:200` | `AdaptiveResize`, result `Crop` |
| `rt:fill/w:300/h:200/g:fp:0.25:0.75` | `Resize`, result `Crop` with focal-point gravity |
| `rt:fill/w:300/h:200/g:soea:12:-0.25` | `Resize`, result `Crop` with top-level gravity offsets |
| `c:100:100/g:so` | `Crop` inheriting top-level gravity when crop gravity is omitted |
| `c:100:100:fp:0.25:0.75` | `Crop` with crop-specific focal-point gravity |
| `ar/rot:90/fl:true:false/c:100:100` | `AutoOrient`, `Rotate`, `Flip`, `Crop` |
| `extend:true/w:300/h:200` | `Resize`, `ExtendCanvas` |
```

- [x] **Step 6: Add or verify plan-shape tests**

Verify existing tests cover the mapping examples. Add missing assertions to `test/parser/native/plan_builder_test.exs` only when not already covered.

Required shape assertion for ordering:

```elixir
assert Enum.map(operations, &ImagePlug.Transform.transform_name/1) == [:auto_orient, :rotate, :flip, :crop, :resize]
```

Use the exact current expected order if the test includes only a subset of those operations.

Required parity-sensitive assertions:

```elixir
assert %Transform.Crop{gravity: {:fp, 0.25, 0.75}} = crop
assert %Transform.Crop{x_offset: {:pixels, -12.0}, y_offset: {:scale, 0.25}} = crop
assert %Transform.Resize{rule: %{mode: :force, width: :auto, height: {:pixels, 200}}} = resize
```

- [x] **Step 7: Run focused planner tests**

Run:

```bash
mise exec -- mix test test/parser/native/plan_builder_test.exs
```

Expected: PASS.

- [x] **Step 8: Commit**

```bash
git add docs/transform_operations.md test/parser/native/plan_builder_test.exs
git commit -m "docs: explain transform operation mapping"
```

### Task 4: Add Shared Transform Contract Module Docs

**Files:**
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/transform/chain.ex`
- Modify: `lib/image_plug/transform/decode_planner.ex`
- Modify: `lib/image_plug/transform/materializer.ex`
- Modify: `lib/image_plug/transform/state.ex`
- Modify: `lib/image_plug/transform/material.ex`
- Modify: `lib/image_plug/transform/geometry/dimension_rule.ex`
- Modify: `lib/image_plug/transform/geometry/dimension_resolver.ex`
- Modify: `lib/image_plug/transform/geometry/crop_coordinate_mapper.ex`

- [x] **Step 1: Dispatch parallel implementers for shared contracts**

Use up to 2 implementer subagents in parallel.

Batch A owns these files:

- `lib/image_plug/transform.ex`
- `lib/image_plug/transform/chain.ex`
- `lib/image_plug/transform/decode_planner.ex`
- `lib/image_plug/transform/materializer.ex`
- `lib/image_plug/transform/state.ex`
- `lib/image_plug/transform/material.ex`

Batch B owns these files:

- `lib/image_plug/transform/geometry/dimension_rule.ex`
- `lib/image_plug/transform/geometry/dimension_resolver.ex`
- `lib/image_plug/transform/geometry/crop_coordinate_mapper.ex`

Tell both implementers:

```text
You are not alone in the codebase. Only edit your assigned files. Do not revert or reformat files owned by the other implementer. Keep docs product-neutral and do not reference parser-specific Native structs from shared transform contracts.
```

- [x] **Step 2: Add or revise shared contract module docs**

For each shared module, write or revise a concise `@moduledoc` with the module's role. Replace `@moduledoc false` only where it is present; do not delete an existing useful moduledoc just to follow the template.

```elixir
@moduledoc """
Shared transform contract used by operation modules and parser/planner code.

This module is product-neutral and must not depend on parser-specific request structs.
"""
```

Adapt the exact wording per module:

- `ImagePlug.Transform`: behaviour callbacks and dispatch facade.
- `ImagePlug.Transform.Chain`: ordered chain execution.
- `ImagePlug.Transform.DecodePlanner`: sequential/random access interpretation and random fallback.
- `ImagePlug.Transform.Materializer`: decode/materialization boundary.
- `ImagePlug.Transform.State`: image, metadata, focus, and error state carried through execution.
- `ImagePlug.Transform.Material`: canonical material protocol for cache keys.
- `DimensionRule`: dimension fields and allowed resize modes.
- `DimensionResolver`: runtime resolution of dimensions, min dimensions, zoom, DPR, and enlarge.
- `CropCoordinateMapper`: semantic-to-physical crop coordinate mapping and rounding.

- [x] **Step 3: Run compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [x] **Step 4: Commit**

```bash
git add lib/image_plug/transform.ex lib/image_plug/transform/chain.ex lib/image_plug/transform/decode_planner.ex lib/image_plug/transform/materializer.ex lib/image_plug/transform/state.ex lib/image_plug/transform/material.ex lib/image_plug/transform/geometry/dimension_rule.ex lib/image_plug/transform/geometry/dimension_resolver.ex lib/image_plug/transform/geometry/crop_coordinate_mapper.ex
git commit -m "docs: document shared transform contracts"
```

### Task 5: Add Core Operation Module Docs

**Files:**
- Modify: `lib/image_plug/transform/resize.ex`
- Modify: `lib/image_plug/transform/adaptive_resize.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/extend_canvas.ex`

- [x] **Step 1: Dispatch parallel implementers for core operation docs**

Use up to 2 implementer subagents in parallel.

Batch A owns these files:

- `lib/image_plug/transform/resize.ex`
- `lib/image_plug/transform/adaptive_resize.ex`

Batch B owns these files:

- `lib/image_plug/transform/crop.ex`
- `lib/image_plug/transform/extend_canvas.ex`

Read-only reference files: `lib/image_plug/transform/material/resize.ex`, `lib/image_plug/transform/material/adaptive_resize.ex`, `lib/image_plug/transform/material/crop.ex`, and `lib/image_plug/transform/material/extend_canvas.ex`. Do not edit material defimpl files in this task.

Tell both implementers:

```text
You are not alone in the codebase. Only edit your assigned files. Do not revert or reformat files owned by the other implementer. Use the shared module-doc template and keep operation docs field-level and product-neutral. Native URL examples are allowed only when explicitly framed as parser translations.
```

- [x] **Step 2: Add required module doc sections to each module**

For each module, add these sections with module-specific content:

- Opening paragraph: one sentence defining the product-neutral operation.
- `## Construct When`: when parser/dialect code should construct this operation.
- `## Struct Contract`: parser/planner code constructs operation structs directly; plan validation rejects malformed operation structs before runtime side effects.
- `## Fields`: required fields, optional fields, accepted values, and links to shared contracts such as `DimensionRule`.
- `## Execution Semantics`: how `execute/2` changes `ImagePlug.Transform.State`.
- `## Decode Planning Metadata`: what `metadata/1` returns and why.
- `## Cache Material`: exact keyword fields emitted by the module's `ImagePlug.Transform.Material` implementation.
- `## Examples`: construction examples using struct literals.

- [x] **Step 3: Document `Resize`**

Cover:

- `DimensionRule` modes `:fit`, `:fill`, `:fill_down`, and `:force`.
- `:auto` dimensions.
- Force zero-dimension behavior after `5b9eeff`.
- Sequential metadata for safe `:fit` and `:force` requests with requested dimensions.
- Exact material fields from `lib/image_plug/transform/material/resize.ex`.

- [x] **Step 4: Document `AdaptiveResize`**

Cover:

- Construct for runtime-dependent auto resize semantics.
- Runtime fit/fill choice from source and target orientation.
- Random decode metadata.
- Delegation to `Resize.execute/2`.
- Exact material fields from `lib/image_plug/transform/material/adaptive_resize.ex`.

- [x] **Step 5: Document `Crop`**

Cover:

- Explicit crop and result crop semantics.
- Gravity, focal-point gravity, crop gravity inheritance from Native planner, and offsets.
- Offset units: pixels versus scale.
- Effective DPR offset scaling during execution after `5b9eeff`.
- Orientation context and crop coordinate mapper behavior.
- Exact material fields from `lib/image_plug/transform/material/crop.ex`.

- [x] **Step 6: Document `ExtendCanvas`**

Cover:

- Dimension canvas extension and aspect-ratio extension.
- Gravity and offsets.
- Random decode metadata.
- Exact material fields from `lib/image_plug/transform/material/extend_canvas.ex`.

- [x] **Step 7: Run focused transform tests**

Run:

```bash
mise exec -- mix test test/image_plug/transform/material_test.exs test/image_plug/transform/dimension_resolver_test.exs test/image_plug/transform/crop_coordinate_mapper_test.exs test/transform_chain_test.exs
```

Expected: PASS.

- [x] **Step 8: Commit**

```bash
git add lib/image_plug/transform/resize.ex lib/image_plug/transform/adaptive_resize.ex lib/image_plug/transform/crop.ex lib/image_plug/transform/extend_canvas.ex
git commit -m "docs: document core transform operations"
```

### Task 6: Add Remaining Operation Module Docs

**Files:**
- Modify: `lib/image_plug/transform/auto_orient.ex`
- Modify: `lib/image_plug/transform/rotate.ex`
- Modify: `lib/image_plug/transform/flip.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `lib/image_plug/transform/contain.ex`
- Modify: `lib/image_plug/transform/cover.ex`
- Modify: `lib/image_plug/transform/focus.ex`

- [x] **Step 1: Dispatch parallel implementers for remaining operation docs**

Use up to 2 implementer subagents in parallel.

Batch A owns these files:

- `lib/image_plug/transform/auto_orient.ex`
- `lib/image_plug/transform/rotate.ex`
- `lib/image_plug/transform/flip.ex`

Batch B owns these files:

- `lib/image_plug/transform/scale.ex`
- `lib/image_plug/transform/contain.ex`
- `lib/image_plug/transform/cover.ex`
- `lib/image_plug/transform/focus.ex`

Read-only reference files: `lib/image_plug/transform/material/auto_orient.ex`, `lib/image_plug/transform/material/rotate.ex`, `lib/image_plug/transform/material/flip.ex`, `lib/image_plug/transform/material/scale.ex`, `lib/image_plug/transform/material/contain.ex`, `lib/image_plug/transform/material/cover.ex`, and `lib/image_plug/transform/material/focus.ex`. Do not edit material defimpl files in this task.

Tell both implementers:

```text
You are not alone in the codebase. Only edit your assigned files. Do not revert or reformat files owned by the other implementer. Preserve the distinction between Native planner behavior and product-neutral transform operation contracts.
```

- [x] **Step 2: Document orientation operations**

For `AutoOrient`, `Rotate`, and `Flip`, document:

- Construct when parser/planner has orientation intent.
- Native suborder: auto-orient, rotate, flip.
- Execution semantics.
- Decode metadata.
- Exact material fields from the corresponding `lib/image_plug/transform/material/*.ex` files.

- [x] **Step 3: Document standalone resize-like operations**

For `Scale`, `Contain`, and `Cover`, document:

- These are exported standalone operations, not implementation details of `Resize`.
- Accepted fields and constraints.
- Sequential/random metadata.
- Execution semantics.
- Exact material fields.
- When a future dialect parser may choose them directly.

- [x] **Step 4: Document `Focus`**

Document:

- `Focus` sets transform state for a later crop.
- Current Native parser does not emit `Focus`; Native focal-point gravity maps to `Crop` gravity.
- Future parsers may emit `Focus` when their dialect has a distinct focus operation.
- Exact material fields from `lib/image_plug/transform/material/focus.ex`.

- [x] **Step 5: Run focused transform tests**

Run:

```bash
mise exec -- mix test test/image_plug/transform/material_test.exs test/transform_chain_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add lib/image_plug/transform/auto_orient.ex lib/image_plug/transform/rotate.ex lib/image_plug/transform/flip.ex lib/image_plug/transform/scale.ex lib/image_plug/transform/contain.ex lib/image_plug/transform/cover.ex lib/image_plug/transform/focus.ex
git commit -m "docs: document remaining transform operations"
```

### Task 7: Final Documentation Verification

**Files:**
- Verify all documentation changes.

- [x] **Step 1: Run formatter**

Run:

```bash
mise exec -- mix format
```

Expected: exits 0. If it changes files, inspect and include formatting-only changes before running the remaining verification commands.

- [x] **Step 2: Run Native/parser focused tests**

Run:

```bash
mise exec -- mix test test/parser/native_test.exs test/parser/native/plan_builder_test.exs test/parser/native_property_test.exs
```

Expected: PASS.

- [x] **Step 3: Run transform focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/transform/material_test.exs test/image_plug/transform/dimension_resolver_test.exs test/image_plug/transform/crop_coordinate_mapper_test.exs test/transform_chain_test.exs test/image_plug/decode_planner_test.exs test/image_plug/sequential_compatibility_test.exs
```

Expected: PASS.

- [x] **Step 4: Run docs generation**

Run:

```bash
mise exec -- mix docs
```

Expected: PASS. Verify generated docs include `Native Path API` and `Transform Operations`.

- [x] **Step 5: Run compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [x] **Step 6: Run full tests**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [x] **Step 7: Run strict lint**

Run:

```bash
mise exec -- mix credo --strict
```

Expected: PASS.

- [x] **Step 8: Commit final verification fixes if needed**

If verification changed files:

```bash
git add README.md mix.exs docs lib test
git commit -m "docs: complete transform documentation verification"
```

If no files changed, do not commit.

---

## Self-Review

**Spec coverage:** Covered. Tasks implement `docs/native_path_api.md`, `docs/transform_operations.md`, ExDoc extras, README links, operation module docs, shared transform contract docs, parser/plan example coverage, ExDoc generation, final verification, and the required per-task implementer/spec-review/code-quality-review loop.

**Parity coverage after `5b9eeff`:** Covered. Native guide tasks include force zero dimensions, crop plus auto-orient support, top-level gravity offsets, crop gravity variants, crop gravity inheritance, imgproxy-style offset parsing, result crop offset/DPR behavior through Crop docs, center rounding via mapper docs, `g:sm` and crop smart-gravity rejection, `format:auto` rejection, `@extension` output syntax, and Native orientation-before-crop order.

**Placeholder scan:** Clean. The only `...` strings are intentional command notation in `mise exec -- ...` and the URL-shape placeholder `option[:arg...]`; no task has missing implementation details. All tasks name exact files, focused commands, expected results, and commit messages.

**Type consistency:** Uses existing modules and current operation names from `ImagePlug.Transform` exports. Test snippets use existing `Native.parse/2`, `conn/2`, `Plan`, `Pipeline`, and `Transform` patterns already present in parser tests.
