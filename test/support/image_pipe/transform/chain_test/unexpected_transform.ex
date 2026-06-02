defmodule ImagePipe.Transform.ChainTest.UnexpectedTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :unexpected

  def requires_materialization?(%__MODULE__{}), do: false

  def execute(%__MODULE__{}, _state), do: {:error, {__MODULE__, :should_not_run}}
end
