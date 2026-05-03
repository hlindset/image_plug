defmodule ImagePlug.OutputEncoder do
  @moduledoc false

  alias ImagePlug.OutputNegotiation
  alias ImagePlug.TransformState

  defmodule EncodedOutput do
    @moduledoc false

    @enforce_keys [:body, :content_type]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{body: binary(), content_type: String.t()}
  end

  @spec mime_type(TransformState.t()) :: {:ok, String.t()} | :error
  def mime_type(%TransformState{output: format}) when is_atom(format) do
    OutputNegotiation.mime_type(format)
  end

  @spec memory_output(TransformState.t(), keyword()) ::
          {:ok, EncodedOutput.t()} | {:error, {:encode, Exception.t(), list()}}
  def memory_output(%TransformState{} = state, opts) do
    with {:ok, mime_type, suffix} <- output_format(state),
         {:ok, body} <- write_body(Keyword.get(opts, :image_module, Image), state.image, suffix) do
      {:ok, %EncodedOutput{body: body, content_type: mime_type}}
    end
  end

  defp output_format(%TransformState{} = state) do
    with {:ok, mime_type} <- mime_type(state) do
      {:ok, mime_type, OutputNegotiation.suffix!(mime_type)}
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

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end
end
