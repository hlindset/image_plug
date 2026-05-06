defmodule ImagePlug.Runtime.ProcessorTest.SequentialFailingTransform do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  defstruct []

  def name(%__MODULE__{}), do: :sequential_failing
  def validate(%__MODULE__{}), do: :ok

  def metadata(%__MODULE__{}), do: %{access: :sequential}

  def execute(%__MODULE__{}, state) do
    State.add_error(state, {__MODULE__, :failed})
  end
end
