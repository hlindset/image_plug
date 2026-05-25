defmodule ImagePlug.Request.Processor do
  @moduledoc false

  alias ImagePlug.Error
  alias ImagePlug.Plan
  alias ImagePlug.Request.Options
  alias ImagePlug.Request.SourceFormat
  alias ImagePlug.Source
  alias ImagePlug.Telemetry
  alias ImagePlug.Transform
  alias ImagePlug.Transform.DecodePlanner
  alias ImagePlug.Transform.Materializer
  alias ImagePlug.Transform.State

  @type source_format() :: SourceFormat.source_format()
  @type decoded() :: %{
          required(:decode_options) => keyword(),
          required(:image) => Vix.Vips.Image.t(),
          required(:source_format) => source_format()
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
           |> wrap_decode_error(),
         {:ok, source_format} <- SourceFormat.from_image(image),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format
       }}
    end
  end

  @spec process_decoded_source(decoded(), Plan.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_decoded_source(
        %{decode_options: decode_options, image: image},
        %Plan{} = plan,
        opts
      ) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:transform, :execute], %{}, fn ->
      result =
        with {:ok, final_state} <-
               execute_plan_pipelines(%State{image: image}, plan, opts) do
          materialize_before_delivery(final_state, decode_options, opts)
        end

      {result, transform_stop_metadata(result)}
    end)
  end

  defp execute_plan_pipelines(
         %State{} = state,
         %Plan{pipelines: pipelines} = plan,
         opts
       ) do
    last_index = length(pipelines) - 1

    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while(
      {:ok, state},
      &execute_plan_pipeline_step(&1, &2, last_index, plan, opts)
    )
  end

  defp execute_plan_pipeline_step(
         {pipeline, index},
         {:ok, %State{} = state},
         last_index,
         %Plan{} = plan,
         opts
       ) do
    with {:ok, %State{} = state} <-
           Transform.execute_plan(
             %Plan{plan | pipelines: [pipeline]},
             state,
             opts
           ),
         {:ok, %State{} = state} <-
           maybe_materialize_between_pipelines(state, index, last_index, opts) do
      {:cont, {:ok, state}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp first_pipeline_operations(%Plan{
         pipelines: [%ImagePlug.Plan.Pipeline{operations: operations} | _rest]
       }),
       do: operations

  defp maybe_materialize_between_pipelines(%State{} = state, index, last_index, opts)
       when index < last_index do
    materialize_between_pipelines(state, opts)
  end

  defp maybe_materialize_between_pipelines(%State{} = state, _index, _last_index, _opts),
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

  defp materialize_before_delivery(%State{} = state, decode_options, opts) do
    case Keyword.fetch!(decode_options, :access) do
      :sequential -> materialize_state(state, opts) |> handle_materialization_result()
      :random -> {:ok, state}
    end
  end

  defp materialize_between_pipelines(%State{} = state, opts) do
    materialize_state(state, opts)
    |> handle_materialization_result()
  end

  defp materialize_state(%State{} = state, opts) do
    materializer = Keyword.get(opts, :image_materializer, Materializer)

    materializer.materialize(state, opts)
  end

  defp handle_materialization_result({:error, {:config, _reason} = error}), do: {:error, error}

  defp handle_materialization_result({:error, materialize_error}),
    do: {:error, {:decode, materialize_error}}

  defp handle_materialization_result({:ok, %State{} = state}), do: {:ok, state}

  defp wrap_decode_error({:error, {:source, _reason}} = error), do: error
  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

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
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

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
