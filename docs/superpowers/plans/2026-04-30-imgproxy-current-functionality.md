# Imgproxy-Compatible Current Functionality Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ImagePlug's greenfield native request grammar with an imgproxy-compatible first slice covering plain sources, current resize behavior, gravity, explicit output formats, automatic output negotiation, and cache-key behavior.

**Architecture:** Keep imgproxy compatibility at the parser/request-model boundary. Parse imgproxy URL segments into a normalized `ProcessingRequest`, let `PipelinePlanner` validate unsupported semantic combinations before origin fetch, and compile supported intent into the existing transform primitives. Automatic output format selection becomes an explicit selected output before caching encoded responses, so cache keys include the selected output format instead of raw `Accept`.

**Tech Stack:** Elixir, Plug, ExUnit, StreamData, Vix/Image, existing ImagePlug transform modules. Run all commands through `mise exec -- ...` in this repo.

---

## Scope Check

This plan implements the approved first slice only. It does not add signing, base64 sources, encrypted sources, presets, quality controls, metadata controls, filters, watermarks, object detection, `best` output execution, object-oriented gravity, or chained pipeline execution.

The approved spec is:

```text
docs/superpowers/specs/2026-04-30-imgproxy-current-functionality-design.md
```

The source-confirmed imgproxy references are:

```text
/Users/hlindset/src/image_plug/local/imgproxy-master/options/url.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/processing_options.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/resize_type.go
/Users/hlindset/src/image_plug/local/imgproxy-master/options/gravity_options.go
/Users/hlindset/src/image_plug/local/imgproxy-docs-master/versioned_docs/version-4-pre/usage/processing.mdx
```

## Preflight

- [ ] **Step 1: Establish the current baseline**

Run:

```bash
mise exec -- mix test
```

Expected: PASS before implementation starts. If the current baseline fails, stop and record the exact failures before changing code.

- [ ] **Step 2: Verify transform parameter shapes**

Read:

```bash
sed -n '1,140p' lib/image_plug/transform/focus.ex
sed -n '1,150p' lib/image_plug/transform/contain.ex
sed -n '1,150p' lib/image_plug/transform/cover.ex
sed -n '1,130p' lib/image_plug/transform/scale.ex
```

Expected: `Transform.Focus` accepts `{:anchor, x, y}` and coordinate lengths, `Transform.Contain` and `Transform.Cover` accept `constraint: :regular | :min | :max` or `:none`, and `Transform.Scale` accepts `:auto` for one dimension. If these shapes have changed, adapt the planner mapping to the existing transform primitives instead of changing transform modules.

- [ ] **Step 3: Confirm automatic output config does not already exist**

Run:

```bash
rg -n "auto_avif|auto_webp|auto_jxl" lib test config README.md
```

Expected: no existing implementation. If config already exists by the time this plan is executed, use the existing names and defaults instead of adding duplicate option names.

## File Structure

Modify these files:

- `lib/image_plug/processing_request.ex`: Replace old `fit/focus/format:auto` request fields with normalized imgproxy concepts. Keep this module product-neutral.
- `lib/image_plug/param_parser/native.ex`: Replace the old custom grammar with imgproxy-compatible parsing. Keep the module name so existing config stays simple, but the grammar becomes imgproxy-shaped.
- `lib/image_plug/pipeline_planner.ex`: Validate unsupported semantic combinations before origin fetch and map supported imgproxy semantics to existing transform primitives.
- `lib/image_plug/output_negotiation.ex`: Make q-values determine acceptability only; server preference order wins among acceptable candidates.
- `lib/image_plug/cache/key.ex`: Include normalized imgproxy operation fields and selected automatic output format, not raw `Accept`.
- `lib/image_plug/cache.ex`: Allow callers to pass cache-key-only material such as selected automatic output format without passing that material to cache adapters.
- `lib/image_plug.ex`: Select automatic output before cache lookup for automatic requests. Keep explicit output paths cacheable before origin fetch.
- `lib/image_plug/transform_state.ex`: Narrow output type around selected file formats and `:auto` transitional state if needed.
- `README.md`: Replace old custom URL examples with imgproxy-compatible examples and document first-slice behavior.

Modify these tests:

- `test/param_parser/native_test.exs`
- `test/param_parser/native_property_test.exs`
- `test/image_plug/processing_request_test.exs`
- `test/image_plug/pipeline_planner_test.exs`
- `test/image_plug/pipeline_planner_property_test.exs`
- `test/image_plug/output_negotiation_test.exs`
- `test/image_plug/cache/key_test.exs`
- `test/image_plug/cache/key_property_test.exs`
- `test/image_plug_test.exs`

Do not create new transform modules in this slice. The existing primitives are sufficient:

- `ImagePlug.Transform.Scale`
- `ImagePlug.Transform.Contain`
- `ImagePlug.Transform.Cover`
- `ImagePlug.Transform.Focus`
- `ImagePlug.Transform.Output`

## Semantic Mapping

Use these normalized values:

```elixir
resizing_type: :fit | :fill | :fill_down | :force | :auto
format: nil | :webp | :avif | :jpeg | :png | :best
gravity: {:anchor, x, y} | {:fp, x_float, y_float} | :sm
extend_gravity: nil | {:anchor, x, y}
```

Use `nil` for omitted output format. Do not represent omitted format as `:auto` in `ProcessingRequest`; `format:auto` is not an imgproxy format value.

Planner mapping:

```text
resizing_type=nil/default fit + width/height -> Transform.Contain with letterbox=false
resizing_type=fit + width/height             -> Transform.Contain with letterbox=false
resizing_type=fill + width + height          -> optional Transform.Focus, then Transform.Cover
resizing_type=force + width/height           -> Transform.Scale
resizing_type=fill_down                      -> planner error
resizing_type=auto                           -> planner error
format=best                                  -> planner error
gravity=sm                                   -> planner error
extend=true                                  -> planner error
provided extend gravity args                 -> planner error
non-zero crop gravity offsets                -> planner error
```

## Task 1: Normalize `ProcessingRequest`

**Files:**

- Modify: `lib/image_plug/processing_request.ex`
- Modify: `test/image_plug/processing_request_test.exs`
- Modify later in this task only if compile forces it: tests that construct `%ProcessingRequest{}` directly

- [ ] **Step 1: Write the failing request-model tests**

Replace `test/image_plug/processing_request_test.exs` with tests that assert imgproxy-shaped defaults and accepted enum fields:

```elixir
defmodule ImagePlug.ProcessingRequestTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest

  test "defaults to imgproxy-shaped plain request intent" do
    request = %ProcessingRequest{}

    assert request.signature == nil
    assert request.source_kind == nil
    assert request.source_path == []
    assert request.width == nil
    assert request.height == nil
    assert request.resizing_type == :fit
    assert request.enlarge == false
    assert request.extend == false
    assert request.extend_gravity == nil
    assert request.extend_x_offset == nil
    assert request.extend_y_offset == nil
    assert request.gravity == {:anchor, :center, :center}
    assert request.gravity_x_offset == 0.0
    assert request.gravity_y_offset == 0.0
    assert request.format == nil
    assert request.output_extension_from_source == nil
  end

  test "represents unsupported but parsed semantic values distinctly" do
    request = %ProcessingRequest{
      resizing_type: :fill_down,
      gravity: :sm,
      format: :best
    }

    assert request.resizing_type == :fill_down
    assert request.gravity == :sm
    assert request.format == :best
  end
end
```

- [ ] **Step 2: Run the request-model test and verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/processing_request_test.exs
```

Expected: FAIL because `ProcessingRequest` still has old `fit` and `focus` fields and defaults `format` to `:auto`.

- [ ] **Step 3: Replace `ProcessingRequest` fields**

Replace `lib/image_plug/processing_request.ex` with this shape:

```elixir
defmodule ImagePlug.ProcessingRequest do
  @moduledoc """
  Product-neutral representation of a normalized image processing request.
  """

  @type source_kind() :: :plain
  @type resizing_type() :: :fit | :fill | :fill_down | :force | :auto
  @type output_format() :: :webp | :avif | :jpeg | :png | :best
  @type gravity_anchor() ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type gravity() :: gravity_anchor() | {:fp, float(), float()} | :sm

  @type legacy_fit() :: :cover | :contain | :fill | :inside
  @type legacy_focus() ::
          ImagePlug.TransformState.focus_anchor()
          | {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}

  @type t() :: %__MODULE__{
          signature: String.t() | nil,
          source_kind: source_kind() | nil,
          source_path: [String.t()],
          width: ImagePlug.imgp_pixels() | nil,
          height: ImagePlug.imgp_pixels() | nil,
          resizing_type: resizing_type(),
          enlarge: boolean(),
          extend: boolean(),
          extend_gravity: gravity_anchor() | nil,
          extend_x_offset: float() | nil,
          extend_y_offset: float() | nil,
          gravity: gravity(),
          gravity_x_offset: float(),
          gravity_y_offset: float(),
          format: output_format() | nil,
          output_extension_from_source: output_format() | nil,
          fit: legacy_fit() | nil,
          focus: legacy_focus()
        }

  defstruct signature: nil,
            source_kind: nil,
            source_path: [],
            width: nil,
            height: nil,
            resizing_type: :fit,
            enlarge: false,
            extend: false,
            extend_gravity: nil,
            extend_x_offset: nil,
            extend_y_offset: nil,
            gravity: {:anchor, :center, :center},
            gravity_x_offset: 0.0,
            gravity_y_offset: 0.0,
            format: nil,
            output_extension_from_source: nil,
            fit: nil,
            focus: {:anchor, :center, :center}
