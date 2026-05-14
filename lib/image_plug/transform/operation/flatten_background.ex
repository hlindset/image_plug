defmodule ImagePlug.Transform.Operation.FlattenBackground do
  @moduledoc """
  Executable alpha flattening operation.
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  @enforce_keys [:color]
  defstruct @enforce_keys

  @type rgb :: [0..255]
  @type t :: %__MODULE__{color: rgb()}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :flatten_background

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{color: color}, %State{} = state) do
    case Image.flatten(state.image, background_color: color) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end
end
