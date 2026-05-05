defmodule ImagePlug.Transform.Focus do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.TransformState

  @doc """
  The parsed operation used by `ImagePlug.Transform.Focus`.
  """
  defstruct [:type]

  @type t ::
          %__MODULE__{type: {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}}
          | %__MODULE__{type: TransformState.focus_anchor()}

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
  def execute(%__MODULE__{type: {:coordinate, left, top}}, %TransformState{} = state) do
    left = to_pixels(image_width(state), left)
    top = to_pixels(image_height(state), top)

    focus =
      {:coordinate, max(min(image_width(state), left), 0), max(min(image_height(state), top), 0)}

    state
    |> set_focus(focus)
    |> maybe_draw_debug_dot()
  end

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:anchor, x, y}}, %TransformState{} = state) do
    state
    |> set_focus({:anchor, x, y})
    |> maybe_draw_debug_dot()
  end

  defp maybe_draw_debug_dot(%TransformState{debug: true, focus: focus} = state) do
    {left, top} = anchor_to_pixels(focus, image_width(state), image_height(state))
    draw_debug_dot(state, left, top)
  end

  defp maybe_draw_debug_dot(%TransformState{} = state), do: state

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch!(attrs, :type) do
      {:coordinate, _left, _top} ->
        attrs

      {:anchor, x, y} when x in [:left, :center, :right] and y in [:top, :center, :bottom] ->
        attrs

      type ->
        raise ArgumentError, "invalid focus type: #{inspect(type)}"
    end
  end
end
