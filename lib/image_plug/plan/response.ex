defmodule ImagePlug.Plan.Response do
  @moduledoc false

  defstruct disposition: :default, filename: nil

  @type t :: %__MODULE__{
          disposition: :default | :inline | :attachment,
          filename: String.t() | nil
        }
end
