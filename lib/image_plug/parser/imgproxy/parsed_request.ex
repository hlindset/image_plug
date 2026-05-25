defmodule ImagePlug.Parser.Imgproxy.ParsedRequest do
  @moduledoc false

  alias ImagePlug.Parser.Imgproxy.PipelineRequest

  @default_output %{format: nil, quality: :default, format_qualities: %{}}
  @default_policy %{expires: 0}
  @default_cache %{cachebuster: nil}
  @default_response %{filename: nil, disposition: :default}

  @enforce_keys [:signature, :source_kind, :source_path, :pipelines]
  defstruct @enforce_keys ++
              [
                output: @default_output,
                policy: @default_policy,
                cache: @default_cache,
                response: @default_response
              ]

  @type output_format() :: ImagePlug.Format.output_format() | :best
  @type quality() :: :default | {:quality, 1..100}
  @type output_request() :: %{
          required(:format) => output_format() | nil,
          required(:quality) => quality(),
          required(:format_qualities) => %{optional(output_format()) => quality()}
        }
  @type policy_request() :: %{required(:expires) => non_neg_integer()}
  @type cache_request() :: %{required(:cachebuster) => String.t() | nil}
  @type response_request() :: %{
          required(:filename) => String.t() | nil,
          required(:disposition) => :default | :inline | :attachment
        }

  @type t() :: %__MODULE__{
          signature: String.t(),
          source_kind: :plain,
          source_path: String.t(),
          pipelines: [PipelineRequest.t()],
          output: output_request(),
          policy: policy_request(),
          cache: cache_request(),
          response: response_request()
        }

  @spec output_request(keyword() | map()) :: output_request()
  def output_request(attrs \\ []), do: request_map(@default_output, attrs)

  @spec policy_request(keyword() | map()) :: policy_request()
  def policy_request(attrs \\ []), do: request_map(@default_policy, attrs)

  @spec cache_request(keyword() | map()) :: cache_request()
  def cache_request(attrs \\ []), do: request_map(@default_cache, attrs)

  @spec response_request(keyword() | map()) :: response_request()
  def response_request(attrs \\ []), do: request_map(@default_response, attrs)

  defp request_map(defaults, attrs) when is_list(attrs),
    do: request_map(defaults, Map.new(attrs))

  defp request_map(defaults, attrs) when is_map(attrs), do: Map.merge(defaults, attrs)
end
