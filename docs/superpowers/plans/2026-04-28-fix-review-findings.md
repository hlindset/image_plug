# Fix Review Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the eight design review findings around request validation, transform failures, debug mutation, streaming, cover semantics, parser contracts, performance guardrails, and output negotiation.

**Architecture:** Keep `ImagePlug` as the Plug adapter, but move origin retrieval and output negotiation into focused modules. Keep the transform modules, but make the pipeline return explicit errors instead of sending partially transformed images. Keep the TwicPics parser for now, but make it an adapter behind a correct parser behaviour.

**Tech Stack:** Elixir 1.17 via `mise exec -- ...`, Plug, Req, Req.Test, Image, Vix/libvips, ExUnit.

---

## File Structure

- Create `lib/image_plug/origin.ex`: builds safe origin URLs and fetches image bytes with non-bang Req calls, status checks, content-type checks, redirect limits, receive timeout, and max body size enforcement while streaming the response body.
- Create `lib/image_plug/output_negotiation.ex`: parses `Accept`, applies q-values and wildcards, selects the best supported image MIME type, and maps MIME types to image suffixes.
- Modify `lib/image_plug.ex`: parse params before fetching, delegate origin fetch, decode errors, transform errors, output negotiation, `Vary: Accept`, and chunked streaming with pre-send encoder failure handling.
- Modify `lib/image_plug/param_parser.ex`: make the behaviour match the parser actually used by the Plug and fix transform parameter type references.
- Modify `lib/image_plug/transform_state.ex`: default `debug` to `false`.
- Modify `lib/image_plug/transform_chain.ex`: stop executing transforms after the first transform error.
- Modify `lib/image_plug/transform/focus.ex`: keep debug drawing opt-in through `TransformState.debug`.
- Modify `lib/image_plug/transform/cover.ex`: recompute/clamp the crop after constraint-aware scaling.
- Modify `lib/image_plug/transform/scale.ex`: use `Image.thumbnail/3` for proportional downscales and keep `Image.resize/2` for upscales or forced aspect-ratio changes.
- Modify `lib/image_plug/param_parser/twicpics/size_parser.ex` and warning-only parser files: clear existing compile warnings after the behaviour contract is fixed.
- Modify `test/test_helper.exs`: start Req.Test ownership support.
- Create `test/image_plug/origin_test.exs`: origin URL, status, content type, timeout/transport error, and max body tests.
- Create `test/image_plug/output_negotiation_test.exs`: q-value, wildcard, alpha/no-alpha, explicit format, and suffix tests.
- Modify `test/image_plug_test.exs`: end-to-end Plug tests for parse-before-fetch, origin errors, decode errors, transform errors, content negotiation headers, and streaming error handling.
- Modify `test/transform_chain_test.exs`: transform short-circuit behavior.
- Modify `test/param_parser/twicpics_test.exs`: parser behaviour smoke test through `parse/1`.

---

### Task 1: Align the Parser Behaviour Boundary

**Files:**
- Modify: `lib/image_plug/param_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics.ex`
- Modify: `test/param_parser/twicpics_test.exs`

- [ ] **Step 1: Run the behaviour warning check**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: FAIL with warnings that `ImagePlug.ParamParser.Twicpics.parse/1` is not a callback and `parse_chain/1` is not implemented.

- [ ] **Step 2: Replace the parser behaviour contract**

Replace the full contents of `lib/image_plug/param_parser.ex` with:

```elixir
defmodule ImagePlug.ParamParser do
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

  @type parse_error() ::
          {:invalid_params, transform_module(), String.t()}
          | {:invalid_transform, String.t()}
          | {:unexpected_char, keyword()}
          | {:expected_key, keyword()}
          | {:expected_value, keyword()}
          | {:strictly_positive_number_required, keyword()}

  @doc """
  Parse a transform chain from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, transform_chain()} | {:error, any()}

  @doc """
  Render parser-specific errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
```

- [ ] **Step 3: Add a parser behaviour smoke test**

Append this test to `test/param_parser/twicpics_test.exs`:

```elixir
  test "implements the parser behaviour used by the plug" do
    conn =
      Plug.Test.conn(
        :get,
        "/process/images/cat-300.jpg?twic=v1/resize=100/output=webp"
      )

    assert {:ok,
            [
              {Transform.Scale, %Transform.Scale.ScaleParams{}},
              {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
            ]} = Twicpics.parse(conn)
  end
```

- [ ] **Step 4: Run the targeted parser tests**

Run:

```bash
mise exec -- mix test test/param_parser/twicpics_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_plug/param_parser.ex test/param_parser/twicpics_test.exs
git commit -m "fix: align parser behaviour contract"
```

---

### Task 2: Make Transform Errors Explicit and Disable Debug Mutation

**Files:**
- Modify: `lib/image_plug/transform_state.ex`
- Modify: `lib/image_plug/transform_chain.ex`
- Modify: `test/transform_chain_test.exs`
- Modify: `test/param_parser/twicpics_test.exs`

- [ ] **Step 1: Add failing tests for debug mutation and short-circuiting**

