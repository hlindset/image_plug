defmodule ImagePipe.Output.Resolved do
  @moduledoc false

  @enforce_keys [:format, :quality, :response_headers]
  defstruct @enforce_keys

  @type format :: ImagePipe.Format.output_format()
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          format: format(),
          quality: quality(),
          response_headers: [{String.t(), String.t()}]
        }
end
