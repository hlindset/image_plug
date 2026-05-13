defmodule ImagePlug.Runtime.ProcessorTest.SecondTransform do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  defstruct [:test_pid, :ref]

  def name(%__MODULE__{}), do: :second

  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{test_pid: test_pid, ref: ref}, %State{} = state) do
    send(test_pid, {:pipeline_event, ref, :second_transform_ran})
    {:ok, state}
  end
end
