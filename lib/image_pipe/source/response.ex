defmodule ImagePipe.Source.Response do
  @moduledoc false

  defstruct stream: nil, path: nil

  @type t :: %__MODULE__{
          stream: Enumerable.t() | nil,
          path: Path.t() | nil
        }
end
