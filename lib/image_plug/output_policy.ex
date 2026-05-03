defmodule ImagePlug.OutputPolicy do
  @moduledoc false

  import Plug.Conn

  alias ImagePlug.ImageFormat
  alias ImagePlug.OutputNegotiation
  alias ImagePlug.ProcessingRequest

  @enforce_keys [:mode, :modern_candidates, :headers, :quality]
  defstruct @enforce_keys

  @type format() :: :avif | :webp | :jpeg | :png
  @type mode() :: :source | :best | {:explicit, format()}
  @type reason() :: :explicit | :auto | :source

  @type t() :: %__MODULE__{
          mode: mode(),
          modern_candidates: [format()],
          headers: [{String.t(), String.t()}],
          quality: :default
        }

  @spec from_request(Plug.Conn.t(), ProcessingRequest.t(), keyword()) :: t()
  def from_request(%Plug.Conn{} = conn, %ProcessingRequest{format: nil}, opts) do
    %__MODULE__{
      mode: :source,
      modern_candidates: OutputNegotiation.modern_candidates(accept_header(conn), opts),
      headers: automatic_headers(),
      quality: :default
    }
  end

  def from_request(%Plug.Conn{}, %ProcessingRequest{format: format}, _opts) do
    %__MODULE__{
      mode: {:explicit, format},
      modern_candidates: [],
      headers: [],
      quality: :default
    }
  end

  @spec resolve_before_origin(t()) ::
          {:selected, format(), reason()} | :needs_source_format | :needs_encoded_evaluation
  def resolve_before_origin(%__MODULE__{mode: {:explicit, format}}),
    do: {:selected, format, :explicit}

  def resolve_before_origin(%__MODULE__{mode: :source, modern_candidates: [format | _rest]}),
    do: {:selected, format, :auto}

  def resolve_before_origin(%__MODULE__{mode: :source, modern_candidates: []}),
    do: :needs_source_format

  def resolve_before_origin(%__MODULE__{mode: :best}), do: :needs_encoded_evaluation

  @spec resolve_source_format(t(), format() | nil) ::
          {:selected, format(), :source} | {:error, :source_format_required}
  def resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    case ImageFormat.mime_type(source_format) do
      {:ok, _mime_type} -> {:selected, source_format, :source}
      :error -> {:error, :source_format_required}
    end
  end

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: [{"vary", "Accept"}]

  defp accept_header(conn), do: conn |> get_req_header("accept") |> Enum.join(",")
end
