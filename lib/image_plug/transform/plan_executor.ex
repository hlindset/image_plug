defmodule ImagePlug.Transform.PlanExecutor do
  @moduledoc false

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Resize, as: PlanResize
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  @spec execute(Plan.t(), State.t(), SourceMetadata.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{} = plan, %State{} = state, %SourceMetadata{} = metadata, opts) do
    with {:ok, pipelines} <- ImagePlug.Transform.validate_prefetch_safe_plan(plan) do
      execute_pipelines(pipelines, state, metadata, opts)
    end
  end

  defp execute_pipelines(pipelines, %State{} = state, %SourceMetadata{} = metadata, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state, metadata, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, metadata, opts) do
    Enum.reduce_while(operations, {:ok, state}, fn operation, {:ok, state} ->
      case execute_operation(operation, state, metadata, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_operation(operation, %State{} = state, %SourceMetadata{} = metadata, opts) do
    operation
    |> executable_operations(state, metadata, opts)
    |> then(&Chain.execute(state, &1))
  end

  defp executable_operations(%PlanResize{mode: :fit} = operation, %State{}, _metadata, _opts) do
    [%Resize{rule: tagged_dimension_rule(operation, :fit)}]
  end

  defp executable_operations(%PlanResize{mode: :cover} = operation, %State{}, _metadata, _opts) do
    operation
    |> tagged_dimension_rule(:cover)
    |> cover_resize_and_crop(tagged_executable_gravity(operation.guide), crop_offsets(operation))
  end

  defp executable_operations(%PlanResize{mode: :stretch} = operation, %State{}, _metadata, _opts) do
    [%Resize{rule: tagged_dimension_rule(operation, :stretch)}]
  end

  defp executable_operations(
         %PlanResize{mode: :auto} = operation,
         %State{} = state,
         _metadata,
         _opts
       ) do
    branch =
      resize_auto_branch(
        Image.width(state.image),
        Image.height(state.image),
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )

    rule = tagged_dimension_rule(operation, branch)

    tagged_executable_resize_operations(branch, rule, operation)
  end

  defp executable_operations(%CropGuided{} = operation, %State{}, _metadata, _opts) do
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

  defp executable_operations(%CropRegion{} = operation, %State{}, _metadata, _opts) do
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

  defp executable_operations(%Canvas{} = operation, %State{}, _metadata, _opts) do
    width = canvas_dimension(operation.width)
    height = canvas_dimension(operation.height)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: tagged_executable_gravity(operation.placement),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        background: operation.background
      }
    ]
  end

  defp executable_operations(%AutoOrient{} = operation, %State{}, _metadata, _opts),
    do: [operation]

  defp executable_operations(%Rotate{} = operation, %State{}, _metadata, _opts), do: [operation]
  defp executable_operations(%Flip{} = operation, %State{}, _metadata, _opts), do: [operation]

  defp tagged_executable_resize_operations(:cover, %DimensionRule{} = rule, operation) do
    cover_resize_and_crop(
      rule,
      tagged_executable_gravity(operation.guide),
      crop_offsets(operation)
    )
  end

  defp tagged_executable_resize_operations(:fit, %DimensionRule{} = rule, _operation) do
    [%Resize{rule: rule}]
  end

  defp cover_resize_and_crop(%DimensionRule{} = rule, gravity, {x_offset, y_offset}) do
    [
      %Resize{rule: rule},
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: gravity,
        x_offset: x_offset,
        y_offset: y_offset,
        target_rule: rule
      }
    ]
  end

  defp tagged_dimension_rule(operation, mode) do
    %DimensionRule{
      mode: dimension_rule_mode(mode),
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

  defp dimension_rule_mode(:cover), do: :fill
  defp dimension_rule_mode(:fit), do: :fit
  defp dimension_rule_mode(:stretch), do: :force

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

  defp crop_offsets(operation), do: {operation.x_offset, operation.y_offset}

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
