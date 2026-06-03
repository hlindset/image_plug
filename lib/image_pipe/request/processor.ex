defmodule ImagePipe.Request.Processor do
  @moduledoc false

  alias Image.Options.Open, as: ImageOpenOptions
  alias ImagePipe.Error
  alias ImagePipe.Plan
  alias ImagePipe.Request.Options
  alias ImagePipe.Request.SourceFormat
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @type source_format() :: SourceFormat.source_format()
  @type decoded() :: %{
          required(:decode_options) => keyword(),
          required(:image) => VipsImage.t(),
          required(:source_format) => source_format(),
          optional(:source_response) => Source.Response.t(),
          optional(:source_dimensions) => {pos_integer(), pos_integer()} | nil,
          optional(:original_dims) => {pos_integer(), pos_integer()},
          optional(:achieved_shrink) => %{w: float(), h: float()} | nil
        }

  @spec process_source(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_source(%Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
    with {:ok, decoded} <-
           fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
      process_decoded_source(decoded, plan, opts)
    end
  end

  @spec fetch_decode_validate_source_with_source_format(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, decoded()} | {:error, term()}
  def fetch_decode_validate_source_with_source_format(
        %Plan{} = plan,
        %Source.Resolved{} = resolved_source,
        opts
      ) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    Telemetry.span(telemetry_opts, [:source, :fetch_decode], %{}, fn ->
      result =
        with {:ok, %Source.Response{} = source_response} <-
               Source.fetch(resolved_source, opts, Options.source_runtime_opts(opts)) do
          decode_validate_source_response(source_response, plan, opts)
        end

      {result, fetch_decode_stop_metadata(result)}
    end)
  end

  @spec decode_validate_source_response(Source.Response.t(), Plan.t(), keyword()) ::
          {:ok, decoded()} | {:error, term()}
  def decode_validate_source_response(%Source.Response{} = source_response, %Plan{} = plan, opts) do
    operations = first_pipeline_operations(plan)

    with {:ok, input} <- seekable_input(source_response),
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> prefer_source_body_limit(source_response)
           |> prefer_source_stream_error(source_response)
           |> wrap_decode_error(),
         {:ok, source_format} <- SourceFormat.from_image(header_image),
         original_dims = {Image.width(header_image), Image.height(header_image)},
         :ok <- validate_original_pixels(original_dims, opts) |> wrap_input_limit_error(),
         decode_options =
           DecodePlanner.open_options(
             operations,
             source_format,
             original_dims,
             exif_quarter_turn?(header_image),
             plan.auto_rotate
           ),
         {:ok, image} <-
           open_seekable_input(input, decode_options, opts)
           |> prefer_source_body_limit(source_response)
           |> prefer_source_stream_error(source_response)
           |> wrap_decode_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format,
         source_response: source_response,
         source_dimensions: shrink_source_dimensions(decode_options, original_dims),
         original_dims: original_dims,
         achieved_shrink: compute_achieved_shrink(original_dims, image)
       }}
    end
  end

  # The residual resize sizes against the exact original extent — but only when the
  # decode was actually shrunk. With no shrink the transform layer reads the live
  # image dims instead (which also keeps a crop-before-resize correct), so we leave
  # it `nil`. These are the stored (pre-orientation) dims; `AutoOrient` swaps them
  # in step if it rotates, and shrink is declined when a crop/quarter-turn rotate
  # precedes the resize, so they cannot go stale.
  defp shrink_source_dimensions(decode_options, original_dims) do
    if Keyword.has_key?(decode_options, :shrink) or Keyword.has_key?(decode_options, :scale) do
      original_dims
    else
      nil
    end
  end

  @spec process_decoded_source(decoded(), Plan.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_decoded_source(
        %{image: image} = decoded,
        %Plan{} = plan,
        opts
      ) do
    source_response = Map.get(decoded, :source_response)
    source_dimensions = Map.get(decoded, :source_dimensions)

    initial_state = %State{image: image, source_dimensions: source_dimensions}

    Telemetry.span(Telemetry.telemetry_opts(opts), [:transform, :execute], %{}, fn ->
      result =
        with {:ok, final_state} <-
               execute_plan_pipelines(initial_state, plan, opts),
             {:ok, final_state} <-
               materialize_before_delivery(final_state, opts, source_response),
             :ok <- validate_result_image(final_state.image, opts) do
          {:ok, final_state}
        end

      {result, transform_stop_metadata(result)}
    end)
  end

  defp execute_plan_pipelines(%State{} = state, %Plan{pipelines: pipelines} = plan, opts) do
    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, &execute_plan_pipeline_step(&1, &2, plan, opts))
    |> classify_materialize_error()
  end

  defp classify_materialize_error({:error, {:materialize_error, reason}}),
    do: {:error, {:decode, reason}}

  defp classify_materialize_error(result), do: result

  defp execute_plan_pipeline_step(
         {pipeline, index},
         {:ok, %State{} = state},
         %Plan{} = plan,
         opts
       ) do
    opts = Keyword.put(opts, :seed_orientation, index == 0)

    case Transform.execute_plan(%Plan{plan | pipelines: [pipeline]}, state, opts) do
      {:ok, %State{} = state} -> {:cont, {:ok, state}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp first_pipeline_operations(%Plan{
         pipelines: [%ImagePipe.Plan.Pipeline{operations: operations} | _rest]
       }),
       do: operations

  defp seekable_input(%Source.Response{path: path, stream: nil}) when is_binary(path),
    do: {:ok, {:path, path}}

  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  end

  defp seekable_input(%Source.Response{}), do: {:error, {:source, :invalid_adapter_result}}

  # A file path opens through `Image.open/2`, which routes to the libvips file loader and
  # preserves loader options (including `:access`).
  defp open_seekable_input({:path, path}, decode_options, opts) do
    case Keyword.get(opts, :image_open_module) do
      nil -> Image.open(path, decode_options)
      module -> module.open(path, decode_options)
    end
  end

  # A drained buffer opens through the libvips buffer loader directly via `new_from_buffer/2`.
  # We do NOT use `Image.open/2` (a binary matching no image signature is misrouted as a
  # filesystem path) nor `Image.from_binary/2` (it strips `:access`, silently downgrading the
  # planner's `:sequential` selection to libvips' random default). Validating the open options
  # the same way the `image` library does, then calling `new_from_buffer/2`, detects the format
  # from the bytes for any supported format AND carries `:access`/`fail_on:` through to libvips.
  # The buffer loader is injectable so tests can observe the options libvips actually receives.
  defp open_seekable_input({:buffer, binary}, decode_options, opts) do
    case Keyword.get(opts, :image_open_module) do
      nil -> open_buffer(binary, decode_options, opts)
      module -> module.open(binary, decode_options)
    end
  end

  defp open_buffer(binary, decode_options, opts) do
    loader = Keyword.get(opts, :buffer_loader, &VipsImage.new_from_buffer/2)

    with {:ok, vips_opts} <- ImageOpenOptions.validate_options(decode_options) do
      loader.(binary, vips_opts)
    end
  end

  defp materialize_before_delivery(%State{} = state, opts, source_response) do
    result =
      if state.materialized? do
        {:ok, state}
      else
        materialize_state(state, opts)
      end

    handle_materialization_result(result, source_response)
  end

  defp materialize_state(%State{} = state, opts) do
    materializer = Keyword.get(opts, :image_materializer, Materializer)

    materializer.materialize(state, opts)
  end

  defp handle_materialization_result(result, source_response) do
    result
    |> prefer_source_body_limit(source_response)
    |> prefer_source_stream_error(source_response)
    |> do_handle_materialization_result()
  end

  defp do_handle_materialization_result({:error, {:source, _reason} = error}), do: {:error, error}

  defp do_handle_materialization_result({:error, {:config, _reason} = error}), do: {:error, error}

  defp do_handle_materialization_result({:error, materialize_error}),
    do: {:error, {:decode, materialize_error}}

  defp do_handle_materialization_result({:ok, %State{} = state}), do: {:ok, state}

  defp wrap_decode_error({:error, {:source, _reason}} = error), do: error
  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  defp prefer_source_body_limit(result, %Source.Response{} = source_response) do
    case Source.body_limit_exceeded?(source_response) do
      true -> {:error, {:source, :body_too_large}}
      false -> result
    end
  end

  defp prefer_source_body_limit(result, _source_response), do: result

  defp prefer_source_stream_error({:error, reason}, %Source.Response{} = source_response) do
    case Source.stream_error_reason(source_response) do
      {:ok, reason} -> {:error, {:source, reason}}
      :error -> {:error, reason}
    end
  end

  defp prefer_source_stream_error(result, _source_response), do: result

  # Whether the source's EXIF orientation implies a 90°/270° turn. The decode
  # planner uses this (together with the presence of an AutoOrient step in the
  # chain) to decide whether the shrink axes must be swapped. Reading the header
  # value stays here because only the Request layer holds the decoded image; the
  # orientation *policy* lives in the planner.
  defp exif_quarter_turn?(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, v} when v in [5, 6, 7, 8] -> true
      _ -> false
    end
  end

  defp validate_original_pixels({w, h}, opts) do
    max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
    pixel_count = w * h

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp compute_achieved_shrink({orig_w, orig_h}, image) do
    loaded_w = Image.width(image)
    loaded_h = Image.height(image)
    %{w: max(1.0, orig_w / loaded_w), h: max(1.0, orig_h / loaded_h)}
  end

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

  defp validate_result_image(image, opts) do
    width = Image.width(image)
    height = Image.height(image)
    pixels = width * height

    with :ok <- check_result_width(width, Keyword.fetch!(opts, :max_result_width)),
         :ok <- check_result_height(height, Keyword.fetch!(opts, :max_result_height)) do
      check_result_pixels(pixels, Keyword.fetch!(opts, :max_result_pixels))
    end
  end

  defp check_result_width(width, max_width) when width <= max_width, do: :ok

  defp check_result_width(width, max_width),
    do: {:error, {:result_limit, {:result_width_too_large, width, max_width}}}

  defp check_result_height(height, max_height) when height <= max_height, do: :ok

  defp check_result_height(height, max_height),
    do: {:error, {:result_limit, {:result_height_too_large, height, max_height}}}

  defp check_result_pixels(pixels, max_pixels) when pixels <= max_pixels, do: :ok

  defp check_result_pixels(pixels, max_pixels),
    do: {:error, {:result_limit, {:too_many_result_pixels, pixels, max_pixels}}}

  defp fetch_decode_stop_metadata(
         {:ok, %{image: image, decode_options: decode_options} = decoded}
       ) do
    load_option =
      cond do
        Keyword.has_key?(decode_options, :shrink) ->
          {:shrink, Keyword.fetch!(decode_options, :shrink)}

        Keyword.has_key?(decode_options, :scale) ->
          {:scale, Keyword.fetch!(decode_options, :scale)}

        true ->
          nil
      end

    %{
      result: :ok,
      load_option: load_option,
      achieved_shrink: Map.get(decoded, :achieved_shrink),
      original_dims: Map.get(decoded, :original_dims),
      loaded_dims: {Image.width(image), Image.height(image)}
    }
  end

  defp fetch_decode_stop_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}

  defp fetch_decode_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}
end
