defmodule ImagePlug.Transform.Resolver.Lowering do
  @moduledoc false

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation.AutoOrient, as: SemanticAutoOrient
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Flip, as: SemanticFlip
  alias ImagePlug.Plan.Operation.ResizeCover
  alias ImagePlug.Plan.Operation.ResizeFit
  alias ImagePlug.Plan.Operation.ResizeStretch
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Plan.Operation.Rotate, as: SemanticRotate
  alias ImagePlug.Transform.Derivation
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.Resolver.Geometry

  @default_gravity {:anchor, :center, :center}

  @spec lower(term(), map()) :: {:ok, [struct()], [Derivation.t()]} | {:error, term()}
  def lower(%ResizeFit{} = operation, _context) do
    with {:ok, rule} <- dimension_rule(operation, :fit) do
      {:ok, [%Resize{rule: rule}], []}
    end
  end

  def lower(%ResizeCover{} = operation, _context) do
    with {:ok, rule} <- dimension_rule(operation, :cover) do
      {:ok, cover_operations(rule, operation.guide), []}
    end
  end

  def lower(%ResizeStretch{} = operation, _context) do
    with {:ok, rule} <- dimension_rule(operation, :stretch) do
      {:ok, [%Resize{rule: rule}], []}
    end
  end

  def lower(%ResizeAuto{} = operation, context) do
    with {:ok, width} <- logical_pixels(operation.size.width),
         {:ok, height} <- logical_pixels(operation.size.height),
         branch =
           Geometry.resize_auto_branch(
             context.current_width,
             context.current_height,
             width,
             height
           ),
         {:ok, rule} <- dimension_rule(operation, branch) do
      derivation = derivation(branch, context)

      {:ok, executable_operations(branch, rule), [derivation]}
    end
  end

  def lower(%CropGuided{} = operation, _context) do
    with {:ok, width} <- crop_dimension(operation.size.width),
         {:ok, height} <- crop_dimension(operation.size.height),
         {:ok, gravity} <- legacy_gravity(operation.guide) do
      {:ok, [%Crop{width: width, height: height, crop_from: :gravity, gravity: gravity}], []}
    end
  end

  def lower(%CropRegion{} = operation, context) do
    with {:ok, crop} <- crop_region(operation.region, context) do
      derivation = %Derivation{
        code: :crop_region_resolved,
        value: %{
          left: crop.crop_from.left,
          top: crop.crop_from.top,
          width: crop.width,
          height: crop.height
        },
        pipeline_index: context.pipeline_index,
        operation_index: context.operation_index,
        material?: false
      }

      {:ok, [crop], [derivation]}
    end
  end

  def lower(%Canvas{} = operation, _context) do
    with {:ok, width} <- canvas_dimension(operation.size.width),
         {:ok, height} <- canvas_dimension(operation.size.height),
         {:ok, gravity} <- legacy_gravity(operation.placement) do
      {:ok,
       [
         %ExtendCanvas{
           rule: {:dimensions, width, height},
           gravity: gravity,
           background: operation.background
         }
       ], []}
    end
  end

  def lower(%SemanticAutoOrient{}, _context), do: {:ok, [%AutoOrient{}], []}
  def lower(%SemanticRotate{angle: angle}, _context), do: {:ok, [%Rotate{angle: angle}], []}
  def lower(%SemanticFlip{axis: axis}, _context), do: {:ok, [%Flip{axis: axis}], []}

  def lower(operation, _context), do: {:error, {:unsupported_semantic_operation, operation}}

  defp logical_pixels(%Dimension{unit: :logical_px, value: value}), do: {:ok, value}
  defp logical_pixels(%Dimension{}), do: {:ok, :unknown}

  defp dimension_rule(operation, mode) do
    with {:ok, width} <- legacy_dimension(operation.size.width),
         {:ok, height} <- legacy_dimension(operation.size.height) do
      {:ok,
       %DimensionRule{
         mode: dimension_rule_mode(mode),
         width: width,
         height: height,
         dpr: operation.size.dpr,
         enlarge: operation.enlargement == :allow
       }}
    end
  end

  defp dimension_rule_mode(:cover), do: :fill
  defp dimension_rule_mode(:fit), do: :fit
  defp dimension_rule_mode(:stretch), do: :force

  defp legacy_dimension(%Dimension{unit: :auto}), do: {:ok, :auto}
  defp legacy_dimension(%Dimension{unit: :logical_px, value: value}), do: {:ok, {:pixels, value}}

  defp legacy_dimension(%Dimension{} = dimension),
    do: {:error, {:unsupported_resize_auto_dimension, dimension}}

  defp executable_operations(:cover, %DimensionRule{} = rule), do: cover_operations(rule, nil)
  defp executable_operations(:fit, %DimensionRule{} = rule), do: [%Resize{rule: rule}]

  defp cover_operations(%DimensionRule{} = rule, guide) do
    gravity =
      case legacy_gravity(guide) do
        {:ok, gravity} -> gravity
        {:error, _reason} -> @default_gravity
      end

    [
      %Resize{rule: rule},
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: gravity,
        target_rule: rule
      }
    ]
  end

  defp derivation(branch, context) do
    %Derivation{
      code: :resize_auto_branch,
      value: branch,
      pipeline_index: context.pipeline_index,
      operation_index: context.operation_index,
      material?: false
    }
  end

  defp crop_dimension(%Dimension{unit: :full_axis}), do: {:ok, :auto}
  defp crop_dimension(%Dimension{unit: :logical_px, value: value}), do: {:ok, {:pixels, value}}

  defp crop_dimension(%Dimension{} = dimension),
    do: {:error, {:unsupported_crop_dimension, dimension}}

  defp canvas_dimension(%Dimension{unit: :auto}), do: {:ok, :auto}
  defp canvas_dimension(%Dimension{unit: :logical_px, value: value}), do: {:ok, {:pixels, value}}

  defp canvas_dimension(%Dimension{} = dimension),
    do: {:error, {:unsupported_canvas_dimension, dimension}}

  defp crop_region(%Region{space: space} = region, context) when space in [:source, :current] do
    with {:ok, left} <- region_dimension(region.x, context.current_width),
         {:ok, top} <- region_dimension(region.y, context.current_height),
         {:ok, width} <- region_dimension(region.width, context.current_width),
         {:ok, height} <- region_dimension(region.height, context.current_height) do
      {:ok,
       %Crop{
         width: {:pixels, width},
         height: {:pixels, height},
         crop_from: %{left: {:pixels, left}, top: {:pixels, top}}
       }}
    end
  end

  defp crop_region(%Region{} = region, _context),
    do: {:error, {:unsupported_crop_region_space, region.space}}

  defp region_dimension(%Dimension{unit: :logical_px, value: value}, _axis), do: {:ok, value}

  defp region_dimension(
         %Dimension{unit: :ratio, numerator: numerator, denominator: denominator},
         axis
       )
       when is_integer(axis) and axis > 0 do
    {:ok, round(axis * numerator / denominator)}
  end

  defp region_dimension(%Dimension{} = dimension, _axis),
    do: {:error, {:unsupported_crop_region_dimension, dimension}}

  defp legacy_gravity(nil), do: {:ok, @default_gravity}
  defp legacy_gravity(%Gravity{type: :anchor, x: x, y: y}), do: {:ok, {:anchor, x, y}}

  defp legacy_gravity(%Gravity{type: :focal_point} = gravity) do
    with {:ok, x} <- ratio_to_float(gravity.x),
         {:ok, y} <- ratio_to_float(gravity.y) do
      {:ok, {:fp, x, y}}
    end
  end

  defp ratio_to_float(%Dimension{unit: :ratio, numerator: numerator, denominator: denominator}) do
    {:ok, numerator / denominator}
  end

  defp ratio_to_float(%Dimension{} = dimension),
    do: {:error, {:unsupported_focal_point_dimension, dimension}}
end