end
```

The `fit` and `focus` fields are temporary compile shims for modules that are migrated in later tasks. Do not parse new user input into them. Remove them after `PipelinePlanner` and `Cache.Key` no longer reference them.

- [ ] **Step 4: Run the focused test**

Run:

```bash
mise exec -- mix test test/image_plug/processing_request_test.exs
```

Expected: PASS. The temporary `fit` and `focus` fields keep old planner and cache modules compiling until later tasks replace those references.

- [ ] **Step 5: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/processing_request.ex test/image_plug/processing_request_test.exs
mise exec -- git commit -m "feat: normalize imgproxy processing request"
```

## Task 2: Parse Imgproxy URL Structure And Source Extension

**Files:**

- Modify: `test/param_parser/native_test.exs`
- Modify: `lib/image_plug/param_parser/native.ex`

- [ ] **Step 1: Write failing URL boundary tests**

Replace the old plain-source, signature, missing-source, and source-extension tests in `test/param_parser/native_test.exs` with these cases:

```elixir
defmodule ImagePlug.ParamParser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.ParamParser.Native
  alias ImagePlug.ProcessingRequest

  test "parses a plain source with no processing options" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              resizing_type: :fit,
              width: nil,
              height: nil,
              gravity: {:anchor, :center, :center},
              format: nil,
              output_extension_from_source: nil
            }} = Native.parse(conn)
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %ProcessingRequest{signature: "unsafe"}} =
             conn(:get, "/unsafe/plain/images/cat.jpg") |> Native.parse()
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Native.parse(conn(:get, "/signed-value/plain/images/cat.jpg")) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing signature" do
    assert Native.parse(conn(:get, "/")) == {:error, :missing_signature}
  end

  test "rejects missing source kind" do
    assert Native.parse(conn(:get, "/_/w:300")) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    assert Native.parse(conn(:get, "/_/plain")) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "treats option-like segments after plain as source path" do
    assert {:ok, %ProcessingRequest{source_path: ["images", "w:300", "cat.jpg"]}} =
             conn(:get, "/_/plain/images/w:300/cat.jpg") |> Native.parse()
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat@v1.jpg"],
              format: :webp,
              output_extension_from_source: :webp
            }} = conn(:get, "/_/plain/images/cat%40v1.jpg@webp") |> Native.parse()
  end

  test "dangling raw @ leaves output automatic when no explicit format exists" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat.jpg"],
              format: nil,
              output_extension_from_source: nil
            }} = conn(:get, "/_/plain/images/cat.jpg@") |> Native.parse()
  end

  test "rejects multiple raw @ source extension separators" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png")) ==
             {:error, {:multiple_source_format_separators, "images/cat.jpg@webp@png"}}
  end

  test "rejects unknown source extensions as parser errors" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@unknown")) ==
             {:error, {:invalid_format, "unknown", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "parses best source extension for planner rejection" do
    assert {:ok,
            %ProcessingRequest{
              format: :best,
              output_extension_from_source: :best
            }} = conn(:get, "/_/plain/images/cat.jpg@best") |> Native.parse()
  end
end
```

- [ ] **Step 2: Run parser URL tests and verify they fail**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs
```

Expected: FAIL because the parser does not yet split raw `@`, validate source extensions, or populate imgproxy-shaped request fields.

- [ ] **Step 3: Implement source splitting and format parsing helpers**

In `lib/image_plug/param_parser/native.ex`, replace `split_source/1` with raw `@` handling before percent-decoding. Use this helper code:

```elixir
@format_names ~w(webp avif jpeg jpg png best)
@formats %{
  "webp" => :webp,
  "avif" => :avif,
  "jpeg" => :jpeg,
  "jpg" => :jpeg,
  "png" => :png,
  "best" => :best
}

defp split_source(path_info) do
  case Enum.split_while(path_info, &(&1 != "plain")) do
    {_options, []} ->
      {:error, :missing_source_kind}

    {_options, ["plain"]} ->
      {:error, {:missing_source_identifier, "plain"}}

    {options, ["plain" | source_path]} ->
      with {:ok, decoded_source_path, source_format} <- parse_plain_source(source_path) do
        {:ok, options, decoded_source_path, source_format}
      end
  end
end

defp parse_plain_source(source_path) do
  encoded = Enum.join(source_path, "/")

  case String.split(encoded, "@") do
    [""] ->
      {:error, {:missing_source_identifier, "plain"}}

    [source] ->
      decode_source_path(source, nil)

    [source, ""] ->
      decode_source_path(source, nil)

    [source, extension] ->
      with {:ok, format} <- parse_format(extension) do
        decode_source_path(source, format)
      end

    _parts ->
      {:error, {:multiple_source_format_separators, encoded}}
  end
end

defp decode_source_path(source, source_format) do
  decoded =
    source
    |> String.split("/", trim: false)
    |> Enum.map(&URI.decode/1)

  {:ok, decoded, source_format}
end

defp parse_format(value) do
  case Map.fetch(@formats, value) do
    {:ok, parsed_value} -> {:ok, parsed_value}
    :error -> {:error, {:invalid_format, value, @format_names}}
  end
end
```

Then update `parse/1` to merge source format after options:

```elixir
def parse(%Plug.Conn{path_info: [signature | path_info]}) do
  with :ok <- validate_signature(signature),
       {:ok, option_segments, source_path, source_format} <- split_source(path_info),
       {:ok, options} <- parse_options(option_segments) do
    options =
      case source_format do
        nil -> options
        format -> Keyword.put(options, :format, format)
      end

    {:ok,
     struct!(
       ProcessingRequest,
       Keyword.merge(
         [
           signature: signature,
           source_kind: :plain,
           source_path: source_path,
           output_extension_from_source: source_format
         ],
         options
       )
     )}
  end
end
```

- [ ] **Step 4: Keep only URL-boundary tests green**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs
```

Expected: PASS. Task 2 only covers source boundary parsing plus source `@extension`; processing option grammar is introduced in Task 3.

- [ ] **Step 5: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/param_parser/native.ex test/param_parser/native_test.exs
mise exec -- git commit -m "feat: parse imgproxy plain source extensions"
```

## Task 3: Parse Imgproxy Processing Options And Assignment Semantics

**Files:**

- Modify: `test/param_parser/native_test.exs`
- Modify: `test/param_parser/native_property_test.exs`
- Modify: `lib/image_plug/param_parser/native.ex`

- [ ] **Step 1: Add failing option grammar tests**

Add these tests to `test/param_parser/native_test.exs`:

```elixir
test "parses resize and rs full grammar" do
  assert {:ok,
          %ProcessingRequest{
            resizing_type: :fill,
            width: {:pixels, 300},
            height: {:pixels, 200},
            enlarge: true,
            extend: false
          }} = conn(:get, "/_/resize:fill:300:200:1:0/plain/images/cat.jpg") |> Native.parse()

  assert {:ok,
          %ProcessingRequest{
            resizing_type: :force,
            width: {:pixels, 300},
            height: {:pixels, 200}
          }} = conn(:get, "/_/rs:force:300:200/plain/images/cat.jpg") |> Native.parse()
end

