defmodule ImagePlug.Transform.ExtendCanvas do
  @moduledoc """
  Represents a product-neutral canvas expansion operation that embeds the
  current image into a same-size-or-larger canvas.

  ## Construct When

  Construct `ExtendCanvas` when parser or planner code needs letterboxing,
  padding, or aspect-ratio canvas extension without changing the image content
  scale. Use it after resize-like operations when the requested output box is
  larger than the resized image, or when a dialect requests extension to a
  target aspect ratio.

  Native parser translations construct this operation for supported canvas
  extension requests such as dimension extension and extend-aspect-ratio
  requests. The URL option names remain parser concerns; this operation only
  models the neutral canvas semantics.

  ## Fields

  Required fields:

  - `rule`: either `{:dimensions, width, height}` or
    `{:aspect_ratio, {ratio_width, ratio_height}}`.

  Optional fields:

  - `gravity`: an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`. Defaults
    to center.
  - `x_offset`: numeric horizontal offset added after gravity placement.
    Defaults to `0.0`.
  - `y_offset`: numeric vertical offset added after gravity placement. Defaults
    to `0.0`.
  - `background`: background fill passed to `Image.embed/4`. Defaults to
    `:white`; `:transparent` is converted to an RGBA transparent color.

  Dimension rules accept non-negative numbers, `{:pixels, value}` with a
  non-negative value, or `:auto` on each axis. Aspect-ratio rules require
  positive numeric ratio components.

  ## Execution Semantics

  `execute/2` resolves the canvas size from `rule`, embeds
  `ImagePlug.Transform.State.image` into that canvas, stores the embedded image
  back into the state, and resets focus. If dimensions are invalid or embedding
  fails, execution records `{__MODULE__, reason}` in the state errors.

  For `{:dimensions, width, height}`, each requested dimension resolves against
  the current image size. `:auto` keeps the current size on that axis. The final
  canvas width and height are never smaller than the current image.

  For `{:aspect_ratio, {ratio_width, ratio_height}}`, execution expands the
  canvas on the needed axis so the final canvas has the requested ratio while
  preserving the full current image. The image is not resampled by this
  operation.

  Gravity chooses the base image placement in the new canvas. Offsets are
  rounded and added to that placement after gravity resolution, then passed to
  image embedding.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Canvas extension needs the whole
  current image available for embedding into a new canvas and is not treated as
  safe for optimized sequential source decoding.

  ## Examples

      canvas = %ImagePlug.Transform.ExtendCanvas{
        rule: {:dimensions, {:pixels, 400}, {:pixels, 300}},
        gravity: {:anchor, :center, :center},
        x_offset: 0.0,
        y_offset: 0.0
      }

  A Native parser translation for extend-aspect-ratio syntax would construct an
  `ExtendCanvas` operation with an `{:aspect_ratio, ratio}` rule.
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

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
  def name(%__MODULE__{}), do: :extend_canvas

  @impl ImagePlug.Transform
  def validate(%__MODULE__{} = operation) do
    with :ok <- validate_rule(operation.rule),
         :ok <- Validation.anchor("extend canvas", :gravity, operation.gravity),
         :ok <- Validation.number("extend canvas", :x_offset, operation.x_offset) do
      Validation.number("extend canvas", :y_offset, operation.y_offset)
    end
  end

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    with {:ok, {width, height}} <- canvas_dimensions(state, operation.rule),
         {:ok, image} <- embed_image(state, operation, width, height) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, reason} -> add_error(state, {__MODULE__, reason})
    end
  end

  defp canvas_dimensions(%State{} = state, {:dimensions, width, height}) do
    width = canvas_dimension(image_width(state), width)
    height = canvas_dimension(image_height(state), height)

    {:ok, {max(image_width(state), width), max(image_height(state), height)}}
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

  defp validate_rule({:dimensions, width, height}) do
    with :ok <- Validation.non_negative_dimension_or_auto("extend canvas", :width, width) do
      Validation.non_negative_dimension_or_auto("extend canvas", :height, height)
    end
  end

  defp validate_rule({:aspect_ratio, {width, height}})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_rule(rule) do
    {:error, ArgumentError.exception("invalid extend canvas rule: #{inspect(rule)}")}
  end
end
