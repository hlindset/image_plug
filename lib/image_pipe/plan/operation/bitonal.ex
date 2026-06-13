defmodule ImagePipe.Plan.Operation.Bitonal do
  @moduledoc """
  Semantic bitonal (1-bit black-and-white threshold) operation.
  Converts the image to grayscale then thresholds at 128: pixels >= 128
  become white (255) and pixels < 128 become black (0).
  """

  defstruct []

  @type t :: %__MODULE__{}
end
