defmodule ImagePlug.ProcessorTest.FirstTransform do
  @moduledoc false

  alias ImagePlug.Transform.State

  defstruct []

  def new(attrs), do: {:ok, new!(attrs)}
  def new!(%__MODULE__{} = operation), do: operation
  def new!(attrs), do: struct!(__MODULE__, attrs)

  def name(%__MODULE__{}), do: :first

  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, %State{} = state) do
    %State{state | debug: true}
  end
end
