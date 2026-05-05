defmodule ImagePlug.Transform.ExtendCanvas do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  @default_gravity {:anchor, :center, :center}

  defstruct rule: nil,
            gravity: @default_gravity,
            x_offset: 0.0,
            y_offset: 0.0,
            background: :white

  @type canvas_rule() ::
          {:dimensions, ImagePlug.imgp_length() | :auto, ImagePlug.imgp_length() | :auto}
          | {:aspect_ratio, ImagePlug.imgp_ratio()}

  @type t :: %__MODULE__{
          rule: canvas_rule(),
          gravity: State.focus_anchor(),
          x_offset: number(),
          y_offset: number(),
          background: term()
        }

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
  def name(%__MODULE__{}), do: :extend_canvas

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    with {:ok, {width, height}} <- canvas_dimensions(state, operation.rule),
         {:ok, image} <- embed_image(state, operation, width, height) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  defp canvas_dimensions(%State{} = state, {:dimensions, width, height}) do
    width = canvas_dimension(image_width(state), width)
    height = canvas_dimension(image_height(state), height)

    {:ok, {max(image_width(state), width), max(image_height(state), height)}}
  rescue
    ArgumentError -> {:error, {:invalid_canvas_dimensions, {width, height}}}
  end

  defp canvas_dimensions(%State{} = state, {:aspect_ratio, {ratio_width, ratio_height}})
       when is_number(ratio_width) and is_number(ratio_height) and ratio_width > 0 and
              ratio_height > 0 do
    target_ratio = ratio_width / ratio_height
    source_ratio = image_width(state) / image_height(state)

    {width, height} =
      if source_ratio > target_ratio do
        {image_width(state), round(image_width(state) / target_ratio)}
      else
        {round(image_height(state) * target_ratio), image_height(state)}
      end

    {:ok, {max(image_width(state), width), max(image_height(state), height)}}
  end

  defp canvas_dimensions(_state, rule), do: {:error, {:invalid_canvas_rule, rule}}

  defp embed_image(%State{} = state, %__MODULE__{} = operation, width, height) do
    x = offset(:x, operation.gravity, operation.x_offset, image_width(state), width)
    y = offset(:y, operation.gravity, operation.y_offset, image_height(state), height)

    Image.embed(state.image, width, height,
      x: x,
      y: y,
      background_color: background_color(operation.background)
    )
  end

  defp offset(axis, gravity, configured_offset, image_size, canvas_size) do
    base_offset(axis, gravity, image_size, canvas_size) + round(configured_offset)
  end

  defp base_offset(:x, {:anchor, :left, _y}, _image_size, _canvas_size), do: 0

  defp base_offset(:x, {:anchor, :center, _y}, image_size, canvas_size),
    do: div(canvas_size - image_size, 2)

  defp base_offset(:x, {:anchor, :right, _y}, image_size, canvas_size),
    do: canvas_size - image_size

  defp base_offset(:y, {:anchor, _x, :top}, _image_size, _canvas_size), do: 0

  defp base_offset(:y, {:anchor, _x, :center}, image_size, canvas_size),
    do: div(canvas_size - image_size, 2)

  defp base_offset(:y, {:anchor, _x, :bottom}, image_size, canvas_size),
    do: canvas_size - image_size

  defp canvas_dimension(current_size, :auto), do: current_size

  defp canvas_dimension(_current_size, {:pixels, value}) when is_number(value) and value >= 0,
    do: round(value)

  defp canvas_dimension(_current_size, value) when is_number(value) and value >= 0,
    do: round(value)

  defp canvas_dimension(current_size, size_unit), do: to_pixels(current_size, size_unit)

  defp background_color(:transparent), do: [0, 0, 0, 0]
  defp background_color({:color, color}), do: color
  defp background_color(color), do: color

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:rule, :gravity, :x_offset, :y_offset, :background])
    validate_rule!(Map.fetch!(attrs, :rule))
    validate_gravity!(Map.get(attrs, :gravity, @default_gravity))
    validate_offset!(:x_offset, Map.get(attrs, :x_offset, 0.0))
    validate_offset!(:y_offset, Map.get(attrs, :y_offset, 0.0))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown extend canvas option(s): #{keys}"
    end
  end

  defp validate_rule!({:dimensions, width, height}) do
    validate_dimension_or_auto!(:width, width)
    validate_dimension_or_auto!(:height, height)
  end

  defp validate_rule!({:aspect_ratio, {width, height}})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_rule!(rule),
    do: raise(ArgumentError, "invalid extend canvas rule: #{inspect(rule)}")

  defp validate_dimension_or_auto!(_field, :auto), do: :ok

  defp validate_dimension_or_auto!(_field, {:pixels, value}) when is_number(value) and value >= 0,
    do: :ok

  defp validate_dimension_or_auto!(_field, value) when is_number(value) and value >= 0,
    do: :ok

  defp validate_dimension_or_auto!(field, value),
    do: raise(ArgumentError, "invalid extend canvas #{field}: #{inspect(value)}")

  defp validate_gravity!({:anchor, x, y})
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: :ok

  defp validate_gravity!(gravity),
    do: raise(ArgumentError, "invalid extend canvas gravity: #{inspect(gravity)}")

  defp validate_offset!(_field, value) when is_number(value), do: :ok

  defp validate_offset!(field, value),
    do: raise(ArgumentError, "invalid extend canvas #{field}: #{inspect(value)}")
end