test "parses omitted resize arguments with imgproxy defaults" do
  assert {:ok, %ProcessingRequest{resizing_type: :fit, width: {:pixels, 300}, height: nil}} =
           conn(:get, "/_/rs:fit:300/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{resizing_type: :fit, width: {:pixels, 300}, height: {:pixels, 200}}} =
           conn(:get, "/_/rs::300:200/plain/images/cat.jpg") |> Native.parse()
end

test "omitted meta-option arguments do not overwrite previous field assignments" do
  assert {:ok,
          %ProcessingRequest{
            resizing_type: :fill,
            width: {:pixels, 500},
            height: {:pixels, 200}
          }} = conn(:get, "/_/w:500/rs:fill::200/plain/images/cat.jpg") |> Native.parse()
end

test "parses size without changing resizing_type" do
  assert {:ok,
          %ProcessingRequest{
            resizing_type: :force,
            width: {:pixels, 300},
            height: {:pixels, 200}
          }} = conn(:get, "/_/rt:force/s:300:200/plain/images/cat.jpg") |> Native.parse()
end

test "size overwrites dimensions without resetting resizing_type" do
  assert {:ok,
          %ProcessingRequest{
            resizing_type: :fill,
            width: {:pixels, 100},
            height: {:pixels, 100}
          }} = conn(:get, "/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg") |> Native.parse()
end

test "parses resizing type aliases and all documented values" do
  for {value, expected} <- [
        {"fit", :fit},
        {"fill", :fill},
        {"fill-down", :fill_down},
        {"force", :force},
        {"auto", :auto}
      ] do
    assert {:ok, %ProcessingRequest{resizing_type: ^expected}} =
             conn(:get, "/_/rt:#{value}/plain/images/cat.jpg") |> Native.parse()
  end
end

test "parses width and height aliases including zero" do
  assert {:ok, %ProcessingRequest{width: {:pixels, 0}, height: {:pixels, 200}}} =
           conn(:get, "/_/w:0/h:200/plain/images/cat.jpg") |> Native.parse()
end

test "parses gravity anchors and focal point" do
  assert {:ok, %ProcessingRequest{gravity: {:anchor, :left, :top}}} =
           conn(:get, "/_/g:nowe/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{gravity: {:fp, 0.5, 0.25}}} =
           conn(:get, "/_/gravity:fp:0.5:0.25/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{gravity: {:fp, 1.0, 0.0}}} =
           conn(:get, "/_/g:fp:1:0/plain/images/cat.jpg") |> Native.parse()
end

test "parses smart gravity for planner rejection" do
  assert {:ok, %ProcessingRequest{gravity: :sm}} =
           conn(:get, "/_/g:sm/plain/images/cat.jpg") |> Native.parse()
end

test "parses format aliases and jpg normalization" do
  assert {:ok, %ProcessingRequest{format: :webp}} =
           conn(:get, "/_/format:webp/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{format: :avif}} =
           conn(:get, "/_/f:avif/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{format: :jpeg}} =
           conn(:get, "/_/ext:jpg/plain/images/cat.jpg") |> Native.parse()
end

test "plain source extension overrides explicit format after options" do
  assert {:ok,
          %ProcessingRequest{
            format: :png,
            output_extension_from_source: :png
          }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@png") |> Native.parse()
end

test "dangling raw @ does not overwrite an explicit format" do
  assert {:ok,
          %ProcessingRequest{
            source_path: ["images", "cat.jpg"],
            format: :webp,
            output_extension_from_source: nil
          }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@") |> Native.parse()
end

test "rejects format auto because it is not imgproxy grammar" do
  assert Native.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg")) ==
           {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
end

test "later field assignments overwrite earlier assignments" do
  assert {:ok, %ProcessingRequest{resizing_type: :fill, width: {:pixels, 500}, height: {:pixels, 200}}} =
           conn(:get, "/_/resize:fill:300:200/w:500/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{resizing_type: :fill, width: {:pixels, 300}, height: {:pixels, 200}}} =
           conn(:get, "/_/w:500/resize:fill:300:200/plain/images/cat.jpg") |> Native.parse()

  assert {:ok, %ProcessingRequest{resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 200}}} =
           conn(:get, "/_/size:300:200/rt:force/plain/images/cat.jpg") |> Native.parse()
end

test "reserves chained pipeline separator as its own parser error" do
  assert Native.parse(conn(:get, "/_/rs:fit:500:500/-/trim:10/plain/images/cat.jpg")) ==
           {:error, :unsupported_chained_pipeline}

  assert {:ok, %ProcessingRequest{resizing_type: :fill_down}} =
           conn(:get, "/_/rs:fill-down:300:200/plain/images/cat.jpg") |> Native.parse()
end
```

- [ ] **Step 2: Run parser tests and verify they fail**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs
```

Expected: FAIL because imgproxy option parsing is not implemented.

- [ ] **Step 3: Replace duplicate-option rejection with left-to-right assignment**

In `lib/image_plug/param_parser/native.ex`, replace `parse_options/1` with a reducer that merges assignments:

```elixir
defp parse_options(option_segments) do
  Enum.reduce_while(option_segments, {:ok, []}, fn segment, {:ok, options} ->
    case parse_option(segment) do
      {:ok, assignments} ->
        {:cont, {:ok, Keyword.merge(options, assignments)}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end)
end
```

Delete `option_field/1`; imgproxy meta-options intentionally assign multiple fields and later assignments win per field.

- [ ] **Step 4: Implement option parsers**

Use this implementation shape in `lib/image_plug/param_parser/native.ex`:

```elixir
@resizing_types %{
  "fit" => :fit,
  "fill" => :fill,
  "fill-down" => :fill_down,
  "force" => :force,
  "auto" => :auto
}

@gravity_anchors %{
  "no" => {:anchor, :center, :top},
  "so" => {:anchor, :center, :bottom},
  "ea" => {:anchor, :right, :center},
  "we" => {:anchor, :left, :center},
  "noea" => {:anchor, :right, :top},
  "nowe" => {:anchor, :left, :top},
  "soea" => {:anchor, :right, :bottom},
  "sowe" => {:anchor, :left, :bottom},
  "ce" => {:anchor, :center, :center}
}

defp parse_option("-"), do: {:error, :unsupported_chained_pipeline}

defp parse_option(segment) do
  case String.split(segment, ":") do
    [name | args] when name in ["resize", "rs"] -> parse_resize(segment, args)
    [name | args] when name in ["size", "s"] -> parse_size(segment, args)
    [name, value] when name in ["resizing_type", "rt"] -> parse_resizing_type(value)
    [name | _args] when name in ["resizing_type", "rt"] -> {:error, {:invalid_option_segment, segment}}
    [name, value] when name in ["width", "w"] -> parse_dimension(:width, value)
    [name | _args] when name in ["width", "w"] -> {:error, {:invalid_option_segment, segment}}
    [name, value] when name in ["height", "h"] -> parse_dimension(:height, value)
    [name | _args] when name in ["height", "h"] -> {:error, {:invalid_option_segment, segment}}
    [name | args] when name in ["gravity", "g"] -> parse_gravity_option(segment, args)
    [name, value] when name in ["format", "f", "ext"] -> parse_format_option(value)
    [name | _args] when name in ["format", "f", "ext"] -> {:error, {:invalid_option_segment, segment}}
    [key | _rest] -> {:error, {:unknown_option, key}}
  end
end
```

Then add helpers:

```elixir
defp parse_resize(segment, args) when length(args) <= 8 do
  with {:ok, assignments} <- put_optional_resizing_type([], Enum.at(args, 0)),
       {:ok, assignments} <- put_optional_pixels(assignments, :width, Enum.at(args, 1)),
       {:ok, assignments} <- put_optional_pixels(assignments, :height, Enum.at(args, 2)),
       {:ok, assignments} <- put_optional_boolean(assignments, :enlarge, Enum.at(args, 3)),
       {:ok, assignments} <- put_optional_boolean(assignments, :extend, Enum.at(args, 4)),
       {:ok, extend_gravity_fields} <- parse_optional_extend_gravity(Enum.drop(args, 5)) do
    {:ok, assignments ++ extend_gravity_fields}
  end
end

defp parse_resize(segment, _args), do: {:error, {:invalid_option_segment, segment}}

defp parse_size(segment, args) when length(args) <= 7 do
  with {:ok, assignments} <- put_optional_pixels([], :width, Enum.at(args, 0)),
       {:ok, assignments} <- put_optional_pixels(assignments, :height, Enum.at(args, 1)),
       {:ok, assignments} <- put_optional_boolean(assignments, :enlarge, Enum.at(args, 2)),
       {:ok, assignments} <- put_optional_boolean(assignments, :extend, Enum.at(args, 3)),
       {:ok, extend_gravity_fields} <- parse_optional_extend_gravity(Enum.drop(args, 4)) do
    {:ok, assignments ++ extend_gravity_fields}
  end
end

defp parse_size(segment, _args), do: {:error, {:invalid_option_segment, segment}}

defp parse_resizing_type(value) do
  with {:ok, resizing_type} <- parse_resizing_type_value(value) do
    {:ok, [resizing_type: resizing_type]}
  end
end

defp put_optional_resizing_type(assignments, nil), do: {:ok, assignments}
defp put_optional_resizing_type(assignments, ""), do: {:ok, assignments}

defp put_optional_resizing_type(assignments, value) do
  with {:ok, resizing_type} <- parse_resizing_type_value(value) do
    {:ok, Keyword.put(assignments, :resizing_type, resizing_type)}
  end
end

defp parse_resizing_type_value(value) do
  case Map.fetch(@resizing_types, value) do
    {:ok, resizing_type} -> {:ok, resizing_type}
    :error -> {:error, {:invalid_resizing_type, value, Map.keys(@resizing_types) |> Enum.sort()}}
  end
end

defp parse_dimension(field, value) do
  with {:ok, pixels} <- parse_pixels(value) do
    {:ok, [{field, pixels}]}
  end
end

defp parse_format_option(value) do
  with {:ok, format} <- parse_format(value) do
    {:ok, [format: format]}
  end
end
```

Use non-negative integer pixel parsing:

```elixir
defp put_optional_pixels(assignments, _field, nil), do: {:ok, assignments}
defp put_optional_pixels(assignments, _field, ""), do: {:ok, assignments}

defp put_optional_pixels(assignments, field, value) do
  with {:ok, pixels} <- parse_pixels(value) do
    {:ok, Keyword.put(assignments, field, pixels)}
  end
end

defp parse_pixels(value) do
  case Integer.parse(value) do
    {integer, ""} when integer >= 0 -> {:ok, {:pixels, integer}}
    _other -> {:error, {:invalid_non_negative_integer, value}}
  end
end
```

Use imgproxy boolean grammar:

```elixir
defp put_optional_boolean(assignments, _field, nil), do: {:ok, assignments}
defp put_optional_boolean(assignments, _field, ""), do: {:ok, assignments}

defp put_optional_boolean(assignments, field, value) when value in ["1", "t", "true"] do
  {:ok, Keyword.put(assignments, field, true)}
end

defp put_optional_boolean(assignments, field, value) when value in ["0", "f", "false"] do
  {:ok, Keyword.put(assignments, field, false)}
end

defp put_optional_boolean(_assignments, _field, value), do: {:error, {:invalid_boolean, value}}
```

Parse gravity and extend gravity:

```elixir
defp parse_gravity_option(segment, ["sm"]), do: {:ok, [gravity: :sm]}

defp parse_gravity_option(_segment, ["fp", x, y]) do
  with {:ok, parsed_x} <- parse_focal_point_coordinate(x),
       {:ok, parsed_y} <- parse_focal_point_coordinate(y) do
    {:ok, [gravity: {:fp, parsed_x, parsed_y}, gravity_x_offset: 0.0, gravity_y_offset: 0.0]}
  end
end

defp parse_gravity_option(_segment, [gravity]) do
  with {:ok, anchor} <- parse_gravity_anchor(gravity) do
    {:ok, [gravity: anchor, gravity_x_offset: 0.0, gravity_y_offset: 0.0]}
  end
end

defp parse_gravity_option(_segment, [gravity, x_offset, y_offset]) do
  with {:ok, anchor} <- parse_gravity_anchor(gravity),
       {:ok, parsed_x_offset} <- parse_float(x_offset),
       {:ok, parsed_y_offset} <- parse_float(y_offset) do
    {:ok, [gravity: anchor, gravity_x_offset: parsed_x_offset, gravity_y_offset: parsed_y_offset]}
  end
end

defp parse_gravity_option(segment, _args), do: {:error, {:invalid_option_segment, segment}}

defp parse_optional_extend_gravity([]), do: {:ok, []}
defp parse_optional_extend_gravity([""]), do: {:ok, []}

defp parse_optional_extend_gravity([gravity]) do
  with {:ok, anchor} <- parse_gravity_anchor(gravity) do
    {:ok, [extend_gravity: anchor]}
  end
end

defp parse_optional_extend_gravity([gravity, x_offset, y_offset]) do
  with {:ok, anchor} <- parse_gravity_anchor(gravity),
       {:ok, parsed_x_offset} <- parse_float(x_offset),
       {:ok, parsed_y_offset} <- parse_float(y_offset) do
    {:ok, [extend_gravity: anchor, extend_x_offset: parsed_x_offset, extend_y_offset: parsed_y_offset]}
  end
end

defp parse_optional_extend_gravity(args), do: {:error, {:invalid_extend_gravity, args}}

defp parse_gravity_anchor(value) do
  case Map.fetch(@gravity_anchors, value) do
    {:ok, anchor} -> {:ok, anchor}
    :error -> {:error, {:invalid_gravity, value}}
  end
end

defp parse_focal_point_coordinate(value) do
  with {:ok, coordinate} <- parse_float(value),
       true <- coordinate >= 0.0 and coordinate <= 1.0 do
    {:ok, coordinate}
  else
    _ -> {:error, {:invalid_gravity_coordinate, value}}
  end
end

defp parse_float(value) do
  case Float.parse(value) do
    {float, ""} ->
      {:ok, float}

    :error ->
      case Integer.parse(value) do
        {integer, ""} -> {:ok, integer * 1.0}
        _other -> {:error, {:invalid_float, value}}
      end

    _other ->
      {:error, {:invalid_float, value}}
  end
end
```

- [ ] **Step 5: Update parser property tests for assignment semantics**

Replace `test/param_parser/native_property_test.exs` with property coverage for last-wins assignment rather than order-insensitive uniqueness:

```elixir
defmodule ImagePlug.ParamParser.NativePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.ParamParser.Native

  property "segments after plain are preserved as source path" do
    check all source_path <- valid_source_path_with_option_like_segments(),
              max_runs: 100 do
      assert {:ok, request} =
               ["w:300"]
               |> native_path(source_path)
               |> parse_path()

      assert request.source_path == source_path
    end
  end

  property "later width assignments overwrite earlier width assignments" do
    check all first <- integer(0..10_000),
              second <- integer(0..10_000),
              max_runs: 100 do
      assert {:ok, request} =
               ["w:#{first}", "w:#{second}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert request.width == {:pixels, second}
    end
  end

  property "resize meta-option overwrites atomic width and height fields by position" do
    check all width <- integer(0..10_000),
              height <- integer(0..10_000),
              max_runs: 100 do
      assert {:ok, request} =
               ["w:999", "h:888", "rs:fill:#{width}:#{height}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert request.width == {:pixels, width}
      assert request.height == {:pixels, height}
      assert request.resizing_type == :fill
    end
  end

  defp parse_path(path), do: conn(:get, path) |> Native.parse()

  defp native_path(options, source_path) do
    source_path = Enum.join(source_path, "/")

    case Enum.join(options, "/") do
      "" -> "/_/plain/#{source_path}"
      option_path -> "/_/#{option_path}/plain/#{source_path}"
    end
  end

  defp valid_source_path_with_option_like_segments do
    list_of(one_of([path_segment(), option_like_path_segment()]), min_length: 1, max_length: 6)
  end

  defp path_segment do
    string(:alphanumeric, min_length: 1, max_length: 20)
  end

  defp option_like_path_segment do
    one_of([
      map(integer(0..10_000), &"w:#{&1}"),
      map(integer(0..10_000), &"h:#{&1}"),
      member_of(~w(f:webp ext:png rs:fill:100:100 g:ce a:b c:d))
    ])
  end
end
```

- [ ] **Step 6: Run parser tests**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs test/param_parser/native_property_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/param_parser/native.ex test/param_parser/native_test.exs test/param_parser/native_property_test.exs
mise exec -- git commit -m "feat: parse imgproxy processing options"
```

## Task 4: Plan Supported Geometry And Reject Unsupported Semantics

**Files:**

- Modify: `test/image_plug/pipeline_planner_test.exs`
- Modify: `test/image_plug/pipeline_planner_property_test.exs`
- Modify: `lib/image_plug/pipeline_planner.ex`

- [ ] **Step 1: Write failing planner tests**

Replace planner tests that reference old `fit`/`focus` with imgproxy-shaped tests:

```elixir
defmodule ImagePlug.PipelinePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  test "plans no transforms for a plain request without dimensions or explicit output" do
    assert PipelinePlanner.plan(request()) == {:ok, []}
  end

  test "plans width-only fit resize as contain with auto height" do
    assert PipelinePlanner.plan(request(width: {:pixels, 300})) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto,
                   constraint: :max,
                   letterbox: false
                 }}
              ]}
  end

  test "plans zero dimensions for aspect-preserving resize types" do
    assert PipelinePlanner.plan(request(width: {:pixels, 0}, height: {:pixels, 0})) == {:ok, []}

    assert {:ok,
            [
              {Transform.Contain,
               %Transform.Contain.ContainParams{
                 width: :auto,
                 height: {:pixels, 200}
               }}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 0}, height: {:pixels, 200}))
  end

  test "maps enlarge to existing transform constraints for fit and fill" do
    assert {:ok,
            [
              {Transform.Contain,
               %Transform.Contain.ContainParams{
                 constraint: :max
               }}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 300}, enlarge: false))

    assert {:ok,
            [
              {Transform.Contain,
               %Transform.Contain.ContainParams{
                 constraint: :regular
               }}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 300}, enlarge: true))

    assert {:ok,
            [
              {Transform.Cover,
               %Transform.Cover.CoverParams{
                 constraint: :max
               }}
            ]} =
             PipelinePlanner.plan(
               request(resizing_type: :fill, width: {:pixels, 300}, height: {:pixels, 200})
             )

    assert {:ok,
            [
              {Transform.Cover,
               %Transform.Cover.CoverParams{
                 constraint: :none
               }}
            ]} =
             PipelinePlanner.plan(
               request(
                 resizing_type: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true
               )
             )
  end

  test "plans fill as focus plus cover when gravity is not center" do
    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: {:anchor, :left, :top}
             )
           ) ==
             {:ok,
              [
                {Transform.Focus, %Transform.Focus.FocusParams{type: {:anchor, :left, :top}}},
                {Transform.Cover,
                 %Transform.Cover.CoverParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :max
                 }}
              ]}
  end

  test "plans focal point gravity before fill cover" do
    assert {:ok, [{Transform.Focus, %Transform.Focus.FocusParams{type: {:coordinate, {:percent, 50.0}, {:percent, 25.0}}}}, {Transform.Cover, _}]} =
             PipelinePlanner.plan(
               request(
                 resizing_type: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 gravity: {:fp, 0.5, 0.25}
               )
             )
  end

  test "plans force as direct scale" do
    assert PipelinePlanner.plan(
             request(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 200})
           ) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200}
                 }}
              ]}
  end

  test "appends explicit output format last" do
    assert {:ok,
            [
              {Transform.Contain, %Transform.Contain.ContainParams{}},
              {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 300}, format: :webp))
  end

  test "rejects unsupported semantic combinations" do
    assert PipelinePlanner.plan(request(format: :best)) == {:error, {:unsupported_output_format, :best}}
    assert PipelinePlanner.plan(request(gravity: :sm)) == {:error, {:unsupported_gravity, :sm}}
    assert PipelinePlanner.plan(request(resizing_type: :auto)) == {:error, {:unsupported_resizing_type, :auto}}
    assert PipelinePlanner.plan(request(resizing_type: :fill_down)) == {:error, {:unsupported_resizing_type, :fill_down}}
    assert PipelinePlanner.plan(request(extend: true)) == {:error, {:unsupported_extend, true}}
    assert PipelinePlanner.plan(request(extend_gravity: {:anchor, :center, :center})) == {:error, {:unsupported_extend_gravity, {:anchor, :center, :center}}}
    assert PipelinePlanner.plan(request(gravity_x_offset: 1.0)) == {:error, {:unsupported_gravity_offset, {1.0, 0.0}}}
  end

  test "rejects fill without both dimensions" do
    assert PipelinePlanner.plan(request(resizing_type: :fill, width: {:pixels, 300})) ==
             {:error, {:missing_dimensions, :fill}}
  end

  test "rejects zero dimensions for force because current scale cannot represent imgproxy auto dimension semantics for force" do
    assert PipelinePlanner.plan(request(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200})) ==
             {:error, {:unsupported_zero_dimension, :force}}
  end

  defp request(attrs \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"]
        ],
        attrs
      )
    )
  end
