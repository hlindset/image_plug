defmodule ImagePlug.PlanTest.PartialTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :partial
  def metadata(%__MODULE__{}), do: %{access: :random}
  def execute(%__MODULE__{}, state), do: state
end