Append this code to `test/transform_chain_test.exs`:

```elixir
  defmodule FailingTransform do
    defstruct []

    def execute(state, %__MODULE__{}) do
      ImagePlug.TransformState.add_error(state, {__MODULE__, :failed})
    end
  end

  defmodule UnexpectedTransform do
    defstruct []

    def execute(state, %__MODULE__{}) do
      ImagePlug.TransformState.add_error(state, {__MODULE__, :should_not_run})
    end
  end

  test "stops executing after the first transform error" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      {FailingTransform, %FailingTransform{}},
      {UnexpectedTransform, %UnexpectedTransform{}}
    ]

    assert {:error, {:transform_error, state}} =
             ImagePlug.TransformChain.execute(%ImagePlug.TransformState{image: image}, chain)

    assert state.errors == [{FailingTransform, :failed}]
  end
```

Append this code to `test/param_parser/twicpics_test.exs`:

```elixir
  test "focus does not draw a debug dot by default" do
    {:ok, image} = Image.new(20, 20, color: :white)

    result =
      %TransformState{image: image}
      |> Transform.Focus.execute(%Transform.Focus.FocusParams{type: {:anchor, :center, :center}})

    assert Image.get_pixel!(result.image, 10, 10) == [255, 255, 255]
    assert result.focus == {:anchor, :center, :center}
  end
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
mise exec -- mix test test/transform_chain_test.exs test/param_parser/twicpics_test.exs
```

Expected: FAIL because the chain records both transform errors and focus draws a red debug dot.

- [ ] **Step 3: Disable debug by default**

In `lib/image_plug/transform_state.ex`, change the struct from:

```elixir
  defstruct image: nil,
            focus: @default_focus,
            errors: [],
            output: :auto,
            debug: true
```

to:

```elixir
  defstruct image: nil,
            focus: @default_focus,
            errors: [],
            output: :auto,
            debug: false
```

- [ ] **Step 4: Replace transform-chain execution with short-circuiting**

Replace `execute/2` in `lib/image_plug/transform_chain.ex` with:

```elixir
  @spec execute(TransformState.t(), ParamParser.transform_chain()) ::
          {:ok, TransformState.t()} | {:error, {:transform_error, TransformState.t()}}
  def execute(%TransformState{} = state, transform_chain) do
    transform_chain
    |> Enum.reduce_while(state, fn {module, parameters}, state ->
      Logger.info(
        "executing transform: #{inspect(module)} with params #{inspect(parameters)}"
      )

      next_state = module.execute(state, parameters)

      case next_state do
        %TransformState{errors: []} -> {:cont, next_state}
        %TransformState{} -> {:halt, next_state}
      end
    end)
    |> case do
      %TransformState{errors: []} = state -> {:ok, state}
      %TransformState{} = state -> {:error, {:transform_error, state}}
    end
  end
```

- [ ] **Step 5: Run the targeted tests**

Run:

```bash
mise exec -- mix test test/transform_chain_test.exs test/param_parser/twicpics_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_plug/transform_state.ex lib/image_plug/transform_chain.ex test/transform_chain_test.exs test/param_parser/twicpics_test.exs
git commit -m "fix: stop transform pipeline on errors"
```

---

### Task 3: Add a Safe Origin Fetcher and Parse Before Fetching

**Files:**
- Create: `lib/image_plug/origin.ex`
- Modify: `lib/image_plug.ex`
- Modify: `test/test_helper.exs`
- Create: `test/image_plug/origin_test.exs`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Enable Req.Test cleanup**

Replace `test/test_helper.exs` with:

```elixir
ExUnit.start()
Application.ensure_all_started(:req)
```

- [ ] **Step 2: Add failing origin tests**

Create `test/image_plug/origin_test.exs` with:

```elixir
defmodule ImagePlug.OriginTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Origin

  setup do
    Req.Test.verify_on_exit!()
  end

  test "builds origin URLs from root and path segments" do
    assert Origin.build_url("https://img.example/base", ["images", "cat 1.jpg"]) ==
             {:ok, "https://img.example/base/images/cat%201.jpg"}
  end

  test "fetches image bodies with status and content-type validation" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "jpeg-bytes")
    end)

    assert {:ok, %Origin.Response{body: "jpeg-bytes", content_type: "image/jpeg"}} =
             Origin.fetch("http://origin.test/cat.jpg",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "rejects non-success status before reading a large body" do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 404, String.duplicate("x", 100))
    end)

    assert {:error, {:bad_status, 404}} =
             Origin.fetch("http://origin.test/missing.jpg",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "rejects non-image content types" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(200, "not an image")
    end)

    assert {:error, {:bad_content_type, "text/plain; charset=utf-8"}} =
             Origin.fetch("http://origin.test/file.txt",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "stops reading when the body exceeds the configured limit" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, "abcdef")
    end)

    assert {:error, {:body_too_large, 5}} =
             Origin.fetch("http://origin.test/cat.jpg",
               max_body_bytes: 5,
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end

  test "turns transport errors into tagged origin errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:transport, %Req.TransportError{reason: :timeout}}} =
             Origin.fetch("http://origin.test/cat.jpg",
               req_options: [plug: {Req.Test, __MODULE__}]
             )
  end
end
```