end
```

- [ ] **Step 2: Run planner tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/pipeline_planner_test.exs
```

Expected: FAIL because planner still matches old `fit` and `focus`.

- [ ] **Step 3: Implement semantic validation and geometry mapping**

Replace `lib/image_plug/pipeline_planner.ex` with this shape:

```elixir
defmodule ImagePlug.PipelinePlanner do
  @moduledoc """
  Converts normalized processing requests into executable transform chains.
  """

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform
  alias ImagePlug.TransformChain

  @default_gravity {:anchor, :center, :center}

  @spec plan(ProcessingRequest.t()) :: {:ok, TransformChain.t()} | {:error, term()}
  def plan(%ProcessingRequest{} = request) do
    with :ok <- validate_supported_semantics(request),
         {:ok, geometry_chain} <- plan_geometry(request) do
      chain =
        geometry_chain
        |> prepend_gravity(request.gravity)
        |> append_output(request.format)

      {:ok, chain}
    end
  end

  defp validate_supported_semantics(%ProcessingRequest{format: :best}),
    do: {:error, {:unsupported_output_format, :best}}

  defp validate_supported_semantics(%ProcessingRequest{gravity: :sm}),
    do: {:error, {:unsupported_gravity, :sm}}

  defp validate_supported_semantics(%ProcessingRequest{resizing_type: type})
       when type in [:auto, :fill_down],
       do: {:error, {:unsupported_resizing_type, type}}

  defp validate_supported_semantics(%ProcessingRequest{extend: true}),
    do: {:error, {:unsupported_extend, true}}

  defp validate_supported_semantics(%ProcessingRequest{extend_gravity: gravity}) when not is_nil(gravity),
    do: {:error, {:unsupported_extend_gravity, gravity}}

  defp validate_supported_semantics(%ProcessingRequest{extend_x_offset: offset}) when not is_nil(offset),
    do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_supported_semantics(%ProcessingRequest{extend_y_offset: offset}) when not is_nil(offset),
    do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_supported_semantics(%ProcessingRequest{gravity_x_offset: 0.0, gravity_y_offset: 0.0}),
    do: :ok

  defp validate_supported_semantics(%ProcessingRequest{gravity_x_offset: x, gravity_y_offset: y}),
    do: {:error, {:unsupported_gravity_offset, {x, y}}}

  defp plan_geometry(%ProcessingRequest{width: width, height: height})
       when (is_nil(width) and is_nil(height)) or (width == {:pixels, 0} and height == {:pixels, 0}),
       do: {:ok, []}

  defp plan_geometry(%ProcessingRequest{resizing_type: :fit, width: width, height: height} = request) do
    {:ok, [contain(auto_dimension(width), auto_dimension(height), false, constraint_for_enlarge(:fit, request.enlarge))]}
  end

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, width: nil}), do: missing_dimensions(:fill)
  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, height: nil}), do: missing_dimensions(:fill)

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, width: width, height: height} = request) do
    {:ok,
     [
       {Transform.Cover,
        %Transform.Cover.CoverParams{
          type: :dimensions,
          width: auto_dimension(width),
          height: auto_dimension(height),
          constraint: constraint_for_enlarge(:fill, request.enlarge)
        }}
     ]}
  end

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, width: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, height: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, width: width, height: height}) do
    {:ok, [scale(width || :auto, height || :auto)]}
  end

  defp auto_dimension(nil), do: :auto
  defp auto_dimension({:pixels, 0}), do: :auto
  defp auto_dimension(dimension), do: dimension

  defp constraint_for_enlarge(:fit, false), do: :max
  defp constraint_for_enlarge(:fit, true), do: :regular
  defp constraint_for_enlarge(:fill, false), do: :max
  defp constraint_for_enlarge(:fill, true), do: :none

  defp scale(width, height) do
    {Transform.Scale,
     %Transform.Scale.ScaleParams{
       type: :dimensions,
       width: width,
       height: height
     }}
  end

  defp contain(width, height, letterbox, constraint) do
    {Transform.Contain,
     %Transform.Contain.ContainParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: constraint,
       letterbox: letterbox
     }}
  end

  defp prepend_gravity([], _gravity), do: []
  defp prepend_gravity(chain, @default_gravity), do: chain

  defp prepend_gravity([{Transform.Cover, _params} | _rest] = chain, gravity) do
    [{Transform.Focus, %Transform.Focus.FocusParams{type: focus_type(gravity)}} | chain]
  end

  defp prepend_gravity(chain, _gravity), do: chain

  defp focus_type({:anchor, _x, _y} = anchor), do: anchor
  defp focus_type({:fp, x, y}), do: {:coordinate, {:percent, x * 100.0}, {:percent, y * 100.0}}

  defp append_output(chain, nil), do: chain

  defp append_output(chain, format) do
    chain ++ [{Transform.Output, %Transform.Output.OutputParams{format: format}}]
  end

  defp missing_dimensions(type), do: {:error, {:missing_dimensions, type}}
end
```

