defmodule ImagePlug.Transform.Resolver.Lowering do
  @moduledoc false

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Operation.AutoOrient
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Flip
  alias ImagePlug.Plan.Operation.Resize, as: PlanResize
  alias ImagePlug.Plan.Operation.ResizeCover
  alias ImagePlug.Plan.Operation.ResizeFit
  alias ImagePlug.Plan.Operation.ResizeStretch
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Plan.Operation.Rotate
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.AutoOrient, as: ExecutableAutoOrient
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip, as: ExecutableFlip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate, as: ExecutableRotate
  alias ImagePlug.Transform.Resolver.Geometry

  @spec lower(Operation.semantic_operation(), map()) :: [struct()]
  def lower(%PlanResize{mode: :fit} = operation, _context) do
    [%Resize{rule: tagged_dimension_rule(operation, :fit)}]
  end

  def lower(%PlanResize{mode: :cover} = operation, _context) do
    rule = tagged_dimension_rule(operation, :cover)

    cover_resize_and_crop(rule, tagged_executable_gravity(operation.guide), {0.0, 0.0})
  end

  def lower(%PlanResize{mode: :stretch} = operation, _context) do
    [%Resize{rule: tagged_dimension_rule(operation, :stretch)}]
  end

  def lower(%PlanResize{mode: :auto} = operation, context) do
    branch =
      Geometry.resize_auto_branch(
        context.current_width,
        context.current_height,
        tagged_logical_pixels(operation.width),
        tagged_logical_pixels(operation.height)
      )

    rule = tagged_dimension_rule(operation, branch)

    tagged_executable_operations(branch, rule, operation)
  end

  def lower(%ResizeFit{} = operation, _context) do
    [%Resize{rule: dimension_rule(operation, :fit)}]
  end

  def lower(%ResizeCover{} = operation, _context) do
    rule = dimension_rule(operation, :cover)

    cover_operations(rule, operation.guide, operation)
  end

  def lower(%ResizeStretch{} = operation, _context) do
    [%Resize{rule: dimension_rule(operation, :stretch)}]
  end

  def lower(%ResizeAuto{} = operation, context) do
    width = logical_pixels(operation.size.width)
    height = logical_pixels(operation.size.height)

    branch =
      Geometry.resize_auto_branch(
        context.current_width,
        context.current_height,
        width,
        height
      )

    rule = dimension_rule(operation, branch)

    executable_operations(branch, rule, operation)
  end

  def lower(%CropGuided{} = operation, _context) do
    [
      %Crop{
        width: crop_dimension(operation.size.width),
        height: crop_dimension(operation.size.height),
        crop_from: :gravity,
        gravity: executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset
      }
    ]
  end

  def lower(%CropRegion{} = operation, context) do
    [crop_region(operation.region, context)]
  end

  def lower(%Canvas{} = operation, _context) do
    width = canvas_dimension(operation.size.width)
    height = canvas_dimension(operation.size.height)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: executable_gravity(operation.placement),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        background: operation.background
      }
    ]
  end

  def lower(%AutoOrient{}, _context), do: [%ExecutableAutoOrient{}]
  def lower(%Rotate{angle: angle}, _context), do: [%ExecutableRotate{angle: angle}]
  def lower(%Flip{axis: axis}, _context), do: [%ExecutableFlip{axis: axis}]

  defp logical_pixels(%Dimension{unit: :logical_px, value: value}), do: value
  defp logical_pixels(%Dimension{}), do: :unknown

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

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

  defp dimension_rule(operation, mode) do
    %DimensionRule{
      mode: dimension_rule_mode(mode),
      width: executable_resize_dimension(operation.size.width),
      height: executable_resize_dimension(operation.size.height),
      min_width: executable_optional_resize_dimension(operation.min_width),
      min_height: executable_optional_resize_dimension(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      dpr: operation.size.dpr,
      enlarge: operation.enlargement == :allow
    }
  end

  defp dimension_rule_mode(:cover), do: :fill
  defp dimension_rule_mode(:fit), do: :fit
  defp dimension_rule_mode(:stretch), do: :force

  defp executable_resize_dimension(%Dimension{unit: :auto}), do: :auto

  defp executable_resize_dimension(%Dimension{unit: :logical_px, value: value}),
    do: {:pixels, value}

  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}

  defp tagged_executable_optional_resize_dimension(nil), do: nil

  defp tagged_executable_optional_resize_dimension(dimension),
    do: tagged_executable_resize_dimension(dimension)

  defp tagged_executable_operations(:cover, %DimensionRule{} = rule, operation),
    do: cover_resize_and_crop(rule, tagged_executable_gravity(operation.guide), {0.0, 0.0})

  defp tagged_executable_operations(:fit, %DimensionRule{} = rule, _operation),
    do: [%Resize{rule: rule}]

  defp executable_operations(:cover, %DimensionRule{} = rule, operation),
    do: cover_operations(rule, operation.guide, operation)

  defp executable_operations(:fit, %DimensionRule{} = rule, _operation),
    do: [%Resize{rule: rule}]

  defp cover_operations(%DimensionRule{} = rule, guide, operation) do
    {x_offset, y_offset} = crop_offsets(operation)

    cover_resize_and_crop(rule, executable_gravity(guide), {x_offset, y_offset})
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

  defp crop_dimension(%Dimension{unit: :full_axis}), do: :auto
  defp crop_dimension(%Dimension{unit: :logical_px, value: value}), do: {:pixels, value}

  defp crop_dimension(%Dimension{unit: :ratio, numerator: numerator, denominator: denominator}),
    do: {:scale, numerator / denominator}

  defp canvas_dimension(%Dimension{unit: :auto}), do: :auto
  defp canvas_dimension(%Dimension{unit: :logical_px, value: value}), do: {:pixels, value}

  defp canvas_dimension(%Dimension{unit: :ratio, numerator: numerator, denominator: denominator}),
    do: {:ratio, numerator / denominator}

  defp crop_region(%Region{space: :source} = region, context) do
    crop_region(region, context.source_width, context.source_height)
  end

  defp crop_region(%Region{space: :current} = region, context) do
    crop_region(region, context.current_width, context.current_height)
  end

  defp crop_region(%Region{} = region, axis_width, axis_height) do
    %Crop{
      width: {:pixels, region_dimension(region.width, axis_width)},
      height: {:pixels, region_dimension(region.height, axis_height)},
      crop_from: %{
        left: {:pixels, region_coordinate(region.x, axis_width)},
        top: {:pixels, region_coordinate(region.y, axis_height)}
      }
    }
  end

  defp region_dimension(%Dimension{unit: :logical_px, value: value}, _axis)
       when value > 0,
       do: value

  defp region_dimension(
         %Dimension{unit: :ratio, numerator: numerator, denominator: denominator},
         axis
       )
       when is_integer(axis) and axis > 0 and numerator > 0 do
    round(axis * numerator / denominator)
  end

  defp region_coordinate(%Dimension{unit: :logical_px, value: value}, _axis)
       when value >= 0,
       do: value

  defp region_coordinate(
         %Dimension{unit: :ratio, numerator: numerator, denominator: denominator},
         axis
       )
       when is_integer(axis) and axis > 0 do
    round(axis * numerator / denominator)
  end

  defp executable_gravity(%Gravity{type: :anchor, x: x, y: y, space: :current}),
    do: {:anchor, x, y}

  defp executable_gravity(%Gravity{type: :focal_point, space: :current} = gravity) do
    {:fp, ratio_to_float(gravity.x), ratio_to_float(gravity.y)}
  end

  defp tagged_executable_gravity(:center), do: {:anchor, :center, :center}
  defp tagged_executable_gravity({:anchor, x, y}), do: {:anchor, x, y}

  defp tagged_executable_gravity({:focal, x, y}),
    do: {:fp, tagged_ratio_to_float(x), tagged_ratio_to_float(y)}

  defp ratio_to_float(%Dimension{unit: :ratio, numerator: numerator, denominator: denominator}) do
    numerator / denominator
  end

  defp tagged_ratio_to_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp executable_optional_resize_dimension(nil), do: nil

  defp executable_optional_resize_dimension(%Dimension{} = dimension),
    do: executable_resize_dimension(dimension)

  defp canvas_rule({:ratio, width}, {:ratio, height}), do: {:aspect_ratio, {width, height}}
  defp canvas_rule(width, height), do: {:dimensions, width, height}

  defp crop_offsets(operation), do: {operation.x_offset, operation.y_offset}
end
