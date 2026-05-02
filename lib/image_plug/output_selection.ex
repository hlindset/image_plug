defmodule ImagePlug.OutputSelection do
  @moduledoc false

  import Plug.Conn

  alias ImagePlug.OutputNegotiation
  alias ImagePlug.Transform.Output

  @enforce_keys [:chain, :format, :headers, :reason]
  defstruct @enforce_keys

  @type reason() :: :auto | :source
  @type t() :: %__MODULE__{
          chain: ImagePlug.TransformChain.t(),
          format: :avif | :webp | :jpeg | :png,
          headers: [{String.t(), String.t()}],
          reason: reason()
        }

  @spec preselect(Plug.Conn.t(), ImagePlug.TransformChain.t(), keyword()) ::
          {:ok, t()} | :defer | {:error, :not_acceptable}
  def preselect(%Plug.Conn{} = conn, chain, opts) do
    conn
    |> accept_header()
    |> OutputNegotiation.preselect(output_negotiation_opts(opts))
    |> case do
      {:ok, format} -> {:ok, selection(chain, format, :auto)}
      :defer -> :defer
      {:error, :not_acceptable} -> {:error, :not_acceptable}
    end
  end

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: accept_vary_headers()

  @spec negotiate(Plug.Conn.t(), atom() | nil, ImagePlug.TransformChain.t(), keyword()) ::
          {:ok, t()} | {:error, :not_acceptable | term()}
  def negotiate(%Plug.Conn{} = conn, source_format, chain, opts) do
    negotiation_opts =
      opts
      |> output_negotiation_opts()
      |> Keyword.put(:source_format, source_format)

    case OutputNegotiation.negotiate_selection(accept_header(conn), negotiation_opts) do
      {:ok, {mime_type, reason}} ->
        case OutputNegotiation.format(mime_type) do
          {:ok, format} -> {:ok, selection(chain, format, reason)}
          :error -> {:error, unsupported_output_format_error(mime_type)}
        end

      {:error, :not_acceptable} ->
        {:error, :not_acceptable}
    end
  end

  defp selection(chain, format, reason) do
    %__MODULE__{
      chain: append_output(chain, format),
      format: format,
      headers: accept_vary_headers(),
      reason: reason
    }
  end

  defp append_output(chain, selected_format) do
    chain ++ [{Output, %Output.OutputParams{format: selected_format}}]
  end

  defp accept_header(conn) do
    conn |> get_req_header("accept") |> Enum.join(",")
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
