defmodule ImagePlug.PlanTest.PartialTransform do
  @moduledoc false

  defstruct []

  def new(attrs), do: {:ok, new!(attrs)}
  def new!(%__MODULE__{} = operation), do: operation
  def new!(attrs), do: struct!(__MODULE__, attrs)
  def name(%__MODULE__{}), do: :partial
  def execute(%__MODULE__{}, state), do: state
end
