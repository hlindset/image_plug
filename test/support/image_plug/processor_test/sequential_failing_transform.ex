defmodule ImagePlug.ProcessorTest.SequentialFailingTransform do
  @moduledoc false

  alias ImagePlug.TransformState

  defstruct []

  def metadata(%__MODULE__{}), do: %{access: :sequential}

  def execute(state, %__MODULE__{}) do
    TransformState.add_error(state, {__MODULE__, :failed})
  end
end
