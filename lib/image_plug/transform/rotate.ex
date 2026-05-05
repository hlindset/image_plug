defmodule ImagePlug.Transform.Rotate do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct [:angle]

  @type t :: %__MODULE__{angle: 0 | 90 | 180 | 270}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation) do
    operation
    |> Map.from_struct()
    |> validate_attrs!()

    operation
  end

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{angle: 0}, %State{} = state), do: state

  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case Image.rotate(state.image, angle) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:angle])
    validate_angle!(Map.fetch!(attrs, :angle))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown rotate option(s): #{keys}"
    end
  end

  defp validate_angle!(angle) when angle in [0, 90, 180, 270], do: :ok

  defp validate_angle!(angle),
    do: raise(ArgumentError, "invalid rotate angle: #{inspect(angle)}")
end
