defmodule ImagePlug.Transform.PlanExecutor do
  @moduledoc false

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Color
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.FlattenBackground, as: PlanFlattenBackground
  alias ImagePlug.Plan.Operation.Padding, as: PlanPadding
  alias ImagePlug.Plan.Operation.Resize, as: PlanResize
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.FlattenBackground
  alias ImagePlug.Transform.Operation.Padding
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.State

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{pipelines: pipelines}, %State{} = state, _opts) do
    execute_pipelines(pipelines, state)
  end

  defp execute_pipelines(pipelines, %State{} = state) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state) do
    initial_context = %{effective_padding_scale: nil}

    Enum.reduce_while(operations, {:ok, state, initial_context}, fn operation,
                                                                    {:ok, state, context} ->
      context = update_execution_context(operation, state, context)

      case execute_operation(operation, state, context) do
        {:ok, %State{} = state} -> {:cont, {:ok, state, context}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, _context} -> {:ok, state}
      {:error, _reason} = error -> error
    end
  end

  defp execute_operation(operation, %State{} = state, context) do
    operation
    |> executable_operations(state, context)
    |> then(&Chain.execute(state, &1))
  end

  defp update_execution_context(%PlanResize{} = operation, %State{} = state, context) do
    scale = resize_padding_scale(operation, state)

    %{context | effective_padding_scale: scale}
  end

  defp update_execution_context(_operation, %State{}, context), do: context

  defp executable_operations(%PlanResize{mode: :fit} = operation, %State{}, _context) do
    [resize_from(operation, :fit)]
  end

  defp executable_operations(%PlanResize{mode: :cover} = operation, %State{} = state, _context) do
    operation
    |> resize_from(:cover)
    |> cover_resize_and_crop(
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp executable_operations(%PlanResize{mode: :stretch} = operation, %State{}, _context) do
    [resize_from(operation, :stretch)]
  end

  defp executable_operations(%PlanResize{mode: :auto} = operation, %State{} = state, _context) do
    branch =
      resize_auto_branch(
        Image.width(state.image),
        Image.height(state.image),
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )

    resize = resize_from(operation, branch)

    tagged_executable_resize_operations(branch, resize, operation, state)
  end

  defp executable_operations(%CropGuided{} = operation, %State{}, _context) do
    [
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: :gravity,
        gravity: tagged_executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset
      }
    ]
  end

  defp executable_operations(%CropRegion{} = operation, %State{}, _context) do
    [
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: %{
          left: crop_coordinate(operation.x),
          top: crop_coordinate(operation.y)
        }
      }
    ]
  end

  defp executable_operations(%Canvas{} = operation, %State{}, _context) do
    width = canvas_dimension(operation.width)
    height = canvas_dimension(operation.height)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: tagged_executable_gravity(operation.placement),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        background: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanPadding{} = operation, %State{} = state, context) do
    scale = effective_padding_scale(operation, state, context)

    [
      %Padding{
        top: scaled_padding_side(operation.top, scale),
        right: scaled_padding_side(operation.right, scale),
        bottom: scaled_padding_side(operation.bottom, scale),
        left: scaled_padding_side(operation.left, scale),
        fill: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanFlattenBackground{} = operation, %State{}, _context) do
    [%FlattenBackground{color: Color.to_rgb_list(operation.color)}]
  end

  defp executable_operations(%AutoOrient{} = operation, %State{}, _context),
    do: [operation]

  defp executable_operations(%Rotate{} = operation, %State{}, _context), do: [operation]
  defp executable_operations(%Flip{} = operation, %State{}, _context), do: [operation]

  defp tagged_executable_resize_operations(
         :cover,
         %Resize{} = resize,
         operation,
         %State{} = state
       ) do
    cover_resize_and_crop(
      resize,
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp tagged_executable_resize_operations(:fit, %Resize{} = resize, _operation, %State{}) do
    [resize]
  end

  defp cover_resize_and_crop(%Resize{} = resize, %State{} = state, gravity, {x_offset, y_offset}) do
    dimensions =
      Resize.resolve_dimensions(resize,
        source_width: Image.width(state.image),
        source_height: Image.height(state.image)
      )

    [
      resize,
      %Crop{
        width: dimensions.target_width,
        height: dimensions.target_height,
        crop_from: :gravity,
        gravity: gravity,
        x_offset: x_offset,
        y_offset: y_offset,
        offset_scale: dimensions.effective_dpr
      }
    ]
  end

  defp resize_from(operation, mode) do
    %Resize{
      mode: resize_mode(mode),
      width: tagged_executable_resize_dimension(operation.width),
      height: tagged_executable_resize_dimension(operation.height),
      min_width: tagged_executable_optional_resize_dimension(operation.min_width),
      min_height: tagged_executable_optional_resize_dimension(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      dpr: tagged_dpr_float(operation.dpr),
      enlarge: operation.enlargement == :allow
    }
  end

  defp resize_mode(:cover), do: :fill
  defp resize_mode(:fit), do: :fit
  defp resize_mode(:stretch), do: :force

  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}

  defp tagged_executable_optional_resize_dimension(nil), do: nil

  defp tagged_executable_optional_resize_dimension(dimension),
    do: tagged_executable_resize_dimension(dimension)

  defp crop_dimension(:full_axis), do: :auto
  defp crop_dimension({:px, value}), do: {:pixels, value}
  defp crop_dimension({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp crop_coordinate({:px, value}), do: {:pixels, value}
  defp crop_coordinate({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp canvas_dimension(:auto), do: :auto
  defp canvas_dimension({:px, value}), do: {:pixels, value}
  defp canvas_dimension({:ratio, numerator, denominator}), do: {:ratio, numerator / denominator}

  defp canvas_rule({:ratio, width}, {:ratio, height}), do: {:aspect_ratio, {width, height}}
  defp canvas_rule(width, height), do: {:dimensions, width, height}

  defp executable_fill(:transparent), do: :transparent
  defp executable_fill({:solid, %Color{} = color}), do: {:color, Color.to_rgb_list(color)}

  defp effective_padding_scale(%PlanPadding{}, %State{}, %{effective_padding_scale: scale})
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:ratio, numerator, denominator}},
         %State{},
         _context
       ),
    do: numerator / denominator

  defp resize_padding_scale(%PlanResize{enlargement: :allow} = operation, %State{}),
    do: tagged_dpr_float(operation.dpr)

  defp resize_padding_scale(%PlanResize{} = operation, %State{} = state) do
    requested_scale = tagged_dpr_float(operation.dpr)
    branch = plan_resize_branch(operation, state)
    resize = resize_from(operation, branch)

    base =
      %{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(
        source_width: Image.width(state.image),
        source_height: Image.height(state.image)
      )

    max_without_enlarge = max_padding_scale_without_enlarge(base, state)
    compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge)

    clamp_padding_scale(compensated, max_without_enlarge)
  end

  defp max_padding_scale_without_enlarge(%{requested_width: :auto, requested_height: :auto}, %State{}),
    do: :unbounded

  defp max_padding_scale_without_enlarge(%{requested_width: width, requested_height: height}, %State{} = state) do
    min(Image.width(state.image) / width, Image.height(state.image) / height)
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, :unbounded), do: requested_scale

  defp compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge)
       when max_without_enlarge < 1.0 do
    requested_scale / max_without_enlarge
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, _max_without_enlarge),
    do: requested_scale

  defp clamp_padding_scale(scale, :unbounded), do: scale
  defp clamp_padding_scale(scale, max_without_enlarge), do: min(scale, max(max_without_enlarge, 1.0))

  defp plan_resize_branch(%PlanResize{mode: :fit}, %State{}), do: :fit
  defp plan_resize_branch(%PlanResize{mode: :cover}, %State{}), do: :cover
  defp plan_resize_branch(%PlanResize{mode: :stretch}, %State{}), do: :stretch

  defp plan_resize_branch(%PlanResize{mode: :auto} = operation, %State{} = state) do
    resize_auto_branch(
      Image.width(state.image),
      Image.height(state.image),
      tagged_logical_pixels(operation.width),
      tagged_logical_pixels(operation.height)
    )
  end

  defp scaled_padding_side({:px, value}, scale), do: round_half_to_even(value * scale)

  defp round_half_to_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  defp tagged_executable_gravity(:center), do: {:anchor, :center, :center}
  defp tagged_executable_gravity(:top_left), do: {:anchor, :left, :top}
  defp tagged_executable_gravity(:top), do: {:anchor, :center, :top}
  defp tagged_executable_gravity(:top_right), do: {:anchor, :right, :top}
  defp tagged_executable_gravity(:left), do: {:anchor, :left, :center}
  defp tagged_executable_gravity(:right), do: {:anchor, :right, :center}
  defp tagged_executable_gravity(:bottom_left), do: {:anchor, :left, :bottom}
  defp tagged_executable_gravity(:bottom), do: {:anchor, :center, :bottom}
  defp tagged_executable_gravity(:bottom_right), do: {:anchor, :right, :bottom}
  defp tagged_executable_gravity({:anchor, x, y}), do: {:anchor, x, y}

  defp tagged_executable_gravity({:focal, x, y}),
    do: {:fp, tagged_ratio_to_float(x), tagged_ratio_to_float(y)}

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp tagged_ratio_to_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp resize_auto_branch(current_width, current_height, target_width, target_height) do
    current_orientation = orientation(current_width, current_height)
    target_orientation = orientation(target_width, target_height)

    auto_branch(current_orientation, target_orientation)
  end

  defp auto_branch(:unknown, _target_orientation), do: :fit
  defp auto_branch(_current_orientation, :unknown), do: :fit
  defp auto_branch(orientation, orientation), do: :cover
  defp auto_branch(_current_orientation, _target_orientation), do: :fit

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width > height,
       do: :landscape

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width < height,
       do: :portrait

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width == height,
       do: :square

  defp orientation(_width, _height), do: :unknown
end
