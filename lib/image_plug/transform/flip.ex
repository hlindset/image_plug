defmodule ImagePlug.Transform.Flip do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct [:axis]

  @type t :: %__MODULE__{axis: :horizontal | :vertical | :both}

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
  def name(%__MODULE__{}), do: :flip

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{axis: :both}, %State{} = state) do
    with {:ok, image} <- Image.flip(state.image, :horizontal),
         {:ok, image} <- Image.flip(image, :vertical) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  def execute(%__MODULE__{axis: axis}, %State{} = state) do
    case Image.flip(state.image, axis) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:axis])
    validate_axis!(Map.fetch!(attrs, :axis))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown flip option(s): #{keys}"
    end
  end

  defp validate_axis!(axis) when axis in [:horizontal, :vertical, :both], do: :ok

  defp validate_axis!(axis),
    do: raise(ArgumentError, "invalid flip axis: #{inspect(axis)}")
end
