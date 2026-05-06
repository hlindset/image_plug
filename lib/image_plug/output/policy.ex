defmodule ImagePlug.Output.Policy do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias ImagePlug.Output.Format
  alias ImagePlug.Output.Negotiation
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan.Output

  @enforce_keys [:mode, :modern_candidates, :headers, :quality, :format_qualities]
  defstruct @enforce_keys

  @type format() :: :avif | :webp | :jpeg | :png
  @type quality() :: :default | {:quality, 1..100}
  @type mode() :: :source | :best | {:explicit, format()}
  @type reason() :: :explicit | :auto | :source

  @type t() :: %__MODULE__{
          mode: mode(),
          modern_candidates: [format()],
          headers: [{String.t(), String.t()}],
          quality: quality(),
          format_qualities: %{optional(format()) => quality()}
        }

  @spec from_output_plan(Plug.Conn.t(), Output.t(), keyword()) :: t()
  def from_output_plan(%Plug.Conn{} = conn, %Output{mode: :automatic} = output, opts) do
    %__MODULE__{
      mode: :source,
      modern_candidates: Negotiation.modern_candidates(accept_header(conn), opts),
      headers: automatic_headers(),
      quality: output.quality,
      format_qualities: output.format_qualities
    }
  end

  def from_output_plan(%Plug.Conn{}, %Output{mode: {:explicit, format}} = output, _opts) do
    %__MODULE__{
      mode: {:explicit, format},
      modern_candidates: [],
      headers: [],
      quality: output.quality,
      format_qualities: output.format_qualities
    }
  end

  @spec resolve_before_origin(t()) ::
          {:selected, format(), reason()} | :needs_source_format | {:needs_encoded_evaluation}
  def resolve_before_origin(%__MODULE__{mode: {:explicit, format}}),
    do: {:selected, format, :explicit}

  def resolve_before_origin(%__MODULE__{mode: :source, modern_candidates: [format | _rest]}),
    do: {:selected, format, :auto}

  def resolve_before_origin(%__MODULE__{mode: :source, modern_candidates: []}),
    do: :needs_source_format

  def resolve_before_origin(%__MODULE__{mode: :best}), do: {:needs_encoded_evaluation}

  @spec resolve(t(), format() | nil) ::
          {:ok, Resolved.t()} | {:error, :source_format_required} | {:needs_encoded_evaluation}
  def resolve(%__MODULE__{} = policy, source_format) do
    case resolve_before_origin(policy) do
      {:selected, format, _reason} ->
        {:ok, resolved(policy, format)}

      :needs_source_format ->
        case resolve_source_format(policy, source_format) do
          {:selected, format, _reason} -> {:ok, resolved(policy, format)}
          {:error, _reason} = error -> error
        end

      {:needs_encoded_evaluation} ->
        {:needs_encoded_evaluation}
    end
  end

  @spec resolve_source_format(t(), format() | nil) ::
          {:selected, format(), :source} | {:error, :source_format_required}
  def resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    case Format.mime_type(source_format) do
      {:ok, _mime_type} -> {:selected, source_format, :source}
      :error -> {:error, :source_format_required}
    end
  end

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: [{"vary", "Accept"}]

  defp resolved(%__MODULE__{} = policy, format) do
    %Resolved{
      format: format,
      quality: effective_quality(policy, format),
      representation_headers: policy.headers
    }
  end

  defp effective_quality(%__MODULE__{quality: {:quality, _value} = quality}, _format),
    do: quality

  defp effective_quality(
         %__MODULE__{quality: :default, format_qualities: format_qualities},
         format
       ),
       do: Map.get(format_qualities, format, :default)

  defp accept_header(conn), do: conn |> get_req_header("accept") |> Enum.join(",")
end
