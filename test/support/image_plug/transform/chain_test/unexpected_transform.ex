defmodule ImagePlug.Transform.ChainTest.UnexpectedTransform do
  @moduledoc false

  alias ImagePlug.Transform.State

  defstruct []

  def new(attrs), do: {:ok, new!(attrs)}
  def new!(%__MODULE__{} = operation), do: operation
  def new!(attrs), do: struct!(__MODULE__, attrs)
  def name(%__MODULE__{}), do: :unexpected
  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, state) do
    State.add_error(state, {__MODULE__, :should_not_run})
  end
end
