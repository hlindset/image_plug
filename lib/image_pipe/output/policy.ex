defmodule ImagePipe.Output.Policy do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2]

  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Output

  @enforce_keys [
    :mode,
    :modern_candidates,
    :headers,
    :quality,
    :format_qualities,
    :strip_metadata,
    :keep_copyright,
    :color_profile
  ]
  defstruct @enforce_keys

  @passthrough_source_formats [:jpeg, :png]

  @type format() :: Format.output_format()
  @type source_format() :: Format.source_format()
  @type quality() :: :default | {:quality, 1..100}
  @type mode() :: :source | {:explicit, format()}

  @type t() :: %__MODULE__{
          mode: mode(),
          modern_candidates: [format()],
          headers: [{String.t(), String.t()}],
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: Output.color_profile()
        }

  @spec from_output_plan(Plug.Conn.t(), Output.t(), keyword()) :: t()
  def from_output_plan(%Plug.Conn{} = conn, %Output{mode: :automatic} = output, opts) do
    %__MODULE__{
      mode: :source,
      modern_candidates: Negotiation.modern_candidates(accept_header(conn), opts),
      headers: automatic_headers(),
      quality: output.quality,
      format_qualities: output.format_qualities,
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright,
      color_profile: output.color_profile
    }
  end

  def from_output_plan(%Plug.Conn{}, %Output{mode: {:explicit, format}} = output, _opts) do
    %__MODULE__{
      mode: {:explicit, format},
      modern_candidates: [],
      headers: [],
      quality: output.quality,
      format_qualities: output.format_qualities,
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright,
      color_profile: output.color_profile
    }
  end

  defp resolve_before_source_fetch(%__MODULE__{mode: {:explicit, format}}),
    do: {:selected, format, :explicit}

  defp resolve_before_source_fetch(%__MODULE__{
         mode: :source,
         modern_candidates: [format | _rest]
       }),
       do: {:selected, format, :auto}

  defp resolve_before_source_fetch(%__MODULE__{mode: :source, modern_candidates: []}),
    do: :needs_source_format

  @spec resolve(t(), source_format() | nil) ::
          {:ok, Resolved.t()}
          | {:error, :source_format_required}
          | {:needs_final_image_alpha, :source}
  def resolve(%__MODULE__{} = policy, source_format) do
    case resolve_before_source_fetch(policy) do
      {:selected, format, _reason} ->
        {:ok, resolved(policy, format)}

      :needs_source_format ->
        case resolve_source_format(policy, source_format) do
          {:selected, format, _reason} -> {:ok, resolved(policy, format)}
          {:needs_final_image_alpha, _reason} = pending -> pending
          {:error, _reason} = error -> error
        end
    end
  end

  @spec ensure_capable(t(), keyword()) :: :ok | {:error, {:unsupported_output_format, format()}}
  def ensure_capable(%__MODULE__{mode: {:explicit, format}}, opts) do
    if Capabilities.supports?(format, opts) do
      :ok
    else
      {:error, {:unsupported_output_format, format}}
    end
  end

  def ensure_capable(%__MODULE__{mode: :source}, _opts), do: :ok

  # Only baseline formats pass through as-is. Modern source formats (avif/webp)
  # are reached here only when the client accepted no modern format, so passing
  # them through would serve an unaccepted (possibly undecodable) format; route
  # them and source-only formats to the raster-by-alpha path instead.
  defp resolve_source_format(%__MODULE__{mode: :source}, source_format) do
    cond do
      source_format in @passthrough_source_formats -> {:selected, source_format, :source}
      Format.source_format?(source_format) -> {:needs_final_image_alpha, :source}
      true -> {:error, :source_format_required}
    end
  end

  @spec resolve_final_image_alpha(t(), boolean()) :: Resolved.t()
  def resolve_final_image_alpha(%__MODULE__{} = policy, true),
    do: resolved(policy, :png)

  def resolve_final_image_alpha(%__MODULE__{} = policy, false),
    do: resolved(policy, :jpeg)

  @spec automatic_headers() :: [{String.t(), String.t()}]
  def automatic_headers, do: [{"vary", "Accept"}]

  defp resolved(%__MODULE__{} = policy, format) do
    %Resolved{
      format: format,
      quality: effective_quality(policy, format),
      response_headers: policy.headers,
      strip_metadata: policy.strip_metadata,
      keep_copyright: policy.keep_copyright,
      color_profile: policy.color_profile
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
