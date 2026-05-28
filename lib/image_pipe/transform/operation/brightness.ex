defmodule ImagePipe.Transform.Operation.Brightness do
  @moduledoc """
  Executable brightness adjustment operation.
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :brightness

  @impl ImagePipe.Transform
  def execute(%__MODULE__{value: value}, %State{} = state) do
    case Image.brightness(state.image, multiplier(value)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp multiplier(value), do: (100 + value) / 100
end
