defmodule ImagePlug.PlanTest.RuntimeOnlyTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :runtime_only
  def validate(%__MODULE__{}), do: :ok
  def metadata(%__MODULE__{}), do: %{access: :random}
  def execute(%__MODULE__{}, state), do: state
end
