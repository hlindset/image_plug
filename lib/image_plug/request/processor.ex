defmodule ImagePlug.Request.Processor do
  @moduledoc false

  alias ImagePlug.Plan
  alias ImagePlug.Origin.Decoded
  alias ImagePlug.Origin
  alias ImagePlug.Telemetry
  alias ImagePlug.Transform
  alias ImagePlug.Transform.DecodePlanner
  alias ImagePlug.Transform.Materializer
  alias ImagePlug.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @type source_format() :: :avif | :webp | :jpeg | :png | nil

  @spec process_origin(Plan.t(), String.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_origin(%Plan{} = plan, origin_identity, opts) do
    with {:ok, %Decoded{} = decoded} <-
           fetch_decode_validate_origin_with_source_format(plan, origin_identity, opts) do
      process_decoded_origin(decoded, plan, opts)
    end
  end

  @spec fetch_decode_validate_origin_with_source_format(Plan.t(), String.t(), keyword()) ::
          {:ok, Decoded.t()} | {:error, term()}
  def fetch_decode_validate_origin_with_source_format(%Plan{} = plan, origin_identity, opts) do
    Telemetry.span(opts, [:origin, :fetch_decode], %{}, fn ->
      result =
        with {:ok, origin_response} <- fetch_origin(plan, origin_identity, opts) do
          decode_validate_origin_response(origin_response, plan, opts)
        end

      {result, fetch_decode_stop_metadata(result)}
    end)
  end

  @spec decode_validate_origin_response(Origin.Response.t(), Plan.t(), keyword()) ::
          {:ok, Decoded.t()} | {:error, term()}
  def decode_validate_origin_response(%Origin.Response{} = origin_response, %Plan{} = plan, opts) do
    decode_options = DecodePlanner.open_options(first_pipeline_operations(plan))

    with {:ok, image} <-
           decode_origin_response(origin_response, decode_options, opts)
           |> wrap_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
      source_format = source_format(image)

      {:ok,
       %Decoded{
         decode_options: decode_options,
         image: image,
         source_format: source_format
       }}
    end
  end

  @spec process_decoded_origin(Decoded.t(), Plan.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_decoded_origin(%Decoded{} = decoded, %Plan{} = plan, opts) do
    Telemetry.span(opts, [:transform, :execute], %{}, fn ->
      result =
        with {:ok, final_state} <-
               execute_plan_pipelines(%State{image: decoded.image}, plan, opts) do
          materialize_before_delivery(final_state, decoded.decode_options, opts)
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

  defp decode_origin_response(%Origin.Response{} = origin_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    image_open_module.open(origin_response.stream, decode_options)
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
    materializer =
      Keyword.get(
        opts,
        :image_materializer,
        Keyword.get(opts, :image_materializer_module, Materializer)
      )

    materializer.materialize(state, opts)
  end

  defp handle_materialization_result({:error, {:config, _reason} = error}), do: {:error, error}

  defp handle_materialization_result({:error, materialize_error}),
    do: {:error, {:decode, materialize_error}}

  defp handle_materialization_result({:ok, %State{} = state}), do: {:ok, state}

  defp fetch_origin(%Plan{source: {:plain, _path}}, origin_identity, opts) do
    Origin.fetch(origin_identity, origin_req_options(opts))
  end

  defp origin_req_options(opts) do
    opts
    |> Keyword.get(:origin_req_options, [])
    |> put_origin_req_option(:max_body_bytes, Keyword.fetch(opts, :max_body_bytes))
    |> put_origin_req_option(:receive_timeout, Keyword.fetch(opts, :origin_receive_timeout))
    |> put_origin_req_option(:max_redirects, Keyword.fetch(opts, :origin_max_redirects))
  end

  defp put_origin_req_option(req_options, key, {:ok, value}),
    do: Keyword.put(req_options, key, value)

  defp put_origin_req_option(req_options, _key, :error), do: req_options

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

  defp source_format(image) do
    case VipsImage.header_value(image, "vips-loader") do
      {:ok, loader} when is_binary(loader) -> loader_format(loader)
      {:error, _reason} -> nil
    end
  end

  defp loader_format("jpegload" <> _suffix), do: :jpeg
  defp loader_format("pngload" <> _suffix), do: :png
  defp loader_format("webpload" <> _suffix), do: :webp
  defp loader_format("heifload" <> _suffix), do: :avif
  defp loader_format(_loader), do: nil

  defp fetch_decode_stop_metadata({:ok, %Decoded{}}), do: %{result: :ok}

  defp fetch_decode_stop_metadata({:error, {:origin, error}}),
    do: %{result: :origin_error, error: Telemetry.error(error)}

  defp fetch_decode_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Telemetry.error(error)}

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Telemetry.error(error)}
end
