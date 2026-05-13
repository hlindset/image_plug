defmodule ImagePlug.Output.Encoder do
  @moduledoc false

  alias ImagePlug.Output.Format
  alias ImagePlug.Output.Resolved

  defmodule EncodedOutput do
    @moduledoc false

    @enforce_keys [:body, :content_type]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{body: binary(), content_type: String.t()}
  end

  @spec mime_type(atom()) :: {:ok, String.t()} | :error
  def mime_type(format) when is_atom(format) do
    Format.mime_type(format)
  end

  @spec memory_output(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, EncodedOutput.t()} | :too_large | {:error, {:encode, Exception.t(), list()}}
  def memory_output(%Vix.Vips.Image{} = image, %Resolved{} = resolved_output, opts) do
    memory_output_with_limit(
      image,
      resolved_output,
      opts,
      Keyword.get(opts, :max_body_bytes)
    )
  end

  defp memory_output_with_limit(
         %Vix.Vips.Image{} = image,
         %Resolved{} = resolved_output,
         opts,
         nil
       ) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, body} <-
           write_body(
             Keyword.get(opts, :image_module, Image),
             image,
             output_options(suffix, resolved_output)
           ) do
      {:ok, %EncodedOutput{body: body, content_type: mime_type}}
    end
  end

  defp memory_output_with_limit(
         %Vix.Vips.Image{} = image,
         %Resolved{} = resolved_output,
         opts,
         max_body_bytes
       )
       when is_integer(max_body_bytes) and max_body_bytes >= 0 do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, body} <-
           stream_body(
             Keyword.get(opts, :image_module, Image),
             image,
             output_options(suffix, resolved_output),
             max_body_bytes
           ) do
      {:ok, %EncodedOutput{body: body, content_type: mime_type}}
    end
  end

  defp output_format(%Resolved{format: format}) when is_atom(format) do
    case mime_type(format) do
      {:ok, mime_type} -> {:ok, mime_type, Format.suffix!(mime_type)}
      :error -> {:error, {:encode, unsupported_output_format_error(format), []}}
    end
  end

  defp write_body(image_module, image, output_options) do
    case image_module.write(image, :memory, output_options) do
      {:ok, body} -> {:ok, body}
      {:error, %_{} = exception} -> {:error, {:encode, exception, []}}
      {:error, reason} -> {:error, {:encode, RuntimeError.exception(inspect(reason)), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp stream_body(image_module, image, output_options, max_body_bytes) do
    image_module.stream!(image, output_options)
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

  defp output_options(suffix, %Resolved{quality: {:quality, value}}),
    do: [suffix: suffix, quality: value]

  defp output_options(suffix, %Resolved{quality: :default}), do: [suffix: suffix]
end
