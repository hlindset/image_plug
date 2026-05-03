defmodule ImagePlug.OutputSelection do
  @moduledoc false

  alias ImagePlug.OutputNegotiation

  @enforce_keys [:format, :headers, :reason]
  defstruct @enforce_keys

  @type reason() :: :auto | :source
  @type t() :: %__MODULE__{
          format: :avif | :webp | :jpeg | :png,
          headers: [{String.t(), String.t()}],
          reason: reason()
        }

  @spec preselect(String.t() | nil, keyword()) ::
          {:ok, t()} | :defer | {:error, :not_acceptable}
  def preselect(accept_header, opts) do
    accept_header
    |> OutputNegotiation.preselect(output_negotiation_opts(opts))
    |> case do
      {:ok, format} -> {:ok, selection(format, :auto)}
      :defer -> :defer
      {:error, :not_acceptable} -> {:error, :not_acceptable}
    end
  end

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: accept_vary_headers()

  @spec negotiate(String.t() | nil, atom() | nil, keyword()) ::
          {:ok, t()} | {:error, :not_acceptable | term()}
  def negotiate(accept_header, source_format, opts) do
    negotiation_opts =
      opts
      |> output_negotiation_opts()
      |> Keyword.put(:source_format, source_format)

    with {:ok, {mime_type, reason}} <-
           OutputNegotiation.negotiate_selection(accept_header, negotiation_opts),
         {:ok, format} <- OutputNegotiation.format(mime_type) do
      {:ok, selection(format, reason)}
    else
      {:error, {:unsupported_output_format, mime_type}} ->
        {:error, unsupported_output_format_error(mime_type)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp selection(format, reason) do
    %__MODULE__{
      format: format,
      headers: accept_vary_headers(),
      reason: reason
    }
  end

  defp accept_vary_headers, do: [{"vary", "Accept"}]

  defp output_negotiation_opts(opts) do
    [
      auto_avif: Keyword.get(opts, :auto_avif, true),
      auto_webp: Keyword.get(opts, :auto_webp, true)
    ]
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end
end