- [ ] **Step 4: Update planner property tests**

Update `test/image_plug/pipeline_planner_property_test.exs` so generated requests use `resizing_type` and explicit formats only:

```elixir
defmodule ImagePlug.PipelinePlannerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  property "explicit output format is always planned last" do
    check all request <- valid_plannable_request_with_explicit_format(),
              max_runs: 100 do
      assert {:ok, chain} = PipelinePlanner.plan(request)
      assert List.last(chain) == {Transform.Output, %Transform.Output.OutputParams{format: request.format}}
    end
  end

  defp valid_plannable_request_with_explicit_format do
    map({valid_geometry(), member_of([:webp, :avif, :jpeg, :png])}, fn {geometry, format} ->
      request(Keyword.put(geometry, :format, format))
    end)
  end

  defp valid_geometry do
    one_of([
      constant([]),
      map(integer(0..10_000), fn width -> [width: {:pixels, width}] end),
      map(integer(0..10_000), fn height -> [height: {:pixels, height}] end),
      map({integer(1..10_000), integer(1..10_000)}, fn {width, height} ->
        [resizing_type: :force, width: {:pixels, width}, height: {:pixels, height}]
      end),
      map({integer(0..10_000), integer(0..10_000)}, fn {width, height} ->
        [resizing_type: :fill, width: {:pixels, width}, height: {:pixels, height}]
      end)
    ])
  end

  defp request(attrs) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"]
        ],
        attrs
      )
    )
  end
end
```

- [ ] **Step 5: Run planner tests**

Run:

```bash
mise exec -- mix test test/image_plug/pipeline_planner_test.exs test/image_plug/pipeline_planner_property_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/pipeline_planner.ex test/image_plug/pipeline_planner_test.exs test/image_plug/pipeline_planner_property_test.exs
mise exec -- git commit -m "feat: plan imgproxy geometry semantics"
```

## Task 5: Automatic Output Negotiation And Cache Key Material

**Files:**

- Modify: `test/image_plug/output_negotiation_test.exs`
- Modify: `lib/image_plug/output_negotiation.ex`
- Modify: `test/image_plug/cache/key_test.exs`
- Modify: `test/image_plug/cache/key_property_test.exs`
- Modify: `lib/image_plug/cache/key.ex`
- Modify: `lib/image_plug/cache.ex`

- [ ] **Step 1: Write failing output negotiation tests**