- [ ] **Step 3: Run the failing origin tests**

Run:

```bash
mise exec -- mix test test/image_plug/origin_test.exs
```

Expected: FAIL because `ImagePlug.Origin` does not exist.

- [ ] **Step 4: Implement the origin module**

Create `lib/image_plug/origin.ex` with:

```elixir
defmodule ImagePlug.Origin do
  @moduledoc false

  defmodule Response do
    @moduledoc false
    defstruct [:body, :content_type, :headers, :url]
  end

  @default_max_body_bytes 10_000_000
  @default_receive_timeout 5_000
  @default_max_redirects 3

  @type error ::
          {:bad_status, non_neg_integer()}
          | {:bad_content_type, String.t() | nil}
          | {:body_too_large, pos_integer()}
          | {:transport, Exception.t()}
          | {:timeout, pos_integer()}
          | {:invalid_root_url, String.t()}

  @spec build_url(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, error()}
  def build_url(root_url, path_info) when is_binary(root_url) and is_list(path_info) do
    case URI.parse(root_url) do
      %URI{scheme: scheme, host: host} = uri when scheme in ["http", "https"] and is_binary(host) ->
        encoded_path =
          path_info
          |> Enum.map(&URI.encode(&1, &URI.char_unreserved?/1))
          |> Enum.join("/")

        root_path = uri.path || ""
        joined_path = join_paths(root_path, encoded_path)

        {:ok, URI.to_string(%URI{uri | path: joined_path, query: nil, fragment: nil})}

      _other ->
        {:error, {:invalid_root_url, root_url}}
    end
  end

  @spec fetch(String.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def fetch(url, opts \\ []) when is_binary(url) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)
    receive_timeout = Keyword.get(opts, :receive_timeout, @default_receive_timeout)
    max_redirects = Keyword.get(opts, :max_redirects, @default_max_redirects)
    req_options = Keyword.get(opts, :req_options, [])

    request_options =
      Keyword.merge(
        [
          url: url,
          into: :self,
          retry: false,
          redirect: true,
          max_redirects: max_redirects,
          receive_timeout: receive_timeout
        ],
        req_options
      )

    case Req.get(request_options) do
      {:ok, %Req.Response{} = response} ->
        with :ok <- validate_status(response),
             {:ok, content_type} <- validate_content_type(response),
             {:ok, body} <- collect_body(response, max_body_bytes, receive_timeout) do
          {:ok,
           %Response{
             body: body,
             content_type: content_type,
             headers: response.headers,
             url: url
           }}
        end

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp join_paths(root_path, encoded_path) do
    [String.trim_trailing(root_path, "/"), encoded_path]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
    |> then(&("/" <> &1))
  end

  defp validate_status(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_status(%Req.Response{status: status}), do: {:error, {:bad_status, status}}

  defp validate_content_type(%Req.Response{headers: headers}) do
    content_type =
      headers
      |> Map.get("content-type", [])
      |> List.first()

    if is_binary(content_type) and String.starts_with?(content_type, "image/") do
      {:ok, content_type}
    else
      {:error, {:bad_content_type, content_type}}
    end
  end

  defp collect_body(response, max_body_bytes, receive_timeout) do
    do_collect_body(response, [], 0, max_body_bytes, receive_timeout)
  end

  defp do_collect_body(response, chunks, size, max_body_bytes, receive_timeout) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, events} ->
            case collect_events(events, chunks, size, max_body_bytes) do
              {:cont, chunks, size} ->
                do_collect_body(response, chunks, size, max_body_bytes, receive_timeout)

              {:done, chunks} ->
                {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

              {:error, {:body_too_large, _limit}} = error ->
                Req.cancel_async_response(response)
                error
            end

          {:error, exception} ->
            Req.cancel_async_response(response)
            {:error, {:transport, exception}}
        end
    after
      receive_timeout ->
        Req.cancel_async_response(response)
        {:error, {:timeout, receive_timeout}}
    end
  end

  defp collect_events(events, chunks, size, max_body_bytes) do
    Enum.reduce_while(events, {:cont, chunks, size}, fn
      {:data, data}, {:cont, chunks, size} ->
        new_size = size + byte_size(data)

        if new_size > max_body_bytes do
          {:halt, {:error, {:body_too_large, max_body_bytes}}}
        else
          {:cont, {:cont, [data | chunks], new_size}}
        end

      :done, {:cont, chunks, _size} ->
        {:halt, {:done, chunks}}

      _event, acc ->
        {:cont, acc}
    end)
  end
end
```

- [ ] **Step 5: Run the origin tests**

Run:

```bash
mise exec -- mix test test/image_plug/origin_test.exs
```

Expected: PASS.

- [ ] **Step 6: Add an end-to-end parse-before-fetch test**

Append this test to `test/image_plug_test.exs`:

```elixir
  defmodule OriginShouldNotBeCalled do
    def call(conn) do
      send(self(), :origin_was_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end
  end

  test "does not fetch origin when transform params are invalid" do
    conn =
      conn(
        :get,
        "/process/images/cat-300.jpg?twic=v1/resize=-x-"
      )

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end
```

- [ ] **Step 7: Modify `ImagePlug.call/2` to parse before origin fetch**

Replace `call/2` and `wrap_error/1` in `lib/image_plug.ex` with:

```elixir
  def call(%Plug.Conn{} = conn, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    param_parser = Keyword.fetch!(opts, :param_parser)

    with {:ok, chain} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, url} <- Origin.build_url(root_url, conn.path_info) |> wrap_origin_error(),
         {:ok, origin_response} <- fetch_origin(url, opts) |> wrap_origin_error(),
         {:ok, image} <- Image.from_binary(origin_response.body, access: :random, fail_on: :error) |> wrap_decode_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain) do
      send_image(conn, final_state)
    else
      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, reason}} ->
        send_origin_error(conn, reason)

      {:error, {:decode, reason}} ->
        send_decode_error(conn, reason)

      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)
    end
  end

  defp fetch_origin(url, opts) do
    Origin.fetch(url,
      max_body_bytes: Keyword.get(opts, :max_body_bytes, 10_000_000),
      receive_timeout: Keyword.get(opts, :origin_receive_timeout, 5_000),
      max_redirects: Keyword.get(opts, :origin_max_redirects, 3),
      req_options: Keyword.get(opts, :origin_req_options, [])
    )
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_origin_error({:error, reason}), do: {:error, {:origin, reason}}
  defp wrap_origin_error(result), do: result

  defp wrap_decode_error({:error, reason}), do: {:error, {:decode, reason}}
  defp wrap_decode_error(result), do: result
```

Add these aliases at the top of `lib/image_plug.ex`:

```elixir
  alias ImagePlug.Origin
```

Add these helper functions before `accepted_formats/1`:

```elixir
  defp send_origin_error(conn, {:bad_status, 404}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "origin image not found")
  end

  defp send_origin_error(conn, reason) do
    Logger.info("origin_error: #{inspect(reason)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "error fetching origin image")
  end

  defp send_decode_error(conn, reason) do
    Logger.info("decode_error: #{inspect(reason)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(415, "origin response is not a supported image")
  end

  defp send_transform_error(conn, errors) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image transform: #{inspect(Enum.reverse(errors))}")
  end
```

- [ ] **Step 8: Run the Plug tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/image_plug/origin_test.exs
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/image_plug.ex lib/image_plug/origin.ex test/test_helper.exs test/image_plug/origin_test.exs test/image_plug_test.exs
git commit -m "fix: validate requests before fetching origin"
```

---

### Task 4: Fix Output Negotiation and Safer Chunked Streaming

**Files:**
- Create: `lib/image_plug/output_negotiation.ex`
- Modify: `lib/image_plug.ex`
- Create: `test/image_plug/output_negotiation_test.exs`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Add failing output negotiation tests**

Create `test/image_plug/output_negotiation_test.exs` with:

```elixir
defmodule ImagePlug.OutputNegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputNegotiation

  test "uses q-values before server priority" do
    assert OutputNegotiation.negotiate("image/webp;q=0.4,image/avif;q=0.9", false) ==
             {:ok, "image/avif"}
  end

  test "uses server priority when q-values tie" do
    assert OutputNegotiation.negotiate("image/webp,image/avif", false) ==
             {:ok, "image/avif"}
  end

  test "supports image wildcard" do
    assert OutputNegotiation.negotiate("image/*;q=0.8", false) == {:ok, "image/avif"}
  end

  test "supports global wildcard" do
    assert OutputNegotiation.negotiate("*/*;q=0.8", true) == {:ok, "image/avif"}
  end

  test "excludes formats with q zero" do
    assert OutputNegotiation.negotiate("image/avif;q=0,image/webp;q=1", false) ==
             {:ok, "image/webp"}
  end

  test "falls back to png for alpha when modern formats are not accepted" do
    assert OutputNegotiation.negotiate("image/jpeg", true) == {:ok, "image/png"}
  end

  test "falls back to jpeg for non-alpha when modern formats are not accepted" do
    assert OutputNegotiation.negotiate("image/png;q=0", false) == {:ok, "image/jpeg"}
  end

  test "maps mime types to suffixes" do
    assert OutputNegotiation.suffix!("image/avif") == ".avif"
    assert OutputNegotiation.suffix!("image/webp") == ".webp"
    assert OutputNegotiation.suffix!("image/jpeg") == ".jpg"
    assert OutputNegotiation.suffix!("image/png") == ".png"
  end
end
```

- [ ] **Step 2: Run the failing negotiation tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_negotiation_test.exs
```

Expected: FAIL because `ImagePlug.OutputNegotiation` does not exist.

- [ ] **Step 3: Implement output negotiation**

Create `lib/image_plug/output_negotiation.ex` with:

