defmodule ImagePlug.Runtime.ProcessorTest.SequentialFailingTransform do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  defstruct []

  def name(%__MODULE__{}), do: :sequential_failing

  def metadata(%__MODULE__{}), do: %{access: :sequential}

  def execute(%__MODULE__{}, _state), do: {:error, {__MODULE__, :failed}}
end
