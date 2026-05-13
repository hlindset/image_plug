defmodule ImagePlug.Transform.ChainTest.UnexpectedTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :unexpected
  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, _state), do: {:error, {__MODULE__, :should_not_run}}
end
