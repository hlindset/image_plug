# Native Path API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build ImagePlug's native path-oriented declarative API and make it the default public parser.

**Architecture:** Add a product-neutral `ImagePlug.ProcessingRequest` as the parser output, then add `ImagePlug.ParamParser.Native` for `/<signature>/<options>/plain/<origin_path>` URLs. Add `ImagePlug.PipelinePlanner` to convert declarative requests into the existing `TransformChain`, and update `ImagePlug` so origin fetches use the parsed source path instead of the whole request path.

**Tech Stack:** Elixir, Plug, ExUnit, Req, image/Vix/libvips. Run all project commands through `mise exec -- ...`.

---

## File Structure

- Create `lib/image_plug/processing_request.ex`: native request struct and types.
- Create `lib/image_plug/param_parser/native.ex`: path parser and native parser error renderer.
- Create `lib/image_plug/pipeline_planner.ex`: request-to-transform-chain planner.
- Modify `lib/image_plug/param_parser.ex`: change parser behaviour docs and callback type from transform chain to processing request.
- Modify `lib/image_plug.ex`: parse request, plan transform chain, fetch origin from `ProcessingRequest.source_path`, and route planner errors through parser error rendering.
- Delete `lib/image_plug/param_parser/twicpics.ex` and `lib/image_plug/param_parser/twicpics/**`: remove the old TwicPics-shaped parser implementation completely.
- Modify `lib/simple_server.ex`: default to `ImagePlug.ParamParser.Native`.
- Modify `README.md`: document the native path API and fixed pipeline semantics.
- Create `test/image_plug/processing_request_test.exs`: struct defaults.
- Create `test/param_parser/native_test.exs`: native parser grammar, error, and order-insensitivity tests.
- Create `test/image_plug/pipeline_planner_test.exs`: planner mapping tests.
- Modify `test/image_plug_test.exs`: plug integration tests use native URLs and fake planners where chain injection is needed.
- Delete `test/param_parser/twicpics_test.exs`, `test/param_parser/twicpics_parser_test.exs`, and `test/param_parser/twicpics/**`: remove tests for the old API surface.

## Implementation Notes

- Remove the old TwicPics parser and tests during this implementation. The codebase is unreleased, so keeping compatibility scaffolding is unnecessary.
- The first native implementation supports pixel dimensions for `w` and `h`, and pixel or percent coordinates for `focus:<x>:<y>`.
- The planner treats omitted `fit` as direct scale behavior when dimensions are supplied.
- `fit:cover`, `fit:fill`, and `fit:inside` require both `w` and `h`.
- `fit:contain` accepts one or both dimensions.
- `format:blurhash` is not part of the native parser.
- Parser and planner failures must happen before origin fetch.

### Task 1: Add ProcessingRequest And Parser Behaviour Shape

**Files:**
- Create: `test/image_plug/processing_request_test.exs`
- Create: `lib/image_plug/processing_request.ex`
- Modify: `lib/image_plug/param_parser.ex`

- [ ] **Step 1: Write the failing ProcessingRequest test**

Create `test/image_plug/processing_request_test.exs`:

```elixir
defmodule ImagePlug.ProcessingRequestTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest

  test "has native request defaults" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"]
    }

    assert request.signature == "_"
    assert request.source_kind == :plain
    assert request.source_path == ["images", "cat.jpg"]
    assert request.width == nil
    assert request.height == nil
    assert request.fit == nil
    assert request.focus == {:anchor, :center, :center}
    assert request.format == :auto
  end
end
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/processing_request_test.exs
```

Expected: failure because `ImagePlug.ProcessingRequest` is not defined.

- [ ] **Step 3: Add the ProcessingRequest module**

Create `lib/image_plug/processing_request.ex`:

