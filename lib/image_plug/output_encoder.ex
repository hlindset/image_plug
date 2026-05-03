defmodule ImagePlug.OutputEncoder do
  @moduledoc false

  alias ImagePlug.ImageFormat
  alias ImagePlug.TransformState

  defmodule EncodedOutput do
    @moduledoc false

    @enforce_keys [:body, :content_type]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{body: binary(), content_type: String.t()}
  end

  @spec mime_type(TransformState.t()) :: {:ok, String.t()} | :error
  def mime_type(%TransformState{output: format}) when is_atom(format) do
    ImageFormat.mime_type(format)
  end

  @spec memory_output(TransformState.t(), keyword()) ::
          {:ok, EncodedOutput.t()} | {:error, {:encode, Exception.t(), list()}}
  def memory_output(%TransformState{} = state, opts) do
    with {:ok, mime_type, suffix} <- output_format(state),
         {:ok, body} <- write_body(Keyword.get(opts, :image_module, Image), state.image, suffix) do
      {:ok, %EncodedOutput{body: body, content_type: mime_type}}
    end
  end

  @spec limited_memory_output(TransformState.t(), keyword(), non_neg_integer() | nil) ::
          {:ok, EncodedOutput.t()} | :too_large | {:error, {:encode, Exception.t(), list()}}
  def limited_memory_output(%TransformState{} = state, opts, nil), do: memory_output(state, opts)

  def limited_memory_output(%TransformState{} = state, opts, max_body_bytes)
      when is_integer(max_body_bytes) and max_body_bytes >= 0 do
    with {:ok, mime_type, suffix} <- output_format(state),
         {:ok, body} <-
           stream_body(Keyword.get(opts, :image_module, Image), state.image, suffix, max_body_bytes) do
      {:ok, %EncodedOutput{body: body, content_type: mime_type}}
    end
  end

  defp output_format(%TransformState{} = state) do
    with {:ok, mime_type} <- mime_type(state) do
      {:ok, mime_type, ImageFormat.suffix!(mime_type)}
    else
      :error -> {:error, {:encode, unsupported_output_format_error(state.output), []}}
    end
  end

  defp write_body(image_module, image, suffix) do
    case image_module.write(image, :memory, suffix: suffix) do
      {:ok, body} -> {:ok, body}
      {:error, %_{} = exception} -> {:error, {:encode, exception, []}}
      {:error, reason} -> {:error, {:encode, RuntimeError.exception(inspect(reason)), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp stream_body(image_module, image, suffix, max_body_bytes) do
    image_module.stream!(image, suffix: suffix)
    |> Enum.reduce_while({[], 0}, fn chunk, {chunks, size} ->
      size = size + byte_size(chunk)

      if size > max_body_bytes do
        {:halt, :too_large}
      else
        {:cont, {[chunk | chunks], size}}
      end
    end)
    |> case do
      :too_large -> :too_large
      {chunks, _size} -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end
end
