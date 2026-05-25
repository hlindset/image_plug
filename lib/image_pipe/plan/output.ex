defmodule ImagePipe.Plan.Output do
  @moduledoc """
  Requested output intent before runtime format negotiation.
  """

  @enforce_keys [:mode]
  defstruct mode: :automatic, quality: :default, format_qualities: %{}

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()}
        }
end