```elixir
defmodule ImagePlug.ProcessingRequest do
  @moduledoc """
  Product-neutral representation of a native ImagePlug processing request.
  """

  @type source_kind() :: :plain
  @type fit() :: :cover | :contain | :fill | :inside
  @type format() :: :auto | :webp | :avif | :jpeg | :png
  @type focus() ::
          ImagePlug.TransformState.focus_anchor()
          | {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}

  @type t() :: %__MODULE__{
          signature: String.t(),
          source_kind: source_kind(),
          source_path: [String.t()],
          width: ImagePlug.imgp_pixels() | nil,
          height: ImagePlug.imgp_pixels() | nil,
          fit: fit() | nil,
          focus: focus(),
          format: format()
        }

  defstruct signature: nil,
            source_kind: nil,
            source_path: [],
            width: nil,
            height: nil,
            fit: nil,
            focus: {:anchor, :center, :center},
            format: :auto
end
```

- [ ] **Step 4: Update the parser behaviour to return ProcessingRequest**

Replace `lib/image_plug/param_parser.ex` with:

```elixir
defmodule ImagePlug.ParamParser do
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  @type transform_module() ::
          Transform.Crop
          | Transform.Focus
          | Transform.Scale
          | Transform.Contain
          | Transform.Cover
          | Transform.Output

  @typedoc """
  A tuple of a module implementing `ImagePlug.Transform`
  and the parsed parameters for that transform.
  """
  @type transform_chain_item() ::
          {Transform.Crop, Transform.Crop.CropParams.t()}
          | {Transform.Focus, Transform.Focus.FocusParams.t()}
          | {Transform.Scale, Transform.Scale.ScaleParams.t()}
          | {Transform.Contain, Transform.Contain.ContainParams.t()}
          | {Transform.Cover, Transform.Cover.CoverParams.t()}
          | {Transform.Output, Transform.Output.OutputParams.t()}

  @type transform_chain() :: list(transform_chain_item())

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, ProcessingRequest.t()} | {:error, any()}

  @doc """
  Render parser-specific errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
```

- [ ] **Step 5: Run the focused test to verify it passes**

Run:

