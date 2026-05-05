defmodule ImagePlug.ProcessorTest.SequentialFailingTransform do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  defstruct []

  def new(attrs), do: {:ok, new!(attrs)}
  def new!(%__MODULE__{} = operation), do: operation
  def new!(attrs), do: struct!(__MODULE__, attrs)

  def name(%__MODULE__{}), do: :sequential_failing

  def metadata(%__MODULE__{}), do: %{access: :sequential}

  def execute(%__MODULE__{}, state) do
    State.add_error(state, {__MODULE__, :failed})
  end
end
