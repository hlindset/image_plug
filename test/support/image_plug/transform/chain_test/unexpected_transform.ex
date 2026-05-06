defmodule ImagePlug.Transform.ChainTest.UnexpectedTransform do
  @moduledoc false

  alias ImagePlug.Transform.State

  defstruct []

  def name(%__MODULE__{}), do: :unexpected
  def validate(%__MODULE__{}), do: :ok
  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, state) do
    State.add_error(state, {__MODULE__, :should_not_run})
  end
end
