defmodule ImagePipe.Output.Encoder do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Resolved

  @spec stream_output(Vix.Vips.Image.t(), Resolved.t(), keyword()) ::
          {:ok, Enumerable.t(), String.t()} | {:error, {:encode, Exception.t(), list()}}
  def stream_output(%Vix.Vips.Image{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output) do
      image_module = Keyword.get(opts, :image_module, Image)
      stream = image_module.stream!(image, output_options(suffix, resolved_output))

      {:ok, stream, mime_type}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp output_format(%Resolved{format: format}) when is_atom(format) do
    case Format.mime_type(format) do
      {:ok, mime_type} -> {:ok, mime_type, Format.suffix!(mime_type)}
      :error -> {:error, {:encode, unsupported_output_format_error(format), []}}
    end
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end

  defp output_options(suffix, %Resolved{quality: {:quality, value}}),
    do: [suffix: suffix, quality: value]

  defp output_options(suffix, %Resolved{quality: :default}), do: [suffix: suffix]
end
