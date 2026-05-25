defmodule ImagePipe.Transform.ChainTest.FailingTransform do
  @moduledoc false

  defstruct []

  def name(%__MODULE__{}), do: :failing
  def metadata(%__MODULE__{}), do: %{access: :random}

  def execute(%__MODULE__{}, _state), do: {:error, {__MODULE__, :failed}}
end