Update `test/image_plug/output_negotiation_test.exs` so q-values do not reorder server preference. Change existing tests that expect higher relative q-values to win so they now expect AVIF whenever AVIF is acceptable:

```elixir
test "uses server preference before relative q-values" do
  assert OutputNegotiation.negotiate("image/webp;q=1,image/avif;q=0.1", false) ==
           {:ok, "image/avif"}
end

test "trims q values but does not let relative q reorder server preference" do
  assert OutputNegotiation.negotiate("image/webp;q= 1,image/avif;q=0.9", true) ==
           {:ok, "image/avif"}
end

test "exact q zero excludes a format even when a wildcard matches" do
  assert OutputNegotiation.negotiate("image/avif;q=0,image/*;q=1", false) ==
           {:ok, "image/webp"}
end

test "matches image and global wildcards" do
  assert OutputNegotiation.negotiate("image/*", false) == {:ok, "image/avif"}
  assert OutputNegotiation.negotiate("*/*", false) == {:ok, "image/avif"}
end

test "returns not acceptable when wildcard excludes every supported output" do
  assert OutputNegotiation.negotiate("image/*;q=0", false) == {:error, :not_acceptable}
end

test "respects automatic format feature flags" do
  assert OutputNegotiation.negotiate("image/avif,image/webp", false, auto_avif: false) ==
           {:ok, "image/webp"}

  assert OutputNegotiation.preselect("image/avif,image/webp", auto_avif: false, auto_webp: false) ==
           :defer

  assert OutputNegotiation.preselect(nil, auto_avif: false, auto_webp: false) == :defer
end

test "preselects AVIF and WebP before origin metadata is available" do
  assert OutputNegotiation.preselect("image/webp;q=1,image/avif;q=0.1", []) == {:ok, :avif}
  assert OutputNegotiation.preselect("image/avif;q=0,image/*;q=1", []) == {:ok, :webp}
  assert OutputNegotiation.preselect("image/*;q=0", []) == {:error, :not_acceptable}
  assert OutputNegotiation.preselect("image/png", []) == :defer
end
```

Keep the existing suffix tests.

- [ ] **Step 2: Run output negotiation tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/output_negotiation_test.exs
```

Expected: FAIL on `image/webp;q=1,image/avif;q=0.1` because current code sorts by q-value.

- [ ] **Step 3: Update negotiation algorithm**

In `lib/image_plug/output_negotiation.ex`, add option-aware negotiation and a pre-origin preselection function:

```elixir
@spec negotiate(String.t() | nil, boolean(), keyword()) ::
        {:ok, String.t()} | {:error, :not_acceptable}
def negotiate(accept_header, has_alpha?, opts \\ []) do
  priority =
    opts
    |> enabled_modern_mime_types()
    |> Kernel.++(fallback_priority(has_alpha?))

  entries = parse_accept(accept_header)

  mime_type =
    case entries do
      [] -> hd(priority)
      entries -> negotiate_from_entries(priority, entries)
    end

  case mime_type do
    nil -> {:error, :not_acceptable}
    mime_type -> {:ok, mime_type}
  end
end

@spec preselect(String.t() | nil, keyword()) :: {:ok, :avif | :webp} | :defer | {:error, :not_acceptable}
def preselect(accept_header, opts \\ []) do
  entries = parse_accept(accept_header)
  modern_priority = enabled_modern_mime_types(opts)

  case entries do
    [] ->
      modern_priority |> List.first() |> preselected_mime_type()

    entries ->
      case Enum.find(modern_priority, fn mime_type -> acceptable?(entries, mime_type) end) do
        nil ->
          if explicitly_excludes_all_images?(entries), do: {:error, :not_acceptable}, else: :defer

        mime_type ->
          preselected_mime_type(mime_type)
      end
  end
end
```

Use these helpers:

```elixir
defp enabled_modern_mime_types(opts) do
  [
    Keyword.get(opts, :auto_avif, true) && "image/avif",
    Keyword.get(opts, :auto_webp, true) && "image/webp"
  ]
  |> Enum.filter(& &1)
end

defp fallback_priority(true), do: ["image/png"]
defp fallback_priority(false), do: ["image/jpeg"]

defp preselected_mime_type(nil), do: :defer
defp preselected_mime_type("image/avif"), do: {:ok, :avif}
defp preselected_mime_type("image/webp"), do: {:ok, :webp}

defp negotiate_from_entries(priority, entries) do
  Enum.find(priority, fn mime_type -> acceptable?(entries, mime_type) end)
end

defp acceptable?(entries, mime_type) do
  quality_for(entries, mime_type) > 0
end

defp quality_for(entries, mime_type) do
  exact_qualities =
    entries
    |> Enum.filter(fn {accepted, _quality} -> accepted == mime_type end)
    |> Enum.map(fn {_accepted, quality} -> quality end)

  case exact_qualities do
    [] ->
      entries
      |> Enum.filter(fn {accepted, _quality} -> wildcard_matches?(accepted, mime_type) end)
      |> Enum.map(fn {_accepted, quality} -> quality end)
      |> Enum.max(fn -> 0.0 end)

    qualities ->
      Enum.max(qualities)
  end
end

defp wildcard_matches?("*/*", _mime_type), do: true
defp wildcard_matches?("image/*", "image/" <> _subtype), do: true
defp wildcard_matches?(_accepted, _mime_type), do: false

defp explicitly_excludes_all_images?(entries) do
  wildcard_exclusion? =
    Enum.any?(entries, fn
      {"*/*", 0.0} -> true
      {"image/*", 0.0} -> true
      _entry -> false
    end)

  positive_exact_image? =
    Enum.any?(entries, fn {accepted, quality} ->
      quality > 0 and String.starts_with?(accepted, "image/") and accepted != "image/*"
    end)

  wildcard_exclusion? and not positive_exact_image?
end
```

Delete `fallback_format/2`, `allowed?/2`, and `excluded?/2` if they become unused. The priority list already includes fallback formats after AVIF/WebP.

- [ ] **Step 4: Run output negotiation tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_negotiation_test.exs
```

Expected: PASS.

- [ ] **Step 5: Write failing cache-key tests for selected output**

Replace the raw-`Accept` cache-key tests in `test/image_plug/cache/key_test.exs` with selected-output tests:

```elixir
test "automatic output includes selected format instead of raw Accept" do
  request = request(format: nil)

  conn_one =
    :get
    |> conn("/_/plain/images/cat.jpg")
    |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

  conn_two =
    :get
    |> conn("/_/plain/images/cat.jpg")
    |> put_req_header("accept", "image/avif,image/webp")

  key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg", selected_output_format: :avif)
  key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg", selected_output_format: :avif)

  assert key_one.material[:output] == [format: :avif, automatic: true]
  assert key_one.hash == key_two.hash
end

test "different selected automatic output changes cache key" do
  request = request(format: nil)
  conn = conn(:get, "/_/plain/images/cat.jpg")

  avif_key = Key.build(conn, request, "https://origin.test/images/cat.jpg", selected_output_format: :avif)
  webp_key = Key.build(conn, request, "https://origin.test/images/cat.jpg", selected_output_format: :webp)

  refute avif_key.hash == webp_key.hash
end

test "explicit formats do not include Accept material or automatic marker" do
  conn =
    :get
    |> conn("/_/f:webp/plain/images/cat.jpg")
    |> put_req_header("accept", "image/jpeg")

  key = Key.build(conn, request(format: :webp), "https://origin.test/images/cat.jpg")

  assert key.material[:output] == [format: :webp, automatic: false]
end
```

- [ ] **Step 6: Run cache-key tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/cache/key_test.exs
```

Expected: FAIL because `Key.build/4` does not accept `:selected_output_format` and still stores normalized raw `Accept`.

- [ ] **Step 7: Update cache key output material**

In `lib/image_plug/cache/key.ex`, increment `@schema_version` from `1` to `2` because operation and output key material changes. Then change `build/4` to read `:selected_output_format` from opts:

```elixir
selected_output_format = Keyword.get(opts, :selected_output_format)

material = [
  schema_version: @schema_version,
  origin_identity: origin_identity,
  operations: operations(request),
  output: output(request, selected_output_format),
  selected_headers: selected_headers(conn, opts),
  selected_cookies: selected_cookies(conn, opts)
]
```

Replace `output/2` with:

```elixir
defp output(%ProcessingRequest{format: nil}, selected_output_format)
     when selected_output_format in [:avif, :webp, :jpeg, :png] do
  [format: selected_output_format, automatic: true]
end

defp output(%ProcessingRequest{format: nil}, nil) do
  raise ArgumentError, "selected_output_format is required for automatic output cache keys"
end

defp output(%ProcessingRequest{format: format}, _selected_output_format) do
  [format: format, automatic: false]
end
```

Update `operations/1` to include new request fields except `signature`, `format`, and `output_extension_from_source`:

```elixir
defp operations(%ProcessingRequest{} = request) do
  [
    source_kind: request.source_kind,
    source_path: request.source_path,
    width: request.width,
    height: request.height,
    resizing_type: request.resizing_type,
    enlarge: request.enlarge,
    extend: request.extend,
    extend_gravity: request.extend_gravity,
    extend_x_offset: request.extend_x_offset,
    extend_y_offset: request.extend_y_offset,
    gravity: request.gravity,
    gravity_x_offset: request.gravity_x_offset,
    gravity_y_offset: request.gravity_y_offset
  ]
