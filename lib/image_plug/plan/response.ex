defmodule ImagePlug.Plan.Response do
  @moduledoc false

  alias ImagePlug.Plan.Response.Filename

  defstruct disposition: :default, filename: nil

  @type t :: %__MODULE__{
          disposition: :default | :inline | :attachment,
          filename: Filename.t() | nil
        }
end
