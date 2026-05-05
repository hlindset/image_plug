defmodule ImagePlug.ParamParser.Native.ParsedRequest do
  @moduledoc false

  @enforce_keys [:signature, :source_kind, :source_path, :pipelines]
  defstruct @enforce_keys ++ [output_format: nil]

  @type output_format() :: :webp | :avif | :jpeg | :png | :best

  @type t() :: %__MODULE__{
          signature: String.t(),
          source_kind: :plain,
          source_path: [String.t()],
          pipelines: [ImagePlug.ParamParser.Native.PipelineRequest.t()],
          output_format: output_format() | nil
        }
end
