defmodule ImagePlug.Processor do
  @moduledoc false

  alias ImagePlug.DecodePlanner
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Origin
  alias ImagePlug.OutputNegotiation
  alias ImagePlug.ProcessingRequest
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

  @spec process_origin(ProcessingRequest.t(), TransformChain.t(), String.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_origin(%ProcessingRequest{} = request, chain, origin_identity, opts) do
    with {:ok, %DecodedOrigin{} = decoded} <-
           fetch_decode_validate_origin_with_source_format(request, origin_identity, chain, opts) do
      process_decoded_origin(decoded, chain, opts)
    end
  end

  @spec fetch_decode_validate_origin_with_source_format(
          ProcessingRequest.t(),
          String.t(),
          TransformChain.t(),
          keyword()
        ) ::
          {:ok, DecodedOrigin.t()} | {:error, term()}
  def fetch_decode_validate_origin_with_source_format(
        %ProcessingRequest{} = request,
        origin_identity,
        chain,
        opts
      ) do
    decode_options = DecodePlanner.open_options(chain)

    with {:ok, origin_response} <-
           fetch_origin(request, origin_identity, opts) |> wrap_origin_error(),
         source_format = source_format(origin_response),
         {:ok, image} <-
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

  @spec process_decoded_origin(DecodedOrigin.t(), TransformChain.t(), keyword()) ::
          {:ok, TransformState.t()} | {:error, term()}
  def process_decoded_origin(%DecodedOrigin{} = decoded, chain, opts) do
    with {:ok, final_state} <- execute_chain(decoded.image, chain),
         {:ok, final_state} <-
           materialize_before_delivery(
             final_state,
             decoded.origin_response,
             decoded.decode_options,
             opts
           ) do
      {:ok, final_state}
    end
  end

  def close_pending_origin(%Origin.Response{} = origin_response) do
    case Origin.stream_status(origin_response) do
      :pending -> Origin.close(origin_response)
      _status -> :ok
    end
  end

  defp execute_chain(image, chain) do
    TransformChain.execute(%TransformState{image: image}, chain)
  end

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

  defp fetch_origin(%ProcessingRequest{source_kind: :plain}, origin_identity, opts) do
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

  defp wrap_decode_error({:error, _} = error), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  defp wrap_origin_decode_error({:error, {:origin, error}}), do: {:error, {:origin, error}}
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
    case OutputNegotiation.format(content_type) do
      {:ok, format} -> format
      :error -> nil
    end
  end
end
