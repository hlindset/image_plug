defmodule ImagePlug.Parser.Imgproxy.ResponseRequest do
  @moduledoc false

  defstruct filename: nil, disposition: :default

  @type t :: %__MODULE__{
          filename: String.t() | nil,
          disposition: :default | :inline | :attachment
        }
end
