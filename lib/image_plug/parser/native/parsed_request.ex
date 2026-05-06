defmodule ImagePlug.Parser.Native.ParsedRequest do
  @moduledoc false

  alias ImagePlug.Parser.Native.CacheRequest
  alias ImagePlug.Parser.Native.OutputRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.RequestPolicy
  alias ImagePlug.Parser.Native.ResponseRequest

  @enforce_keys [:signature, :source_kind, :source_path, :pipelines]
  defstruct @enforce_keys ++
              [
                output: %OutputRequest{},
                policy: %RequestPolicy{},
                cache: %CacheRequest{},
                response: %ResponseRequest{}
              ]

  @type output_format() :: :webp | :avif | :jpeg | :png | :best

  @type t() :: %__MODULE__{
          signature: String.t(),
          source_kind: :plain,
          source_path: [String.t()],
          pipelines: [PipelineRequest.t()],
          output: OutputRequest.t(),
          policy: RequestPolicy.t(),
          cache: CacheRequest.t(),
          response: ResponseRequest.t()
        }
end