```elixir
defmodule ImagePlug.OutputNegotiation do
  @moduledoc false

  @alpha_format_priority ~w(image/avif image/webp image/png)
  @no_alpha_format_priority ~w(image/avif image/webp image/jpeg)
  @default_quality 1.0

  @spec negotiate(String.t() | nil, boolean()) :: {:ok, String.t()}
  def negotiate(accept_header, has_alpha?) do
    priorities = if has_alpha?, do: @alpha_format_priority, else: @no_alpha_format_priority
    accepted = parse_accept(accept_header)

    selected =
      priorities
      |> Enum.with_index()
      |> Enum.map(fn {mime, index} -> {mime, quality_for(mime, accepted), index} end)
      |> Enum.filter(fn {_mime, quality, _index} -> quality > 0 end)
      |> Enum.max_by(fn {_mime, quality, index} -> {quality, -index} end, fn -> {List.last(priorities), @default_quality, 999} end)
      |> elem(0)

    {:ok, selected}
  end

  @spec suffix!(String.t()) :: String.t()
  def suffix!("image/avif"), do: ".avif"
  def suffix!("image/webp"), do: ".webp"
  def suffix!("image/jpeg"), do: ".jpg"
  def suffix!("image/png"), do: ".png"

  defp parse_accept(nil), do: [{"*/*", @default_quality, 0}]
  defp parse_accept(""), do: [{"*/*", @default_quality, 0}]

  defp parse_accept(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.with_index()
    |> Enum.map(fn {part, index} ->
      [media_range | params] =
        part
        |> String.trim()
        |> String.split(";")
        |> Enum.map(&String.trim/1)

      quality =
        params
        |> Enum.find_value(@default_quality, fn
          "q=" <> value ->
            case Float.parse(value) do
              {q, ""} when q >= 0 and q <= 1 -> q
              _other -> 0.0
            end

          _param ->
            nil
        end)

      {String.downcase(media_range), quality, index}
    end)
  end

  defp quality_for(mime, accepted) do
    accepted
    |> Enum.filter(fn {range, _quality, _index} -> matches?(range, mime) end)
    |> Enum.max_by(fn {_range, quality, index} -> {quality, -index} end, fn -> {mime, @default_quality, 999} end)
    |> elem(1)
  end

  defp matches?(range, mime) do
    case String.split(range, "/") do
      ["*", "*"] ->
        true

      ["image", "*"] ->
        String.starts_with?(mime, "image/")

      [type, subtype] ->
        range == mime and type != "" and subtype != ""

      _other ->
        false
    end
  end
end
```

- [ ] **Step 4: Wire negotiation into `ImagePlug`**

In `lib/image_plug.ex`, remove `@alpha_format_priority`, `@no_alpha_format_priority`, `accepted_formats/1`, `mime_type_to_suffix/1`, and `resolve_auto_format/2`.

Add this alias:

```elixir
  alias ImagePlug.OutputNegotiation
```

Replace MIME selection in `send_image/2` with:

```elixir
    mime_type =
      case state.output do
        :auto ->
          accept_header =
            conn
            |> get_req_header("accept")
            |> Enum.join(",")

          {:ok, negotiated} = OutputNegotiation.negotiate(accept_header, Image.has_alpha?(state.image))
          negotiated

        format when is_atom(format) ->
          "image/#{format}"
      end

    suffix = OutputNegotiation.suffix!(mime_type)
```

Add `Vary: Accept` to encoded image responses by changing:

```elixir
      |> put_resp_content_type(mime_type, nil)
      |> send_chunked(200)
```

to:

```elixir
      |> put_resp_header("vary", "accept")
      |> put_resp_content_type(mime_type, nil)
      |> send_chunked(200)
```

- [ ] **Step 5: Make initial encoder failure happen before headers are sent**

Replace the chunking section in `send_image/2` with:

```elixir
    try do
      state.image
      |> Image.stream!(suffix: suffix)
      |> Enum.reduce_while({:pending, conn}, fn data, acc ->
        case acc do
          {:pending, conn} ->
            conn =
              conn
              |> put_resp_header("vary", "accept")
              |> put_resp_content_type(mime_type, nil)
              |> send_chunked(200)

            case chunk(conn, data) do
              {:ok, conn} -> {:cont, {:sent, conn}}
              {:error, :closed} -> {:halt, {:sent, conn}}
            end

          {:sent, conn} ->
            case chunk(conn, data) do
              {:ok, conn} -> {:cont, {:sent, conn}}
              {:error, :closed} -> {:halt, {:sent, conn}}
            end
        end
      end)
      |> case do
        {:pending, conn} ->
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "error encoding image")

        {:sent, conn} ->
          conn
      end
    rescue
      exception ->
        Logger.info("encode_error: #{Exception.message(exception)}")

        if conn.state in [:unset, :set] do
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(500, "error encoding image")
        else
          conn
        end
    end
```

- [ ] **Step 6: Run negotiation and Plug tests**

Run:

