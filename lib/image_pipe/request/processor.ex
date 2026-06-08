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
          optional(:source_dimensions) => {pos_integer(), pos_integer()} | nil,
          optional(:original_dims) => {pos_integer(), pos_integer()},
          optional(:achieved_shrink) => %{w: float(), h: float()} | nil
        }

  @spec process_source(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def process_source(%Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
    with {:ok, decoded} <-
           fetch_decode_validate_source_with_source_format(plan, resolved_source, opts),
         {:ok, %State{} = state} <- process_decoded_source(decoded, plan, opts) do
      materialize_for_delivery(state, opts)
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
           |> wrap_decode_error() do
      {:ok,
       %{
         decode_options: decode_options,
         image: image,
         source_format: source_format,
         source_dimensions: shrink_source_dimensions(decode_options, original_dims),
         original_dims: original_dims,
         achieved_shrink: compute_achieved_shrink(original_dims, image)
       }}
    end
  end

  # The residual resize sizes against the exact original extent — but only when the
  # decode was actually shrunk. With no shrink the transform layer reads the live
  # image dims instead (which also keeps a crop-before-resize correct), so we leave
  # it `nil`. These are the stored (pre-orientation) dims, which stay in the storage
  # frame (orientation is deferred and flushed after the resize); shrink is declined
  # when a crop/quarter-turn rotate precedes the resize, so they cannot go stale.
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
    source_dimensions = Map.get(decoded, :source_dimensions)

    # The realized shrink is only meaningful when shrink-on-load actually fired;
    # `source_dimensions` is the same gate (set iff a shrink/scale load option was
    # emitted). A crop preceding the resize uses it to rescale absolute coords.
    decode_shrink = if source_dimensions, do: Map.get(decoded, :achieved_shrink), else: nil

    initial_state = %State{
      image: image,
      source_dimensions: source_dimensions,
      decode_shrink: decode_shrink
    }

    operation_names = Plan.operation_names(plan)

    execute_start_meta = %{
      operations: operation_names,
      operation_count: length(operation_names)
    }

    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:transform, :execute],
      execute_start_meta,
      fn ->
        result = execute_transform_plan(initial_state, plan, opts)
        {result, transform_stop_metadata(result)}
      end
    )
  end

  # PlanExecutor owns the pipeline loop: it seeds the EXIF orientation once
  # (seed_orientation), iterates all pipelines, and resolves any still-pending
  # orientation at each pipeline boundary (a backstop — within a pipeline the flush
  # usually fires earlier, at the first materializing op or after a resize). The
  # request layer adds the delivery backstop afterward (materialize_for_delivery) —
  # materializing any chain that never materialized mid-pipeline before delivery.
  defp execute_transform_plan(%State{} = state, %Plan{} = plan, opts) do
    Transform.execute_plan(plan, state, Keyword.put(opts, :seed_orientation, true))
    |> classify_materialize_error()
  end

  defp classify_materialize_error({:error, {:materialize_error, reason}}),
    do: {:error, {:decode, reason}}

  defp classify_materialize_error(result), do: result

  defp first_pipeline_operations(%Plan{
         pipelines: [%ImagePipe.Plan.Pipeline{operations: operations} | _rest]
       }),
       do: operations

  defp seekable_input(%Source.Response{path: path, stream: nil}) when is_binary(path),
    do: {:ok, {:path, path}}

  # The drained value is a host-implementable Source adapter stream (a boundary we
  # don't control). A StreamError carries a classified source reason; any other
  # exception/throw/exit raised while draining the source is normalized to a safe
  # {:source, :stream_exception} (→ 422) rather than crashing the request.
  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
    _exception -> {:error, {:source, :stream_exception}}
  catch
    _kind, _reason -> {:error, {:source, :stream_exception}}
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

  @doc """
  Called by `process_source/3` after transform execution and by the producer after
  `Output.Clamp`, to materialize the lazy vips state before encoding. Returns
  `{:ok, state}` unchanged if an op already materialized mid-pipeline; maps a
  materialize failure to a decode error (→ 415), passing through already-tagged
  source/config errors.
  """
  @spec materialize_for_delivery(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize_for_delivery(%State{} = state, opts) do
    result =
      if state.materialized? do
        {:ok, state}
      else
        materialize_state(state, opts)
      end

    classify_delivery_materialize_result(result)
  end

  defp materialize_state(%State{} = state, opts) do
    materializer = Keyword.get(opts, :image_materializer, Materializer)
    materializer.materialize(state, opts)
  end

  # `materialize_state/2` dispatches to the injectable `:image_materializer`, whose
  # `materialize/2` callback returns `{:ok, State} | {:error, term()}` — a boundary the
  # caller doesn't fully control. The default `Materializer` only ever produces vips
  # errors (→ `:decode`), but a host-supplied materializer may already tag a source/
  # config error; pass those through untagged rather than mis-wrapping them as `:decode`.
  defp classify_delivery_materialize_result({:error, {:source, _reason} = error}),
    do: {:error, error}

  defp classify_delivery_materialize_result({:error, {:config, _reason} = error}),
    do: {:error, error}

  defp classify_delivery_materialize_result({:error, reason}), do: {:error, {:decode, reason}}
  defp classify_delivery_materialize_result({:ok, %State{} = state}), do: {:ok, state}

  defp wrap_decode_error({:error, {:source, _reason}} = error), do: error
  defp wrap_decode_error({:error, error}), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  # Whether the source's EXIF orientation implies a 90°/270° turn. The decode
  # planner uses this (together with the `auto_rotate` flag) to decide whether the
  # shrink axes must be swapped. Reading the header
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