end
```

Delete `normalize_accept/1`, `normalize_media_range/1`, and `normalize_accept_param/1` if unused after this change.

- [ ] **Step 8: Pass selected output through cache lookup without adapter leakage**

In `lib/image_plug/cache.ex`, change `lookup/4` to delegate to a new arity:

```elixir
def lookup(conn, request, origin_identity, opts) do
  lookup(conn, request, origin_identity, opts, [])
end

def lookup(conn, request, origin_identity, opts, key_opts) do
  case cache_config(opts) do
    nil ->
      :disabled

    {:ok, adapter, cache_opts} ->
      key = Key.build(conn, request, origin_identity, Keyword.merge(cache_opts, key_opts))

      case adapter.get(key, cache_opts) do
        {:hit, %Entry{} = entry} -> {:hit, key, entry}
        :miss -> {:miss, key}
        {:error, reason} -> handle_read_error(reason, key, cache_opts)
        unexpected -> handle_read_error({:invalid_adapter_result, unexpected}, key, cache_opts)
      end

    {:error, reason} ->
      {:error, {:cache_read, reason}}
  end
end
```

This keeps `selected_output_format` available to `Key.build/4` while leaving adapter option validation and adapter calls unchanged.

- [ ] **Step 9: Update cache key property tests**

In `test/image_plug/cache/key_property_test.exs`, remove properties that assert raw `Accept` normalization or order preservation. Add this property:

```elixir
property "selected automatic output format changes cache key independently of raw Accept" do
  check all request <- cacheable_request(format: nil),
            accept_a <- string(:alphanumeric, max_length: 24),
            accept_b <- string(:alphanumeric, max_length: 24),
            accept_a != accept_b,
            max_runs: 100 do
    origin = "https://origin.test/images/cat.jpg"

    conn_a =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", accept_a)

    conn_b =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", accept_b)

    avif_key_a = Key.build(conn_a, request, origin, selected_output_format: :avif)
    avif_key_b = Key.build(conn_b, request, origin, selected_output_format: :avif)
    webp_key = Key.build(conn_b, request, origin, selected_output_format: :webp)

    assert avif_key_a.hash == avif_key_b.hash
    refute avif_key_a.hash == webp_key.hash
  end
end
```

Update helper generators to use `resizing_type` instead of `fit`. Also update the "operations include every response-affecting processing request field" test to exclude `:signature`, `:format`, and `:output_extension_from_source`.

- [ ] **Step 10: Remove transitional request fields**

After `PipelinePlanner` and `Cache.Key` both use imgproxy-shaped fields, remove the temporary `fit` and `focus` fields from `lib/image_plug/processing_request.ex`:

```elixir
defstruct signature: nil,
          source_kind: nil,
          source_path: [],
          width: nil,
          height: nil,
          resizing_type: :fit,
          enlarge: false,
          extend: false,
          extend_gravity: nil,
          extend_x_offset: nil,
          extend_y_offset: nil,
          gravity: {:anchor, :center, :center},
          gravity_x_offset: 0.0,
          gravity_y_offset: 0.0,
          format: nil,
          output_extension_from_source: nil
```

- [ ] **Step 11: Run cache key tests**

Run:

```bash
mise exec -- mix test test/image_plug/processing_request_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
```

Expected: PASS.

- [ ] **Step 12: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/output_negotiation.ex lib/image_plug/cache.ex lib/image_plug/cache/key.ex lib/image_plug/processing_request.ex test/image_plug/processing_request_test.exs test/image_plug/output_negotiation_test.exs test/image_plug/cache/key_test.exs test/image_plug/cache/key_property_test.exs
mise exec -- git commit -m "feat: normalize automatic output cache keys"
```

## Task 6: Integrate Selected Automatic Output In Plug Flow

**Files:**

- Modify: `lib/image_plug.ex`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Add failing plug-level tests for imgproxy URLs and automatic output**

In `test/image_plug_test.exs`, update old URL tests to imgproxy grammar and add automatic output tests:

```elixir
test "processes an imgproxy fill URL with explicit output extension" do
  conn = conn(:get, "/_/rs:fill:100:100/g:ce/plain/images/cat-300.jpg@jpeg")

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      origin_req_options: [plug: OriginImage]
    )

  assert conn.status == 200
  assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  assert get_resp_header(conn, "vary") == []
end

test "automatic output uses server preference over relative q-values" do
  conn =
    :get
    |> conn("/_/plain/images/cat-300.jpg")
    |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      origin_req_options: [plug: OriginImage]
    )

  assert conn.status == 200
  assert get_resp_header(conn, "content-type") == ["image/avif"]
  assert get_resp_header(conn, "vary") == ["Accept"]
end

test "exact Accept exclusion overrides wildcard allowance" do
  conn =
    :get
    |> conn("/_/plain/images/cat-300.jpg")
    |> put_req_header("accept", "image/avif;q=0,image/*;q=1")

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      origin_req_options: [plug: OriginImage]
    )

  assert conn.status == 200
  assert get_resp_header(conn, "content-type") == ["image/webp"]
  assert get_resp_header(conn, "vary") == ["Accept"]
end

test "automatic AVIF cache hits do not fetch origin" do
  cache_probe = start_cache_probe()

  cached_entry = %ImagePlug.Cache.Entry{
    body: "cached avif",
    content_type: "image/avif",
    headers: [{"vary", "Accept"}],
    created_at: DateTime.utc_now()
  }

  conn =
    :get
    |> conn("/_/plain/images/cat-300.jpg")
    |> put_req_header("accept", "image/avif,image/webp")

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
      origin_req_options: [plug: OriginShouldNotBeCalled]
    )

  flush_cache_probe(cache_probe)
  assert conn.status == 200
  assert conn.resp_body == "cached avif"
  assert_received {:cache_get, key}
  assert key.material[:output] == [format: :avif, automatic: true]
  refute_received :origin_was_called
end

test "disabled automatic modern formats still set Vary for negotiated fallback output" do
  conn = conn(:get, "/_/plain/images/cat-300.jpg")

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      auto_avif: false,
      auto_webp: false,
      origin_req_options: [plug: OriginImage]
    )

  assert conn.status == 200
  assert get_resp_header(conn, "vary") == []
end

test "does not touch cache or origin when planner rejects unsupported semantics" do
  conn = conn(:get, "/_/rs:auto:100:100/plain/images/cat-300.jpg")
  cache_probe = start_cache_probe()

  conn =
    ImagePlug.call(conn,
      root_url: "http://origin.test",
      param_parser: ImagePlug.ParamParser.Native,
      cache: {CacheProbe, message_target: cache_probe},
      origin_req_options: [plug: OriginShouldNotBeCalled]
    )

  flush_cache_probe(cache_probe)
  assert conn.status == 400
  refute_received {:cache_get, _key}
  refute_received :origin_was_called
end
```

- [ ] **Step 2: Run plug tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: FAIL because `ImagePlug.call/2` still uses old URLs and raw `format:auto` flow.

- [ ] **Step 3: Add selected-output helpers in `ImagePlug`**

Add helpers in `lib/image_plug.ex`:

```elixir
defp output_negotiation_opts(opts) do
  [
    auto_avif: Keyword.get(opts, :auto_avif, true),
    auto_webp: Keyword.get(opts, :auto_webp, true)
  ]
end

defp selected_output_format(%Plug.Conn{} = conn, image, opts) do
  accept_header = conn |> get_req_header("accept") |> Enum.join(",")

  case OutputNegotiation.negotiate(accept_header, Image.has_alpha?(image), output_negotiation_opts(opts)) do
    {:ok, mime_type} -> {:ok, OutputNegotiation.format!(mime_type)}
    {:error, :not_acceptable} -> {:error, :not_acceptable}
  end
end
```

Keep MIME/format conversion in `OutputNegotiation` with `format!/1`, `mime_type!/1`, and `suffix!/1`.

- [ ] **Step 4: Split explicit and automatic cache flow**

In `ImagePlug.call/2`, after request, chain, and origin identity succeed, dispatch by request format:

```elixir
dispatch_request(conn, request, chain, origin_identity, opts)

defp dispatch_request(conn, %ProcessingRequest{format: nil} = request, chain, origin_identity, opts) do
  dispatch_automatic_request(conn, request, chain, origin_identity, opts)
end

defp dispatch_request(conn, %ProcessingRequest{} = request, chain, origin_identity, opts) do
  dispatch_explicit_request(conn, request, chain, origin_identity, opts)
end
```

Move the existing `dispatch_request/5` body to `dispatch_explicit_request/5`.

For automatic requests, use a two-phase cache strategy:

- If `OutputNegotiation.preselect/2` can select AVIF or WebP from `Accept` and enabled auto flags, build the cache key and check cache before origin fetch.
- If preselection returns `:defer`, fetch/decode origin, negotiate source/fallback output with metadata, then build the cache key with the selected format.
- If preselection returns `{:error, :not_acceptable}`, return `406` before cache or origin.

