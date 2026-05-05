defmodule ImagePlug.Transform.ChainTest.FailingTransform do
  @moduledoc false

  alias ImagePlug.Transform.State

  defstruct []

  def new(attrs), do: {:ok, new!(attrs)}
  def new!(%__MODULE__{} = operation), do: operation
  def new!(attrs), do: struct!(__MODULE__, attrs)
  def name(%__MODULE__{}), do: :failing
  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, state) do
    State.add_error(state, {__MODULE__, :failed})
  end
end