```bash
mise exec -- mix test test/image_plug/processing_request_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 6: Commit Task 1**

Run:

```bash
git add lib/image_plug/processing_request.ex lib/image_plug/param_parser.ex test/image_plug/processing_request_test.exs
git commit -m "feat: add processing request model"
```

### Task 2: Add Native Path Parser

**Files:**
- Create: `test/param_parser/native_test.exs`
- Create: `lib/image_plug/param_parser/native.ex`

- [ ] **Step 1: Write native parser tests**

Create `test/param_parser/native_test.exs`:

```elixir
defmodule ImagePlug.ParamParser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.ParamParser.Native
  alias ImagePlug.ProcessingRequest

  test "parses a plain source with no options" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              format: :auto,
              focus: {:anchor, :center, :center}
            }} = Native.parse(conn)
  end

  test "parses native options into a processing request" do
    conn =
      conn(
        :get,
        "/_/fit:cover/w:300/h:200/focus:50p:25p/format:webp/plain/images/cat.jpg"
      )

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              fit: :cover,
              width: {:pixels, 300},
              height: {:pixels, 200},
              focus: {:coordinate, {:percent, 50}, {:percent, 25}},
              format: :webp
            }} = Native.parse(conn)
  end

  test "option order does not affect the parsed request" do
    first =
      conn(:get, "/_/fit:cover/w:300/h:200/focus:top/format:png/plain/images/cat.jpg")
      |> Native.parse()

    second =
      conn(:get, "/_/format:png/focus:top/h:200/w:300/fit:cover/plain/images/cat.jpg")
      |> Native.parse()

    assert first == second
  end

  test "supports unsafe as the development signature segment" do
    conn = conn(:get, "/unsafe/w:300/plain/images/cat.jpg")

    assert {:ok, %ProcessingRequest{signature: "unsafe", width: {:pixels, 300}}} =
             Native.parse(conn)
  end

  test "rejects unsupported signature segments" do
    conn = conn(:get, "/signed-value/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing source kind" do
    conn = conn(:get, "/_/w:300")

    assert Native.parse(conn) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    conn = conn(:get, "/_/w:300/plain")

    assert Native.parse(conn) == {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects unknown options" do
    conn = conn(:get, "/_/resize:300/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:unknown_option, "resize"}}
  end

  test "rejects duplicate options" do
    conn = conn(:get, "/_/w:300/w:400/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:duplicate_option, :width}}
  end

  test "rejects invalid dimensions" do
    conn = conn(:get, "/_/w:0/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:invalid_positive_integer, "0"}}
  end

  test "rejects blurhash as a native image format" do
    conn = conn(:get, "/_/format:blurhash/plain/images/cat.jpg")

    assert Native.parse(conn) ==
             {:error, {:invalid_format, "blurhash", ["auto", "webp", "avif", "jpeg", "png"]}}
  end

  test "renders native parser errors as text 400 responses" do
    conn = conn(:get, "/_/resize:300/plain/images/cat.jpg")

    conn = Native.handle_error(conn, {:error, {:unknown_option, "resize"}})

    assert conn.status == 400
    assert conn.resp_body == "invalid image request: {:unknown_option, \"resize\"}"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
```

- [ ] **Step 2: Run parser tests to verify they fail**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs
```

Expected: failure because `ImagePlug.ParamParser.Native` is not defined.

- [ ] **Step 3: Add the native parser**

Create `lib/image_plug/param_parser/native.ex`:

```elixir
defmodule ImagePlug.ParamParser.Native do
  @behaviour ImagePlug.ParamParser

  import Plug.Conn

  alias ImagePlug.ProcessingRequest

  @signatures ["_", "unsafe"]
  @source_kinds ["plain"]
  @formats ["auto", "webp", "avif", "jpeg", "png"]
  @fits ["cover", "contain", "fill", "inside"]
  @focus_anchors %{
    "center" => {:anchor, :center, :center},
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center}
  }

  @impl ImagePlug.ParamParser
  def parse(%Plug.Conn{path_info: path_info}) do
    with {:ok, signature, rest} <- parse_signature(path_info),
         {:ok, option_segments, source_kind, source_path} <- split_source(rest),
         {:ok, options} <- parse_options(option_segments, %{}) do
      {:ok,
       struct!(
         ProcessingRequest,
         Map.merge(options, %{
           signature: signature,
           source_kind: String.to_existing_atom(source_kind),
           source_path: source_path
         })
       )}
    end
  end

  @impl ImagePlug.ParamParser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp parse_signature([]), do: {:error, :missing_signature}

  defp parse_signature([signature | rest]) do
    if signature in @signatures do
      {:ok, signature, rest}
    else
      {:error, {:unsupported_signature, signature}}
    end
  end

  defp split_source(segments) do
    case Enum.find_index(segments, &(&1 in @source_kinds)) do
      nil ->
        {:error, :missing_source_kind}

      index ->
        {option_segments, [source_kind | source_path]} = Enum.split(segments, index)

        case source_path do
          [] -> {:error, {:missing_source_identifier, source_kind}}
          _ -> {:ok, option_segments, source_kind, source_path}
        end
    end
  end

  defp parse_options([], acc), do: {:ok, acc}

  defp parse_options([segment | rest], acc) do
    with {:ok, key, value} <- split_option(segment),
         {:ok, acc} <- parse_option(key, value, acc) do
      parse_options(rest, acc)
    end
  end

  defp split_option(segment) do
    case String.split(segment, ":", parts: 2) do
      [key, value] when key != "" and value != "" -> {:ok, key, value}
      _ -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_option("w", value, acc) do
    with {:ok, width} <- parse_dimension(value) do
      put_once(acc, :width, width)
    end
  end

  defp parse_option("h", value, acc) do
    with {:ok, height} <- parse_dimension(value) do
      put_once(acc, :height, height)
    end
  end

  defp parse_option("fit", value, acc) do
    if value in @fits do
      put_once(acc, :fit, String.to_existing_atom(value))
    else
      {:error, {:invalid_fit, value, @fits}}
    end
  end

  defp parse_option("focus", value, acc) do
    with {:ok, focus} <- parse_focus(value) do
      put_once(acc, :focus, focus)
    end
  end

  defp parse_option("format", value, acc) do
    if value in @formats do
      put_once(acc, :format, String.to_existing_atom(value))
    else
      {:error, {:invalid_format, value, @formats}}
    end
  end

  defp parse_option(key, _value, _acc), do: {:error, {:unknown_option, key}}

  defp put_once(acc, key, value) do
    if Map.has_key?(acc, key) do
      {:error, {:duplicate_option, key}}
    else
      {:ok, Map.put(acc, key, value)}
    end
  end

  defp parse_dimension(value) do
    with {:ok, integer} <- parse_positive_integer(value) do
      {:ok, {:pixels, integer}}
    end
  end

  defp parse_focus(value) do
    case Map.fetch(@focus_anchors, value) do
      {:ok, anchor} ->
        {:ok, anchor}

      :error ->
        parse_focus_coordinate(value)
    end
  end

  defp parse_focus_coordinate(value) do
    case String.split(value, ":", parts: 2) do
      [left, top] ->
        with {:ok, left} <- parse_length(left),
             {:ok, top} <- parse_length(top) do
          {:ok, {:coordinate, left, top}}
        end

      _ ->
        {:error, {:invalid_focus, value}}
    end
  end

  defp parse_length(value) do
    case String.ends_with?(value, "p") do
      true ->
        value
        |> String.trim_trailing("p")
        |> parse_non_negative_integer()
        |> case do
          {:ok, integer} -> {:ok, {:percent, integer}}
          {:error, reason} -> {:error, reason}
        end

      false ->
        parse_dimension(value)
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _ -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _ -> {:error, {:invalid_non_negative_integer, value}}
    end
  end
end
```

- [ ] **Step 4: Run parser tests to verify they pass**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs
```

Expected: 12 tests, 0 failures.

- [ ] **Step 5: Commit Task 2**

Run:

```bash
git add lib/image_plug/param_parser/native.ex test/param_parser/native_test.exs
git commit -m "feat: add native path parser"
```

### Task 3: Add PipelinePlanner

**Files:**
- Create: `test/image_plug/pipeline_planner_test.exs`
- Create: `lib/image_plug/pipeline_planner.ex`

- [ ] **Step 1: Write planner tests**

Create `test/image_plug/pipeline_planner_test.exs`:

```elixir
defmodule ImagePlug.PipelinePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  test "plans no transforms for a plain request with no options" do
    request = %ProcessingRequest{signature: "_", source_kind: :plain, source_path: ["images", "cat.jpg"]}

    assert PipelinePlanner.plan(request) == {:ok, []}
  end

  test "plans width-only resize as a scale transform" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      width: {:pixels, 300}
    }

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto
                 }}
              ]}
  end

  test "plans cover with focus before the cover transform" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      fit: :cover,
      width: {:pixels, 300},
      height: {:pixels, 200},
      focus: {:anchor, :center, :top}
    }

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Focus, %Transform.Focus.FocusParams{type: {:anchor, :center, :top}}},
                {Transform.Cover,
                 %Transform.Cover.CoverParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :none
                 }}
              ]}
  end

  test "plans contain without letterbox" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      fit: :contain,
      width: {:pixels, 800}
    }

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 800},
                   height: :auto,
                   constraint: :none,
                   letterbox: false
                 }}
              ]}
  end

  test "plans inside as contain with letterbox" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      fit: :inside,
      width: {:pixels, 300},
      height: {:pixels, 200}
    }

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :none,
                   letterbox: true
                 }}
              ]}
  end

  test "plans fill as direct scale" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      fit: :fill,
      width: {:pixels, 300},
      height: {:pixels, 200}
    }

    assert PipelinePlanner.plan(request) ==
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

  test "plans explicit output format last" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      width: {:pixels, 300},
      format: :webp
    }

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto
                 }},
                {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
              ]}
  end

  test "rejects cover without both dimensions" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      fit: :cover,
      width: {:pixels, 300}
    }

    assert PipelinePlanner.plan(request) == {:error, {:missing_dimensions, :cover}}
  end
