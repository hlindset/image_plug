defmodule ImagePlug.Runtime.ProcessorTest.FirstTransform do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  defstruct []

  def name(%__MODULE__{}), do: :first
  def validate(%__MODULE__{}), do: :ok

  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, %State{} = state) do
    %State{state | debug: true}
  end
end
