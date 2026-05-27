defmodule ImagePipe.Request.Processor do
  @moduledoc false

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

  @default_max_input_pixels 40_000_000
  @default_max_result_width 8_192
  @default_max_result_height 8_192
  @default_max_result_pixels 40_000_000

  @type source_format() :: SourceFormat.source_format()
  @type decoded() :: %{
          required(:decode_options) => keyword(),
          required(:image) => Vix.Vips.Image.t(),
          required(:source_format) => source_format(),
          optional(:source_response) => Source.Response.t()
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
    decode_options = DecodePlanner.open_options(first_pipeline_operations(plan))

    with {:ok, image} <-
           decode_source_response(source_response, decode_options, opts)
           |> prefer_source_body_limit(source_response)
           |> wrap_decode_error(),
         {:ok, source_format} <- SourceFormat.from_image(image),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format,
         source_response: source_response
       }}
    end
  end

  @spec process_decoded_source(decoded(), Plan.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_decoded_source(
        %{decode_options: decode_options, image: image} = decoded,
        %Plan{} = plan,
        opts
      ) do
    source_response = Map.get(decoded, :source_response)

    Telemetry.span(Telemetry.telemetry_opts(opts), [:transform, :execute], %{}, fn ->
      result =
        with {:ok, final_state} <-
               execute_plan_pipelines(%State{image: image}, plan, opts, source_response),
             {:ok, final_state} <-
               materialize_before_delivery(final_state, decode_options, opts, source_response),
             :ok <- validate_result_image(final_state.image, opts) do
          {:ok, final_state}
        end

      {result, transform_stop_metadata(result)}
    end)
  end

  defp execute_plan_pipelines(
         %State{} = state,
         %Plan{pipelines: pipelines} = plan,
         opts,
         source_response
       ) do
    last_index = length(pipelines) - 1

    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, state},
      &execute_plan_pipeline_step(&1, &2, last_index, plan, opts, source_response)
    )
  end

  defp execute_plan_pipeline_step(
         {pipeline, index},
         {:ok, %State{} = state},
         last_index,
         %Plan{} = plan,
         opts,
         source_response
       ) do
    with {:ok, %State{} = state} <-
           Transform.execute_plan(
             %Plan{plan | pipelines: [pipeline]},
             state,
             opts
           ),
         {:ok, %State{} = state} <-
           maybe_materialize_between_pipelines(state, index, last_index, opts, source_response) do
      {:cont, {:ok, state}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp first_pipeline_operations(%Plan{
         pipelines: [%ImagePipe.Plan.Pipeline{operations: operations} | _rest]
       }),
       do: operations

  defp maybe_materialize_between_pipelines(
         %State{} = state,
         index,
         last_index,
         opts,
         source_response
       )
       when index < last_index do
    materialize_between_pipelines(state, opts, source_response)
  end

  defp maybe_materialize_between_pipelines(
         %State{} = state,
         _index,
         _last_index,
         _opts,
         _source_response
       ),
       do: {:ok, state}

  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)
    image_open_module.open(source_response.stream, decode_options)
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  catch
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %Source.StreamError{reason: reason} -> {:error, {:source, reason}}
  end

  defp materialize_before_delivery(%State{} = state, decode_options, opts, source_response) do
    case Keyword.fetch!(decode_options, :access) do
      :sequential ->
        materialize_state(state, opts) |> handle_materialization_result(source_response)

      :random ->
        {:ok, state}
    end
  end

  defp materialize_between_pipelines(%State{} = state, opts, source_response) do
    materialize_state(state, opts)
    |> handle_materialization_result(source_response)
  end

  defp materialize_state(%State{} = state, opts) do
    materializer = Keyword.get(opts, :image_materializer, Materializer)

    materializer.materialize(state, opts)
  end

  defp handle_materialization_result(result, source_response) do
    result
    |> prefer_source_body_limit(source_response)
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

  defp validate_input_image(image, opts) do
    max_input_pixels = Keyword.get(opts, :max_input_pixels, @default_max_input_pixels)
    pixel_count = Image.width(image) * Image.height(image)

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

  defp validate_result_image(image, opts) do
    width = Image.width(image)
    height = Image.height(image)
    pixels = width * height

    with :ok <-
           check_result_width(
             width,
             Keyword.get(opts, :max_result_width, @default_max_result_width)
           ),
         :ok <-
           check_result_height(
             height,
             Keyword.get(opts, :max_result_height, @default_max_result_height)
           ),
         :ok <-
           check_result_pixels(
             pixels,
             Keyword.get(opts, :max_result_pixels, @default_max_result_pixels)
           ) do
      :ok
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

  defp fetch_decode_stop_metadata({:ok, %{decode_options: _options, image: _image}}),
    do: %{result: :ok}

  defp fetch_decode_stop_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}

  defp fetch_decode_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}
end
