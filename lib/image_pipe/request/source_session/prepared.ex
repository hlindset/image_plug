defmodule ImagePipe.Request.SourceSession.Prepared do
  @moduledoc false

  alias ImagePipe.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :resolved_output]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          resolved_output: Resolved.t()
        }
end
