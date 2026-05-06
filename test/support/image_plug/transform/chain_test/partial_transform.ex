defmodule ImagePlug.Transform.ChainTest.PartialTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :partial
  def execute(%__MODULE__{}, state), do: state
end
