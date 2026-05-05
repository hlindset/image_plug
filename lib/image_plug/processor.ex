defmodule ImagePlug.Processor do
  @moduledoc false

  alias ImagePlug.DecodePlanner
  alias ImagePlug.ImageFormat
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Origin
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  defmodule DecodedOrigin do
    @moduledoc false

    @enforce_keys [:decode_options, :image, :origin_response, :source_format]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{
            decode_options: keyword(),
            image: Vix.Vips.Image.t(),
            origin_response: ImagePlug.Origin.Response.t(),
            source_format: :avif | :webp | :jpeg | :png | nil
          }
  end

  @spec process_origin(Plan.t(), String.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_origin(%Plan{} = plan, origin_identity, opts) do
    with {:ok, pipelines} <- validated_pipelines(plan) do
      process_origin(plan, pipelines, origin_identity, opts)
    end
  end

  @spec process_origin(Plan.t(), [ImagePlug.Pipeline.t()], String.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_origin(%Plan{} = plan, pipelines, origin_identity, opts) when is_list(pipelines) do
    with {:ok, %DecodedOrigin{} = decoded} <-
           fetch_decode_validate_origin_with_source_format(plan, pipelines, origin_identity, opts) do
      process_decoded_origin(decoded, pipelines, opts)
    end
  end

  @spec fetch_decode_validate_origin_with_source_format(
          Plan.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, DecodedOrigin.t()} | {:error, term()}
  def fetch_decode_validate_origin_with_source_format(
        %Plan{} = plan,
        origin_identity,
        opts
      ) do
    with {:ok, pipelines} <- validated_pipelines(plan) do
      fetch_decode_validate_origin_with_source_format(plan, pipelines, origin_identity, opts)
    end
  end

  @spec fetch_decode_validate_origin_with_source_format(
          Plan.t(),
          [ImagePlug.Pipeline.t()],
          String.t(),
          keyword()
        ) ::
          {:ok, DecodedOrigin.t()} | {:error, term()}
  def fetch_decode_validate_origin_with_source_format(
        %Plan{} = plan,
        pipelines,
        origin_identity,
        opts
      )
      when is_list(pipelines) do
    with {:ok, origin_response, source_format} <-
           fetch_origin_with_source_format(plan, pipelines, origin_identity, opts),
         {:ok, %DecodedOrigin{} = decoded} <-
           decode_validate_origin_response(origin_response, source_format, plan, pipelines, opts) do
      {:ok, decoded}
    end
  end

  @spec fetch_origin_with_source_format(Plan.t(), String.t(), keyword()) ::
          {:ok, Origin.Response.t(), :avif | :webp | :jpeg | :png | nil} | {:error, term()}
  def fetch_origin_with_source_format(%Plan{} = plan, origin_identity, opts) do
    with {:ok, pipelines} <- validated_pipelines(plan) do
      fetch_origin_with_source_format(plan, pipelines, origin_identity, opts)
    end
  end

  @spec fetch_origin_with_source_format(Plan.t(), [ImagePlug.Pipeline.t()], String.t(), keyword()) ::
          {:ok, Origin.Response.t(), :avif | :webp | :jpeg | :png | nil} | {:error, term()}
  def fetch_origin_with_source_format(%Plan{} = plan, _pipelines, origin_identity, opts) do
    with {:ok, origin_response} <-
           fetch_origin(plan, origin_identity, opts) |> wrap_origin_error() do
      {:ok, origin_response, source_format(origin_response)}
    end
  end

  @spec decode_validate_origin_response(
          Origin.Response.t(),
          :avif | :webp | :jpeg | :png | nil,
          Plan.t(),
          keyword()
        ) :: {:ok, DecodedOrigin.t()} | {:error, term()}
  def decode_validate_origin_response(
        %Origin.Response{} = origin_response,
        source_format,
        %Plan{} = plan,
        opts
      ) do
    result =
      with {:ok, pipelines} <- validated_pipelines(plan) do
        decode_validate_origin_response(origin_response, source_format, plan, pipelines, opts)
      end

    close_pending_origin_on_error(result, origin_response)
  end

  @spec decode_validate_origin_response(
          Origin.Response.t(),
          :avif | :webp | :jpeg | :png | nil,
          Plan.t(),
          [ImagePlug.Pipeline.t()],
          keyword()
        ) :: {:ok, DecodedOrigin.t()} | {:error, term()}
  def decode_validate_origin_response(origin_response, source_format, plan, _pipelines, opts) do
    decode_options = DecodePlanner.open_options(plan)

    with {:ok, image} <-
           decode_origin_response(origin_response, decode_options, opts)
           |> wrap_origin_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error() do
      {:ok,
       %DecodedOrigin{
         decode_options: decode_options,
         image: image,
         origin_response: origin_response,
         source_format: source_format
       }}
    end
  end

  @spec process_decoded_origin(DecodedOrigin.t(), Plan.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_decoded_origin(%DecodedOrigin{} = decoded, %Plan{} = plan, opts) do
    with {:ok, pipelines} <- validated_pipelines(plan) do
      process_decoded_origin(decoded, pipelines, opts)
    end
  end

  @spec process_decoded_origin(DecodedOrigin.t(), [ImagePlug.Pipeline.t()], keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_decoded_origin(%DecodedOrigin{} = decoded, pipelines, opts)
      when is_list(pipelines) do
    result =
      case execute_pipelines(%TransformState{image: decoded.image}, pipelines, decoded, opts) do
        {:ok, final_state} ->
          materialize_before_delivery(
            final_state,
            decoded.origin_response,
            decoded.decode_options,
            opts
          )

        {:error, _reason} = error ->
          error
      end

    close_pending_origin_on_error(result, decoded.origin_response)
  end

  def close_pending_origin(%Origin.Response{} = origin_response) do
    case Origin.stream_status(origin_response) do
      :pending -> Origin.close(origin_response)
      _status -> :ok
    end
  end

  defp close_pending_origin_on_error(
         {:error, _reason} = error,
         %Origin.Response{} = origin_response
       ) do
    close_pending_origin(origin_response)
    error
  end

  defp close_pending_origin_on_error(result, %Origin.Response{}), do: result

  defp validated_pipelines(%Plan{} = plan), do: Plan.validated_pipelines(plan)

  defp execute_pipelines(%TransformState{} = state, pipelines, %DecodedOrigin{} = decoded, opts) do
    last_index = length(pipelines) - 1

    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, &execute_pipeline_step(&1, &2, last_index, decoded, opts))
  end

  defp execute_pipeline_step(
         {%ImagePlug.Pipeline{operations: operations}, index},
         {:ok, %TransformState{} = state},
         last_index,
         %DecodedOrigin{} = decoded,
         opts
       ) do
    with {:ok, %TransformState{} = state} <- TransformChain.execute(state, operations),
         {:ok, %TransformState{} = state} <-
           maybe_materialize_between_pipelines(state, index, last_index, decoded, opts) do
      {:cont, {:ok, state}}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp maybe_materialize_between_pipelines(
         %TransformState{} = state,
         index,
         last_index,
         %DecodedOrigin{} = decoded,
         opts
       )
       when index < last_index do
    materialize_between_pipelines(state, decoded.origin_response, opts)
  end

  defp maybe_materialize_between_pipelines(
         %TransformState{} = state,
         _index,
         _last_index,
         %DecodedOrigin{},
         _opts
       ),
       do: {:ok, state}

  defp decode_origin_response(%Origin.Response{} = origin_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    case image_open_module.open(origin_response.stream, decode_options) do
      {:ok, image} ->
        case Origin.stream_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:ok, image}
          :pending -> {:ok, image}
        end

      {:error, decode_error} ->
        case Origin.stream_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:error, decode_error}
          :pending -> close_pending_origin_with_decode_error(origin_response, decode_error)
        end
    end
  end

  defp materialize_before_delivery(
         %TransformState{} = state,
         %Origin.Response{} = origin_response,
         decode_options,
         opts
       ) do
    case Keyword.fetch!(decode_options, :access) do
      :sequential -> materialize_sequential_before_delivery(state, origin_response, opts)
      :random -> {:ok, state}
    end
  end

  defp materialize_sequential_before_delivery(
         %TransformState{} = state,
         %Origin.Response{} = origin_response,
         opts
       ) do
    materialize_state(state, opts)
    |> handle_materialization_result(origin_response)
  end

  defp materialize_between_pipelines(
         %TransformState{} = state,
         %Origin.Response{} = origin_response,
         opts
       ) do
    materialize_state(state, opts)
    |> handle_materialization_result(origin_response)
  end

  defp materialize_state(%TransformState{} = state, opts) do
    materializer =
      Keyword.get(
        opts,
        :image_materializer,
        Keyword.get(opts, :image_materializer_module, ImageMaterializer)
      )

    load_materializer(materializer, state, opts)
  end

  defp load_materializer(materializer, %TransformState{} = state, opts)
       when is_atom(materializer) do
    case Code.ensure_loaded(materializer) do
      {:module, ^materializer} ->
        dispatch_materializer(materializer, state, opts)

      {:error, reason} ->
        {:error, {:config, {:invalid_image_materializer, materializer, reason}}}
    end
  end

  defp load_materializer(materializer, %TransformState{}, _opts),
    do: {:error, {:config, {:invalid_image_materializer, materializer}}}

  defp dispatch_materializer(materializer, %TransformState{} = state, opts) do
    cond do
      function_exported?(materializer, :materialize, 2) ->
        materializer.materialize(state, opts)
        |> normalize_state_materializer_result(materializer)

      function_exported?(materializer, :materialize, 1) ->
        materializer.materialize(state.image)
        |> normalize_image_materializer_result(materializer, state)

      true ->
        {:error, {:config, {:invalid_image_materializer, materializer}}}
    end
  end

  defp normalize_state_materializer_result(
         {:ok, %TransformState{image: %Vix.Vips.Image{}} = state},
         _materializer
       ),
       do: {:ok, state}

  defp normalize_state_materializer_result({:ok, invalid_state}, materializer),
    do: invalid_materializer_result(materializer, {:ok, invalid_state})

  defp normalize_state_materializer_result({:error, _reason} = error, _materializer), do: error

  defp normalize_state_materializer_result(unexpected, materializer),
    do: invalid_materializer_result(materializer, unexpected)

  defp normalize_image_materializer_result(
         {:ok, %Vix.Vips.Image{} = image},
         _materializer,
         %TransformState{} = state
       ) do
    {:ok, TransformState.set_image(state, image)}
  end

  defp normalize_image_materializer_result({:ok, invalid_image}, materializer, %TransformState{}),
    do: invalid_materializer_result(materializer, {:ok, invalid_image})

  defp normalize_image_materializer_result(
         {:error, _reason} = error,
         _materializer,
         %TransformState{}
       ),
       do: error

  defp normalize_image_materializer_result(unexpected, materializer, %TransformState{}),
    do: invalid_materializer_result(materializer, unexpected)

  defp invalid_materializer_result(materializer, result),
    do: {:error, {:config, {:invalid_image_materializer_result, materializer, result}}}

  defp handle_materialization_result(
         {:error, {:config, _reason} = error},
         %Origin.Response{}
       ),
       do: {:error, error}

  defp handle_materialization_result(
         {:ok, %TransformState{} = state},
         %Origin.Response{} = origin_response
       ) do
    case Origin.require_stream_status(origin_response) do
      :done -> {:ok, state}
      {:error, reason} -> {:error, {:origin, reason}}
    end
  end

  defp handle_materialization_result(
         {:error, materialize_error},
         %Origin.Response{} = origin_response
       ) do
    case Origin.stream_status(origin_response) do
      {:error, reason} -> {:error, {:origin, reason}}
      :done -> {:error, {:decode, materialize_error}}
      :pending -> close_pending_origin_with_decode_error(origin_response, materialize_error)
    end
  end

  defp close_pending_origin_with_decode_error(
         %Origin.Response{} = origin_response,
         materialize_error
       ) do
    close_pending_origin(origin_response)
    {:error, {:decode, materialize_error}}
  end

  defp fetch_origin(%Plan{source: %Plain{}}, origin_identity, opts) do
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

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  defp wrap_origin_decode_error({:error, {:origin, error}}), do: {:error, {:origin, error}}
  defp wrap_origin_decode_error({:error, {:decode, error}}), do: {:error, {:decode, error}}
  defp wrap_origin_decode_error(result), do: wrap_decode_error(result)

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

  defp source_format(%Origin.Response{content_type: content_type}) do
    case ImageFormat.format(content_type) do
      {:ok, format} -> format
      {:error, {:unsupported_output_format, _mime_type}} -> nil
    end
  end
end