```bash
mise exec -- mix test test/image_plug/output_negotiation_test.exs test/image_plug_test.exs
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_plug.ex lib/image_plug/output_negotiation.ex test/image_plug/output_negotiation_test.exs test/image_plug_test.exs
git commit -m "fix: negotiate output format safely"
```

---

### Task 5: Fix `cover-max` Crop Semantics

**Files:**
- Modify: `lib/image_plug/transform/cover.ex`
- Modify: `test/param_parser/twicpics_test.exs`

- [ ] **Step 1: Add failing cover-max semantics tests**

Append this code to `test/param_parser/twicpics_test.exs`:

```elixir
  test "cover-max does not request a crop larger than the unscaled image" do
    {:ok, image} = Image.new(100, 100, color: :white)

    state =
      Transform.Cover.execute(%TransformState{image: image}, %Transform.Cover.CoverParams{
        type: :dimensions,
        width: {:pixels, 200},
        height: {:pixels, 200},
        constraint: :max
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 100}
  end

  test "cover-max preserves requested ratio when it cannot upscale" do
    {:ok, image} = Image.new(100, 100, color: :white)

    state =
      Transform.Cover.execute(%TransformState{image: image}, %Transform.Cover.CoverParams{
        type: :dimensions,
        width: {:pixels, 200},
        height: {:pixels, 100},
        constraint: :max
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 50}
  end
```

- [ ] **Step 2: Run the failing cover tests**

Run:

```bash
mise exec -- mix test test/param_parser/twicpics_test.exs
```

Expected: FAIL on `cover-max` because the crop can be larger than the actual image after scaling is skipped.

- [ ] **Step 3: Recompute crop dimensions after constraint-aware scaling**

In `lib/image_plug/transform/cover.ex`, replace the dimensions branch of `execute/2` with:

```elixir
  @impl ImagePlug.Transform
  def execute(
        %TransformState{} = state,
        %CoverParams{
          type: :dimensions,
          width: width,
          height: height,
          constraint: constraint
        }
      ) do
    {requested_crop_width, requested_crop_height} = resolve_auto_size(state, width, height)
    {resize_width, resize_height} = fit_cover(state, requested_crop_width, requested_crop_height)

    with {:ok, resized_state} <- maybe_scale(state, resize_width, resize_height, constraint),
         {crop_width, crop_height} <-
           fit_crop_to_image(
             requested_crop_width,
             requested_crop_height,
             image_width(resized_state),
             image_height(resized_state)
           ),
         {left, top} <- crop_origin(resized_state, crop_width, crop_height),
         {:ok, cropped_state} <- do_crop(resized_state, left, top, crop_width, crop_height) do
      reset_focus(cropped_state)
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end
```

Add these private helpers below `fit_cover/3`:

```elixir
  defp fit_crop_to_image(crop_width, crop_height, image_width, image_height) do
    scale = min(1.0, min(image_width / crop_width, image_height / crop_height))

    {
      max(1, round(crop_width * scale)),
      max(1, round(crop_height * scale))
    }
  end

  defp crop_origin(%TransformState{} = state, crop_width, crop_height) do
    resized_width = image_width(state)
    resized_height = image_height(state)
    {center_x, center_y} = anchor_to_scale_units(state.focus, resized_width, resized_height)

    scaled_center_x = to_pixels(resized_width, center_x)
    scaled_center_y = to_pixels(resized_height, center_y)

    left = max(0, min(resized_width - crop_width, round(scaled_center_x - crop_width / 2)))
    top = max(0, min(resized_height - crop_height, round(scaled_center_y - crop_height / 2)))

    {left, top}
  end
```

- [ ] **Step 4: Run cover tests**

Run:

```bash
mise exec -- mix test test/param_parser/twicpics_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_plug/transform/cover.ex test/param_parser/twicpics_test.exs
git commit -m "fix: clamp cover crop after max constraint"
```

---

### Task 6: Add Image Size Guardrails and Proportional Downscale Optimization

**Files:**
- Modify: `lib/image_plug.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `test/image_plug_test.exs`
- Modify: `test/param_parser/twicpics_test.exs`

- [ ] **Step 1: Add failing guardrail and scale tests**

Append this test to `test/image_plug_test.exs`:

```elixir
  test "rejects decoded images above the configured pixel limit" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end)

    conn =
      conn(:get, "/process/images/large.png?twic=v1/resize=10")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        max_input_pixels: 399,
        origin_req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert conn.status == 413
    assert conn.resp_body == "origin image is too large"
  end