end
```

- [ ] **Step 2: Run planner tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/pipeline_planner_test.exs
```

Expected: failure because `ImagePlug.PipelinePlanner` is not defined.

- [ ] **Step 3: Add PipelinePlanner**

Create `lib/image_plug/pipeline_planner.ex`:

```elixir
defmodule ImagePlug.PipelinePlanner do
  @moduledoc """
  Converts declarative processing requests into executable transform chains.
  """

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  @default_focus {:anchor, :center, :center}

  @spec plan(ProcessingRequest.t()) :: {:ok, ImagePlug.ParamParser.transform_chain()} | {:error, term()}
  def plan(%ProcessingRequest{} = request) do
    with {:ok, geometry} <- geometry_transform(request) do
      chain =
        []
        |> append_focus(request, geometry)
        |> append_geometry(geometry)
        |> append_output(request)

      {:ok, chain}
    end
  end

  defp geometry_transform(%ProcessingRequest{fit: nil, width: nil, height: nil}), do: {:ok, nil}

  defp geometry_transform(%ProcessingRequest{fit: nil, width: width, height: height}) do
    {:ok,
     {Transform.Scale,
      %Transform.Scale.ScaleParams{
        type: :dimensions,
        width: width || :auto,
        height: height || :auto
      }}}
  end

  defp geometry_transform(%ProcessingRequest{fit: :cover, width: width, height: height})
       when not is_nil(width) and not is_nil(height) do
    {:ok,
     {Transform.Cover,
      %Transform.Cover.CoverParams{
        type: :dimensions,
        width: width,
        height: height,
        constraint: :none
      }}}
  end

  defp geometry_transform(%ProcessingRequest{fit: :cover}), do: {:error, {:missing_dimensions, :cover}}

  defp geometry_transform(%ProcessingRequest{fit: :contain, width: nil, height: nil}),
    do: {:error, {:missing_dimensions, :contain}}

  defp geometry_transform(%ProcessingRequest{fit: :contain, width: width, height: height}) do
    {:ok,
     {Transform.Contain,
      %Transform.Contain.ContainParams{
        type: :dimensions,
        width: width || :auto,
        height: height || :auto,
        constraint: :none,
        letterbox: false
      }}}
  end

  defp geometry_transform(%ProcessingRequest{fit: :fill, width: width, height: height})
       when not is_nil(width) and not is_nil(height) do
    {:ok,
     {Transform.Scale,
      %Transform.Scale.ScaleParams{
        type: :dimensions,
        width: width,
        height: height
      }}}
  end

  defp geometry_transform(%ProcessingRequest{fit: :fill}), do: {:error, {:missing_dimensions, :fill}}

  defp geometry_transform(%ProcessingRequest{fit: :inside, width: width, height: height})
       when not is_nil(width) and not is_nil(height) do
    {:ok,
     {Transform.Contain,
      %Transform.Contain.ContainParams{
        type: :dimensions,
        width: width,
        height: height,
        constraint: :none,
        letterbox: true
      }}}
  end

  defp geometry_transform(%ProcessingRequest{fit: :inside}), do: {:error, {:missing_dimensions, :inside}}

  defp append_focus(chain, %ProcessingRequest{focus: @default_focus}, _geometry), do: chain
  defp append_focus(chain, %ProcessingRequest{}, nil), do: chain

  defp append_focus(chain, %ProcessingRequest{focus: focus}, _geometry) do
    chain ++ [{Transform.Focus, %Transform.Focus.FocusParams{type: focus}}]
  end

  defp append_geometry(chain, nil), do: chain
  defp append_geometry(chain, geometry), do: chain ++ [geometry]

  defp append_output(chain, %ProcessingRequest{format: :auto}), do: chain

  defp append_output(chain, %ProcessingRequest{format: format}) do
    chain ++ [{Transform.Output, %Transform.Output.OutputParams{format: format}}]
  end
end
```

