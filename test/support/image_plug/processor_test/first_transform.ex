defmodule ImagePlug.ProcessorTest.FirstTransform do
  @moduledoc false

  alias ImagePlug.TransformState

  defstruct []

  def execute(%TransformState{} = state, %__MODULE__{}) do
    %TransformState{state | debug: true}
  end
end
