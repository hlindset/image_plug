defmodule ImagePipe.Transform.ChainTest.UnexpectedTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :unexpected

  def execute(%__MODULE__{}, _state), do: {:error, {__MODULE__, :should_not_run}}
end
