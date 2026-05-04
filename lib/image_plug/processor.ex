defmodule ImagePlug.Processor do
  @moduledoc false

  alias ImagePlug.DecodePlanner
  alias ImagePlug.ImageFormat
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Origin
  alias ImagePlug.Pipeline
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
    with {:ok, %DecodedOrigin{} = decoded} <-
           fetch_decode_validate_origin_with_source_format(plan, origin_identity, opts) do
      process_decoded_origin(decoded, plan, opts)
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
    with {:ok, _operations} <- pipeline_operations(plan),
         {:ok, origin_response, source_format} <-
           fetch_origin_with_source_format(plan, origin_identity, opts),
         {:ok, %DecodedOrigin{} = decoded} <-
           decode_validate_origin_response(origin_response, source_format, plan, opts) do
      {:ok, decoded}
    end
  end

  @spec fetch_origin_with_source_format(Plan.t(), String.t(), keyword()) ::
          {:ok, Origin.Response.t(), :avif | :webp | :jpeg | :png | nil} | {:error, term()}
  def fetch_origin_with_source_format(%Plan{} = plan, origin_identity, opts) do
    with {:ok, _operations} <- pipeline_operations(plan),
         {:ok, origin_response} <-
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
      with {:ok, operations} <- pipeline_operations(plan) do
        decode_options = DecodePlanner.open_options(operations)

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

    close_pending_origin_on_error(result, origin_response)
  end

  @spec process_decoded_origin(DecodedOrigin.t(), Plan.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_decoded_origin(%DecodedOrigin{} = decoded, %Plan{} = plan, opts) do
    result =
      with {:ok, operations} <- pipeline_operations(plan),
           {:ok, final_state} <- execute_chain(decoded.image, operations) do
        materialize_before_delivery(
          final_state,
          decoded.origin_response,
          decoded.decode_options,
          opts
        )
      else
        {:error, _reason} = error -> error
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

  defp execute_chain(image, chain) do
    TransformChain.execute(%TransformState{image: image}, chain)
  end

  defp pipeline_operations(%Plan{pipelines: [%Pipeline{operations: operations}]}),
    do: {:ok, operations}

  defp pipeline_operations(%Plan{pipelines: [_pipeline | _rest]}),
    do: {:error, :unsupported_multiple_pipelines_during_transition}

  defp pipeline_operations(%Plan{pipelines: []}), do: {:error, :empty_pipeline_plan}

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
    materializer = Keyword.get(opts, :image_materializer_module, ImageMaterializer)

    state.image
    |> materializer.materialize()
    |> handle_materialization_result(state, origin_response)
  end

  defp handle_materialization_result(
         {:ok, materialized_image},
         %TransformState{} = state,
         %Origin.Response{} = origin_response
       ) do
    case Origin.require_stream_status(origin_response) do
      :done -> {:ok, TransformState.set_image(state, materialized_image)}
      {:error, reason} -> {:error, {:origin, reason}}
    end
  end

  defp handle_materialization_result(
         {:error, materialize_error},
         %TransformState{},
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