```

Append this test to `test/param_parser/twicpics_test.exs`:

```elixir
  test "scale proportional downscale returns exact target dimensions" do
    {:ok, image} = Image.new(400, 200, color: :white)

    state =
      Transform.Scale.execute(%TransformState{image: image}, %Transform.Scale.ScaleParams{
        type: :dimensions,
        width: {:pixels, 100},
        height: :auto
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 50}
  end
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/param_parser/twicpics_test.exs
```

Expected: FAIL because `max_input_pixels` is not enforced.

- [ ] **Step 3: Enforce decoded pixel limits in `ImagePlug`**

In `lib/image_plug.ex`, insert this `with` step immediately after `Image.from_binary(...) |> wrap_decode_error()`:

```elixir
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error(),
```

Add these helper functions before `send_origin_error/2`:

```elixir
  defp validate_input_image(image, opts) do
    max_input_pixels = Keyword.get(opts, :max_input_pixels, 40_000_000)
    pixel_count = Image.width(image) * Image.height(image)

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, reason}), do: {:error, {:input_limit, reason}}
```

Add this `else` branch in `call/2`:

```elixir
      {:error, {:input_limit, reason}} ->
        send_input_limit_error(conn, reason)
```

Add this helper:

```elixir
  defp send_input_limit_error(conn, reason) do
    Logger.info("input_limit_error: #{inspect(reason)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "origin image is too large")
  end
```

- [ ] **Step 4: Use thumbnail for proportional downscales**

In `lib/image_plug/transform/scale.ex`, replace `do_scale/3` with:

```elixir
  def do_scale(%TransformState{} = state, width, :auto) do
    target_height = round(width / image_width(state) * image_height(state))
    proportional_scale(state, width, target_height)
  end

  def do_scale(%TransformState{} = state, :auto, height) do
    target_width = round(height / image_height(state) * image_width(state))
    proportional_scale(state, target_width, height)
  end

  def do_scale(%TransformState{} = state, width, height) do
    if proportional?(state, width, height) and downscale?(state, width, height) do
      proportional_scale(state, width, height)
    else
      width_scale = width / image_width(state)
      height_scale = height / image_height(state)
      Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end
```

Add these helpers below `do_scale/3`:

```elixir
  defp proportional_scale(%TransformState{} = state, width, height) do
    if downscale?(state, width, height) do
      Image.thumbnail(state.image, "#{width}x#{height}", fit: :contain, resize: :down)
    else
      width_scale = width / image_width(state)
      Image.resize(state.image, width_scale)
    end
  end

  defp proportional?(%TransformState{} = state, width, height) do
    original_ratio = image_width(state) / image_height(state)
    target_ratio = width / height
    abs(original_ratio - target_ratio) < 0.001
  end

  defp downscale?(%TransformState{} = state, width, height) do
    width < image_width(state) and height < image_height(state)
  end
```

- [ ] **Step 5: Run guardrail and transform tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs test/param_parser/twicpics_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_plug.ex lib/image_plug/transform/scale.ex test/image_plug_test.exs test/param_parser/twicpics_test.exs
git commit -m "fix: enforce image limits and optimize downscales"
```

---

### Task 7: Clear Existing Compile Warnings

**Files:**
- Modify: `lib/image_plug/utils.ex`
- Modify: `lib/image_plug/transform.ex`
- Modify: `lib/image_plug/transform/crop.ex`
- Modify: `lib/image_plug/transform/contain.ex`
- Modify: `lib/image_plug/transform/cover.ex`
- Modify: `lib/image_plug/transform/focus.ex`
- Modify: `lib/image_plug/transform/scale.ex`
- Modify: `lib/image_plug/param_parser/twicpics/formatters.ex`
- Modify: `lib/image_plug/param_parser/twicpics/size_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/contain_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/contain_min_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/contain_max_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/cover_min_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/cover_max_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/output_parser.ex`
- Modify: `lib/image_plug/param_parser/twicpics/transform/scale_parser.ex`

- [ ] **Step 1: Run warnings-as-errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: FAIL with unused variable/alias warnings and the `unexpected_value_error/2` warning from `SizeParser`.

- [ ] **Step 2: Remove unused variables in `ImagePlug.Utils`**

In `lib/image_plug/utils.ex`, change the three `resolve_auto_size/3` heads to:

```elixir
  def resolve_auto_size(%TransformState{} = state, width, :auto) do
    aspect_ratio = image_height(state) / image_width(state)
    auto_height = round(to_pixels(image_width(state), width) * aspect_ratio)
    {to_pixels(image_width(state), width), auto_height}
  end

  def resolve_auto_size(%TransformState{} = state, :auto, height) do
    aspect_ratio = image_width(state) / image_height(state)
    auto_width = round(to_pixels(image_height(state), height) * aspect_ratio)
    {auto_width, to_pixels(image_height(state), height)}
  end

  def resolve_auto_size(%TransformState{} = state, width, height) do
    {to_pixels(image_width(state), width), to_pixels(image_height(state), height)}
  end
```

- [ ] **Step 3: Fix the invalid `unexpected_value_error` call**

In `lib/image_plug/param_parser/twicpics/size_parser.ex`, change:

```elixir
        Utils.unexpected_value_error(pos_offset + 2, expected: ["(", "[0-9]", found: "-"])
```

to:

```elixir
        Utils.unexpected_value_error(pos_offset + 2, ["(", "[0-9]"], "-")
```

- [ ] **Step 4: Remove unused aliases and variables**

Make these exact edits:

```elixir
# lib/image_plug/transform.ex
defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState

  @callback execute(TransformState.t(), struct()) :: TransformState.t()
end
```

```elixir
# lib/image_plug/transform/focus.ex
# Remove: alias ImagePlug.Transform
# Change the anchor head to:
  def execute(%TransformState{} = state, %FocusParams{type: {:anchor, x, y}}) do
```

```elixir
# lib/image_plug/transform/contain.ex
# Remove: alias ImagePlug.Transform
# Change the false letterbox head to:
  defp maybe_add_letterbox(%TransformState{} = state, false, _width, _height), do: {:ok, state}
```

```elixir
# lib/image_plug/transform/cover.ex
# Remove: alias ImagePlug.Transform
# Remove unused `= params` bindings from execute heads.
```

```elixir
# lib/image_plug/transform/scale.ex
# Remove: alias ImagePlug.Transform
# Remove unused `= params` binding from dimensions_for_scale_type/2.
```

```elixir
# lib/image_plug/transform/crop.ex
# Remove: alias ImagePlug.Transform
# In anchor_crop_to_pixels/6, change `%TransformState{} = state` to `%TransformState{}` in the explicit-coordinate head.
```

```elixir
# lib/image_plug/param_parser/twicpics/formatters.ex
# Change `opts` to `_opts` in the expected_value format_msg head.
```

```elixir
# Parser transform files
# Remove unused `RatioParser`, `CoordinatesParser`, `Dimensions`, and `AspectRatio` aliases reported by the compiler.
```

- [ ] **Step 5: Run warnings-as-errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [ ] **Step 6: Run all tests**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_plug/utils.ex lib/image_plug/transform.ex lib/image_plug/transform/crop.ex lib/image_plug/transform/contain.ex lib/image_plug/transform/cover.ex lib/image_plug/transform/focus.ex lib/image_plug/transform/scale.ex lib/image_plug/param_parser/twicpics/formatters.ex lib/image_plug/param_parser/twicpics/size_parser.ex lib/image_plug/param_parser/twicpics/transform/contain_parser.ex lib/image_plug/param_parser/twicpics/transform/contain_min_parser.ex lib/image_plug/param_parser/twicpics/transform/contain_max_parser.ex lib/image_plug/param_parser/twicpics/transform/cover_min_parser.ex lib/image_plug/param_parser/twicpics/transform/cover_max_parser.ex lib/image_plug/param_parser/twicpics/transform/output_parser.ex lib/image_plug/param_parser/twicpics/transform/scale_parser.ex
git commit -m "chore: clear compile warnings"
```

---

### Task 8: Final Verification and Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README usage notes**

Add this section after the current usage example in `README.md`:

```markdown
## Operational Notes

`ImagePlug` parses transform parameters before fetching the origin image. Invalid transform requests return `400` without origin traffic.

Origin fetches use non-bang Req calls with bounded redirects, receive timeout, image content-type validation, and a maximum response body size. Configure these with `:origin_max_redirects`, `:origin_receive_timeout`, `:max_body_bytes`, and `:max_input_pixels`.

Automatic output format selection uses the request `Accept` header and sets `Vary: Accept` on image responses. Explicit `output=<format>` values bypass content negotiation.
```

- [ ] **Step 2: Run all tests**

Run:

```bash
mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 3: Run compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [ ] **Step 4: Inspect final diff**

Run:

```bash
git diff --stat HEAD
```

Expected: output includes only the files listed in this plan plus generated directory entries for the new tests and modules.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document image plug operational limits"
```

---

## Self-Review

**Spec coverage:**

- Finding 1 is covered by Task 3: parsing happens before origin fetch, `Req.get!` is removed, origin fetches use non-bang calls, redirects/timeouts/status/content-type/body limits are handled.
- Finding 2 is covered by Task 2 and Task 3: transform chain short-circuits and `ImagePlug` returns `422` instead of a successful image.
- Finding 3 is covered by Task 2: `debug` defaults to `false` and a pixel test verifies focus no longer mutates output.
- Finding 4 is covered by Task 4: output streaming delays header commit until the first encoded chunk and rescues initial encoder failures.
- Finding 5 is covered by Task 5: `cover-max` clamps crop dimensions after constraint-aware scaling.
- Finding 6 is covered by Task 1 and Task 7: parser behaviour and transform parameter types match implementation.
- Finding 7 is covered by Task 3 and Task 6: source bytes, decoded pixels, and proportional downscales have explicit handling.
- Finding 8 is covered by Task 4: q-values, wildcards, format priorities, suffix mapping, and `Vary: Accept` are implemented and tested.

**Placeholder scan:** The plan contains no `TBD`, no unbound “add validation” steps, and no unnamed test requests. Each code-changing task includes the code to add or replace.

**Type consistency:** New modules are referenced as `ImagePlug.Origin`, `ImagePlug.Origin.Response`, and `ImagePlug.OutputNegotiation` consistently. Parser callback is `parse/1` everywhere. Transform param type names match existing structs: `CropParams`, `FocusParams`, `ScaleParams`, `ContainParams`, `CoverParams`, and `OutputParams`.
