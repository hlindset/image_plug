defmodule ImagePlug.OutputEncoder do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.OutputNegotiation
  alias ImagePlug.TransformState

  @spec mime_type(TransformState.t()) :: {:ok, String.t()} | :error
  def mime_type(%TransformState{output: format}) when is_atom(format) do
    OutputNegotiation.mime_type(format)
  end

  @spec cache_entry(TransformState.t(), keyword(), [{String.t(), String.t()}]) ::
          {:ok, Entry.t()} | {:error, {:encode, Exception.t(), list()}}
  def cache_entry(%TransformState{} = state, opts, response_headers) do
    with {:ok, mime_type} <- mime_type(state) do
      suffix = OutputNegotiation.suffix!(mime_type)
      image_module = Keyword.get(opts, :image_module, Image)

      try do
        body = image_module.write!(state.image, :memory, suffix: suffix)

        {:ok,
         Entry.new!(
           body: body,
           content_type: mime_type,
           headers: response_headers,
           created_at: DateTime.utc_now()
         )}
      rescue
        exception -> {:error, {:encode, exception, __STACKTRACE__}}
      end
    else
      :error -> {:error, {:encode, unsupported_output_format_error(state.output), []}}
    end
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end
end
