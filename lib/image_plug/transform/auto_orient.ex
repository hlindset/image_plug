defmodule ImagePlug.Transform.AutoOrient do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation), do: operation

  def new!(attrs) when attrs in [%{}, []], do: %__MODULE__{}

  def new!(attrs), do: raise(ArgumentError, "invalid auto-orient options: #{inspect(attrs)}")

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :auto_orient

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.autorotate(state.image) do
      {:ok, {image, _flags}} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end
end