```elixir
defp dispatch_automatic_request(conn, request, chain, origin_identity, opts) do
  accept_header = conn |> get_req_header("accept") |> Enum.join(",")

  case OutputNegotiation.preselect(accept_header, output_negotiation_opts(opts)) do
    {:ok, selected_format} ->
      dispatch_preselected_automatic_request(conn, request, chain, origin_identity, selected_format, opts)

    :defer ->
      dispatch_deferred_automatic_request(conn, request, chain, origin_identity, opts)

    {:error, :not_acceptable} ->
      send_not_acceptable(conn)
  end
end
```

Implement the preselected path so cache hits avoid origin fetch:

```elixir
defp dispatch_preselected_automatic_request(conn, request, chain, origin_identity, selected_format, opts) do
  selected_chain = append_selected_output(chain, selected_format)

  case Cache.lookup(conn, request, origin_identity, opts, selected_output_format: selected_format) do
    :disabled ->
      process_uncached(conn, request, selected_chain, origin_identity, opts, automatic?: vary_for_automatic?(opts))

    {:hit, _key, %Entry{} = entry} ->
      send_cache_entry(conn, entry)

    {:miss, %Key{} = key} ->
      process_cache_miss(conn, request, selected_chain, origin_identity, key, opts, automatic?: vary_for_automatic?(opts))

    {:error, {:cache_read, error}} ->
      send_cache_error(conn, error)
  end
end
```

Implement the deferred path for source/fallback formats:

```elixir
defp dispatch_deferred_automatic_request(conn, request, chain, origin_identity, opts) do
  with {:ok, image} <- fetch_decode_and_validate_origin(request, origin_identity, opts),
       {:ok, selected_format} <- selected_output_format(conn, image, opts) do
    selected_chain = append_selected_output(chain, selected_format)

    case Cache.lookup(conn, request, origin_identity, opts, selected_output_format: selected_format) do
      :disabled ->
        process_decoded_uncached(conn, image, selected_chain, opts, automatic?: vary_for_automatic?(opts))

      {:hit, _key, %Entry{} = entry} ->
        send_cache_entry(conn, entry)

      {:miss, %Key{} = key} ->
        process_decoded_cache_miss(conn, image, selected_chain, key, opts, automatic?: vary_for_automatic?(opts))

      {:error, {:cache_read, error}} ->
        send_cache_error(conn, error)
    end
  else
    {:error, :not_acceptable} -> send_not_acceptable(conn)
    {:error, {:origin, error}} -> send_origin_error(conn, error)
    {:error, {:decode, error}} -> send_decode_error(conn, error)
    {:error, {:input_limit, error}} -> send_input_limit_error(conn, error)
  end
end

defp append_selected_output(chain, selected_format) do
  chain ++ [{ImagePlug.Transform.Output, %ImagePlug.Transform.Output.OutputParams{format: selected_format}}]
end
```

To avoid duplicating origin code, extract existing `process_origin/4` into:

```elixir
defp fetch_decode_and_validate_origin(request, origin_identity, opts) do
  with {:ok, origin_response} <- fetch_origin(request, origin_identity, opts) |> wrap_origin_error(),
       {:ok, image} <- decode_origin_response(origin_response) |> wrap_origin_decode_error(),
       :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
    {:ok, image}
  end
end

defp execute_chain(image, chain) do
  TransformChain.execute(%TransformState{image: image}, chain)
end
```

Then use `execute_chain/2` from explicit and automatic paths.

- [ ] **Step 5: Ensure automatic responses set `Vary: Accept`**

Change response header handling so automatic requests set `Vary: Accept`. Preselected AVIF/WebP responses, source-format fallback responses, alpha fallback responses, and automatic `406 Not Acceptable` responses should all set `Vary: Accept` because the request `Accept` header can affect the selected output or error outcome. Explicit `format`, `f`, `ext`, and `@extension` responses should not set `Vary: Accept`.

```elixir
defp send_image(%Plug.Conn{} = conn, %TransformState{} = state, opts, response_headers \\ []) do
  mime_type = output_mime_type(state.output)
  suffix = OutputNegotiation.suffix!(mime_type)
  image_module = Keyword.get(opts, :image_module, Image)
  ...
  stream_image(stream, conn, mime_type, response_headers)
end

defp accept_vary_headers, do: [{"vary", "Accept"}]
```

Apply the same response headers to cache entries:

```elixir
encode_cache_entry(conn, final_state, opts, accept_vary_headers())
```

- [ ] **Step 6: Run plug tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
mise exec -- git add lib/image_plug.ex test/image_plug_test.exs
mise exec -- git commit -m "feat: select automatic output before caching"
```

## Task 7: README And Final Compatibility Sweep

**Files:**

- Modify: `README.md`
- Modify any tests still referencing old URL grammar

- [ ] **Step 1: Replace README URL grammar**

Update README examples to imgproxy-compatible grammar:

```markdown
/_/w:300/plain/images/cat-300.jpg
/_/rs:fill:300:300/g:ce/plain/images/cat-300.jpg
/_/rs:fit:800:0/f:webp/plain/images/cat-300.jpg
/_/rt:force/w:300/h:200/plain/images/cat-300.jpg
/_/rs:fill:300:300/plain/images/cat-300.jpg@webp
```

Document supported options:

```markdown
resize:%resizing_type:%width:%height:%enlarge:%extend
rs:%resizing_type:%width:%height:%enlarge:%extend
size:%width:%height:%enlarge:%extend
s:%width:%height:%enlarge:%extend
resizing_type:%resizing_type
rt:%resizing_type
width:%width
w:%width
height:%height
h:%height
gravity:%type:%x_offset:%y_offset
g:%type:%x_offset:%y_offset
format:%extension
f:%extension
ext:%extension
plain source @extension
```

State explicitly:

```markdown
Omitting an explicit output format enables automatic output selection. ImagePlug defaults automatic AVIF and WebP selection to enabled. Explicit `format`, `f`, `ext`, and plain-source `@extension` bypass `Accept` negotiation.
```

- [ ] **Step 2: Search for old grammar in docs and tests**

Run:

```bash
rg -n "focus:|format:auto|format:(webp|jpeg|png)|fit:(cover|contain|fill|inside)" README.md lib test docs/superpowers
```

Expected: Only approved design history may mention old forms. Tests and README examples should use imgproxy grammar. `rs:fit:...` is valid imgproxy grammar and should not be treated as an old-form match.

- [ ] **Step 3: Update any remaining tests that construct old fields**

If `rg` or compile errors show old request fields, replace:

```elixir
fit: :cover
focus: {:anchor, :left, :top}
format: :auto
```

with:

```elixir
resizing_type: :fill
gravity: {:anchor, :left, :top}
format: nil
```

Replace old explicit format URLs:

```text
format:webp
format:jpeg
format:png
```

with:

```text
f:webp
f:jpeg
f:png
```

- [ ] **Step 4: Run focused suites**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs test/image_plug/pipeline_planner_test.exs test/image_plug/output_negotiation_test.exs test/image_plug/cache/key_test.exs test/image_plug_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 6: Format**

Run:

```bash
mise exec -- mix format
```

Expected: Files are formatted without errors.

- [ ] **Step 7: Compile with warnings as errors if available**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS. If the project or dependencies do not support warnings-as-errors cleanly, run `mise exec -- mix compile` and record the exact reason in the final handoff.

- [ ] **Step 8: Commit**

Run:

```bash
mise exec -- git add README.md lib test
mise exec -- git commit -m "docs: document imgproxy-compatible urls"
```

## Final Verification

- [ ] **Step 1: Run the full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 2: Run formatting check**

Run:

```bash
mise exec -- mix format --check-formatted
```

Expected: PASS.

- [ ] **Step 3: Run compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS, or document why warnings-as-errors is not supported and run `mise exec -- mix compile` instead.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git status --short
```

Expected: clean worktree.

## Self-Review

Spec coverage:

- URL structure and raw `@` parsing are covered by Task 2.
- Supported option grammar and assignment order are covered by Task 3.
- Parser/planner error boundaries are covered by Tasks 3 and 4.
- Current executable geometry behavior is covered by Task 4.
- Imgproxy zero-dimension behavior and enlarge constraint mapping are covered by Task 4.
- `best`, `sm`, `auto`, `fill-down`, `extend`, extend gravity, and non-zero gravity offsets are covered by Task 4.
- Automatic output negotiation, q-values, wildcards, exact media exclusions, auto format flags, pre-origin AVIF/WebP preselection, and 406 behavior are covered by Task 5 and Task 6.
- Cache key selected output behavior is covered by Task 5 and Task 6.
- README updates are covered by Task 7.

Placeholder scan:

- The plan contains no placeholder markers, no unspecified test steps, and no references to undefined tasks.

Type consistency:

- The plan consistently uses `format: nil` for omitted output format.
- The plan consistently uses `resizing_type` instead of old `fit`.
- The plan consistently uses `gravity` instead of old `focus`.
- The plan consistently uses `output_extension_from_source` as the clearer implementation field name.
