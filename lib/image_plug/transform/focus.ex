defmodule ImagePlug.Transform.Focus do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  @doc """
  The parsed operation used by `ImagePlug.Transform.Focus`.
  """
  defstruct [:type]

  @type t ::
          %__MODULE__{type: {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}}
          | %__MODULE__{type: State.focus_anchor()}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation), do: operation

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :focus

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:coordinate, left, top}}, %State{} = state) do
    left = to_pixels(image_width(state), left)
    top = to_pixels(image_height(state), top)

    focus =
      {:coordinate, max(min(image_width(state), left), 0), max(min(image_height(state), top), 0)}

    state
    |> set_focus(focus)
    |> maybe_draw_debug_dot()
  end

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:anchor, x, y}}, %State{} = state) do
    state
    |> set_focus({:anchor, x, y})
    |> maybe_draw_debug_dot()
  end

  defp maybe_draw_debug_dot(%State{debug: true, focus: focus} = state) do
    {left, top} = anchor_to_pixels(focus, image_width(state), image_height(state))
    draw_debug_dot(state, left, top)
  end

  defp maybe_draw_debug_dot(%State{} = state), do: state

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:type])

    case Map.fetch!(attrs, :type) do
      {:coordinate, left, top} ->
        validate_position!(:left, left)
        validate_position!(:top, top)
        attrs

      {:anchor, x, y} when x in [:left, :center, :right] and y in [:top, :center, :bottom] ->
        attrs

      type ->
        raise ArgumentError, "invalid focus type: #{inspect(type)}"
    end
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown focus option(s): #{keys}"
    end
  end

  defp validate_position!(_field, value) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:pixels, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:percent, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:scale, value}) when is_number(value) and value >= 0, do: :ok

  defp validate_position!(_field, {:scale, numerator, denominator})
       when is_number(numerator) and is_number(denominator) and numerator >= 0 and denominator > 0,
       do: :ok

  defp validate_position!(field, value),
    do: raise(ArgumentError, "invalid focus #{field}: #{inspect(value)}")
end
