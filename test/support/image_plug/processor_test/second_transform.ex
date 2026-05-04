defmodule ImagePlug.ProcessorTest.SecondTransform do
  @moduledoc false

  alias ImagePlug.TransformState

  defstruct [:test_pid, :ref]

  def execute(%TransformState{} = state, %__MODULE__{test_pid: test_pid, ref: ref}) do
    send(test_pid, {:pipeline_event, ref, :second_transform_ran})
    state
  end
end