- [ ] **Step 4: Run planner tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug/pipeline_planner_test.exs
```

Expected: 8 tests, 0 failures.

- [ ] **Step 5: Commit Task 3**

Run:

```bash
git add lib/image_plug/pipeline_planner.ex test/image_plug/pipeline_planner_test.exs
git commit -m "feat: plan native processing requests"
```

### Task 4: Wire Native Requests Into ImagePlug

**Files:**
- Modify: `lib/image_plug.ex`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Update plug integration tests for request planning**

In `test/image_plug_test.exs`, add the alias and replace the fake parsers/planners near the top of the module:

```elixir
  alias ImagePlug.ProcessingRequest

  defmodule OriginShouldNotBeCalled do
    def call(conn) do
      send(self(), :origin_was_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end
  end

  defmodule OriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule OversizedOriginBody do
    def call(conn, _) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end
  end

  defmodule BrokenImageParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      {:ok,
       %ProcessingRequest{
         signature: "_",
         source_kind: :plain,
         source_path: ["images", "cat-300.jpg"]
       }}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule BrokenImagePlanner do
    def plan(%ProcessingRequest{}) do
      {:ok, [{ImagePlug.ImagePlugTest.BrokenImageTransform, nil}]}
    end
  end

  defmodule BrokenImageTransform do
    def execute(%ImagePlug.TransformState{} = state, _params) do
      %ImagePlug.TransformState{state | image: :not_an_image, output: :jpeg}
    end
  end

  defmodule RaisingAfterFirstChunkParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      {:ok,
       %ProcessingRequest{
         signature: "_",
         source_kind: :plain,
         source_path: ["images", "cat-300.jpg"]
       }}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule RaisingAfterFirstChunkPlanner do
    def plan(%ProcessingRequest{}) do
      {:ok, [{ImagePlug.ImagePlugTest.RaisingAfterFirstChunkTransform, nil}]}
    end
  end
```

Then update the request paths and options in the existing tests:

```elixir
  test "does not fetch origin when transform params are invalid" do
    conn = conn(:get, "/_/w:0/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end
```

Use `param_parser: ImagePlug.ParamParser.Native` for normal plug tests. Use native paths:

```elixir
conn("/_/plain/images/cat-300.jpg")
conn(:get, "/_/w:10/plain/images/large.png")
conn(:get, "/_/plain/images/large-body.png")
```

For the two fake planner tests, pass the fake planner option:

```elixir
pipeline_planner: BrokenImagePlanner
```

and:

```elixir
pipeline_planner: RaisingAfterFirstChunkPlanner
```

Add one new plug-level success test:

```elixir
  test "processes a native path URL with cover and explicit output format" do
    conn = conn(:get, "/_/fit:cover/w:100/h:100/format:jpeg/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end
```

- [ ] **Step 2: Run plug tests to verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: failures because `ImagePlug.call/2` still expects parsers to return transform chains and still uses `conn.path_info` as the origin path.

- [ ] **Step 3: Wire ImagePlug through ProcessingRequest and PipelinePlanner**

In `lib/image_plug.ex`, add aliases:

```elixir
  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
```

Replace `call/2`, `fetch_origin/2`, and the parser wrapping helpers with:

```elixir
  def call(%Plug.Conn{} = conn, opts) do
    param_parser = Keyword.fetch!(opts, :param_parser)
    pipeline_planner = Keyword.get(opts, :pipeline_planner, PipelinePlanner)

    with {:ok, request} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, chain} <- pipeline_planner.plan(request) |> wrap_planner_error(),
         {:ok, origin_response} <- fetch_origin(request, opts) |> wrap_origin_error(),
         {:ok, image} <-
           Image.from_binary(origin_response.body, access: :random, fail_on: :error)
           |> wrap_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain) do
      send_image(conn, final_state, opts)
    else
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:planner, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)

      {:error, {:input_limit, error}} ->
        send_input_limit_error(conn, error)
    end
  end

  defp fetch_origin(%ProcessingRequest{source_kind: :plain, source_path: source_path}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    req_options = origin_req_options(opts)

    with {:ok, url} <- Origin.build_url(root_url, source_path) do
      Origin.fetch(url, req_options)
    end
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_planner_error({:error, _} = error), do: {:error, {:planner, error}}
  defp wrap_planner_error(result), do: result
```

The old `fetch_origin(%Plug.Conn{} = conn, opts)` function should be removed.

- [ ] **Step 4: Run plug tests to verify they pass**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs
```

Expected: all tests in `test/image_plug_test.exs` pass.

- [ ] **Step 5: Commit Task 4**

Run:

```bash
git add lib/image_plug.ex test/image_plug_test.exs
git commit -m "feat: wire native requests into image plug"
```

### Task 5: Remove TwicPics API Remnants

**Files:**
- Delete: `lib/image_plug/param_parser/twicpics.ex`
- Delete: `lib/image_plug/param_parser/twicpics/arithmetic_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/arithmetic_tokenizer.ex`
- Delete: `lib/image_plug/param_parser/twicpics/coordinates_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/formatters.ex`
- Delete: `lib/image_plug/param_parser/twicpics/kv_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/length_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/number_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/ratio_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/size_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/utils.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/contain_max_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/contain_min_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/contain_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/cover_max_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/cover_min_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/cover_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/crop_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/focus_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/inside_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/output_parser.ex`
- Delete: `lib/image_plug/param_parser/twicpics/transform/scale_parser.ex`
- Delete: `test/param_parser/twicpics_test.exs`
- Delete: `test/param_parser/twicpics_parser_test.exs`
- Delete: `test/param_parser/twicpics/arithmetic_tokenizer_test.exs`
- Delete: `test/param_parser/twicpics/kv_parser_test.exs`
- Delete: `test/param_parser/twicpics/utils_test.exs`

- [ ] **Step 1: Remove the old TwicPics parser and tests**

Run:

```bash
git rm lib/image_plug/param_parser/twicpics.ex
git rm -r lib/image_plug/param_parser/twicpics
git rm test/param_parser/twicpics_test.exs
git rm test/param_parser/twicpics_parser_test.exs
git rm -r test/param_parser/twicpics
```

Expected: all listed files are staged as deleted.

- [ ] **Step 2: Verify there are no TwicPics references in runtime code or tests**

Run:

```bash
rg -n "twic|TwicPics|Twicpics" lib test README.md
```

Expected: no matches.

- [ ] **Step 3: Run focused parser and plug tests**

Run:

```bash
mise exec -- mix test test/param_parser/native_test.exs test/image_plug/pipeline_planner_test.exs test/image_plug_test.exs
```

Expected: all focused native API tests pass.

- [ ] **Step 4: Commit Task 5**

Run:

```bash
git add -u lib/image_plug/param_parser test/param_parser
git commit -m "refactor: remove twicpics parser"
```

### Task 6: Make Native Parser The Default Public Surface

**Files:**
- Modify: `lib/simple_server.ex`
- Modify: `README.md`

- [ ] **Step 1: Update the simple server default parser**

In `lib/simple_server.ex`, change the forwarded plug options to:

```elixir
  forward "/",
    to: ImagePlug,
    init_opts: [
      root_url: "http://localhost:4000",
      param_parser: ImagePlug.ParamParser.Native
    ]
```

This makes local URLs match the native grammar directly:

```text
http://localhost:4000/_/fit:cover/w:300/h:300/plain/images/cat-300.jpg
```

- [ ] **Step 2: Rewrite the README API section**

Replace the transform section and usage example in `README.md` with:

````markdown
## Native Path API

ImagePlug's native API uses path-oriented URLs:

```text
/<signature>/<options>/plain/<origin_path>
```

For local development, the signature segment can be `_` or `unsafe`:

```text
/_/plain/images/cat-300.jpg
/_/w:300/plain/images/cat-300.jpg
/_/fit:cover/w:300/h:300/focus:center/format:auto/plain/images/cat-300.jpg
/_/fit:contain/w:800/format:webp/plain/images/cat-300.jpg
```

Options are declarative. Their order in the URL does not define processing order:

```text
/_/fit:cover/w:300/h:300/plain/images/cat-300.jpg
/_/h:300/w:300/fit:cover/plain/images/cat-300.jpg
```

Both URLs describe the same requested output. ImagePlug owns the fixed processing pipeline so it can optimize origin loading, resize, crop, and output encoding over time.

### Options

```text
w:<positive integer>
h:<positive integer>
fit:cover | fit:contain | fit:fill | fit:inside
focus:center | focus:top | focus:bottom | focus:left | focus:right | focus:<x>:<y>
format:auto | format:webp | format:avif | format:jpeg | format:png
```

`w` and `h` are pixel dimensions. `focus:<x>:<y>` accepts pixel values such as `focus:120:80` and percent values such as `focus:50p:25p`.

`format:auto` uses the request `Accept` header and sets `Vary: Accept` on image responses. Explicit formats bypass content negotiation.

## Usage example

```elixir
defmodule ImagePlug.SimpleServer do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: {:the_app_name, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  forward "/",
    to: ImagePlug,
    init_opts: [
      root_url: "http://localhost:4000",
      param_parser: ImagePlug.ParamParser.Native
    ]

  match _ do
    send_resp(conn, 404, "404 Not Found")
  end
end
```
````

Keep the existing "Operational Notes" section, but change its first sentence to:

```markdown
`ImagePlug` parses native path options before fetching the origin image. Invalid processing requests return `400` without origin traffic.
```

- [ ] **Step 3: Run README and simple server search checks**

Run:

```bash
rg -n "twic|TwicPics|transform=|param_parser: ImagePlug.ParamParser.Twicpics" README.md lib/simple_server.ex
```

Expected: no matches.

- [ ] **Step 4: Commit Task 6**

Run:

```bash
git add README.md lib/simple_server.ex
git commit -m "docs: document native path api"
```

### Task 7: Format, Compile, And Run Full Verification

**Files:**
- Modify only files changed by formatting if `mix format` updates them.

- [ ] **Step 1: Format changed Elixir files**

Run:

```bash
mise exec -- mix format lib/image_plug.ex lib/image_plug/param_parser.ex lib/image_plug/processing_request.ex lib/image_plug/param_parser/native.ex lib/image_plug/pipeline_planner.ex lib/simple_server.ex test/image_plug/processing_request_test.exs test/param_parser/native_test.exs test/image_plug/pipeline_planner_test.exs test/image_plug_test.exs
```

Expected: command exits 0.

- [ ] **Step 2: Compile with warnings as failures if the project supports it**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0. If the local Mix version does not support the flag, run `mise exec -- mix compile` and record the unsupported flag output in the task notes before continuing.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 4: Inspect git status**

Run:

```bash
git status --short
```

Expected: only implementation files from this plan are modified or untracked. Existing unrelated untracked files may still be present:

```text
?? docs/superpowers/plans/2026-04-28-fix-review-findings.md
?? priv/static/images/concert.jpeg
?? priv/static/images/woman.jpg
```

- [ ] **Step 5: Commit final formatting adjustments if needed**

If Step 1 changed files after the previous commits, run:

```bash
git add lib test README.md
git commit -m "chore: format native path api changes"
```

If Step 1 did not change files, skip this commit.

## Self-Review

Spec coverage:

- Native path grammar is implemented in Task 2.
- Product-neutral `ProcessingRequest` is implemented in Task 1.
- Fixed pipeline planning is implemented in Task 3.
- Plug-level origin fetch from parsed source path is implemented in Task 4.
- Invalid native requests fail before origin fetch in Task 4 tests.
- Old TwicPics parser modules and tests are removed in Task 5.
- Native API docs and default simple server configuration are implemented in Task 6.
- Signing, encrypted origins, streaming decode, filters, EXIF orientation, metadata controls, background controls, smart focus, and quality options remain outside this implementation and are preserved as future grammar/pipeline room.

Gap scan:

- Each code-changing step includes concrete code or exact replacement instructions.
- Each verification step includes exact commands and expected outcomes.

Type consistency:

- Parser output is consistently `ImagePlug.ProcessingRequest.t()`.
- Planner output is consistently the existing transform chain consumed by `ImagePlug.TransformChain`.
- Native parser field names match `ProcessingRequest`: `signature`, `source_kind`, `source_path`, `width`, `height`, `fit`, `focus`, and `format`.
