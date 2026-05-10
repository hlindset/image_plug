defmodule ImagePlug.Transform.Resolver.Lowering do
  @moduledoc false

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Transform.Derivation
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Resolver.Geometry

  @default_gravity {:anchor, :center, :center}

  @spec lower(term(), map()) :: {:ok, [struct()], [Derivation.t()]} | {:error, term()}
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

  def lower(operation, _context), do: {:error, {:unsupported_semantic_operation, operation}}

  defp logical_pixels(%Dimension{unit: :logical_px, value: value}), do: {:ok, value}
  defp logical_pixels(%Dimension{}), do: {:ok, :unknown}

  defp dimension_rule(%ResizeAuto{} = operation, branch) do
    with {:ok, width} <- legacy_dimension(operation.size.width),
         {:ok, height} <- legacy_dimension(operation.size.height) do
      {:ok,
       %DimensionRule{
         mode: dimension_rule_mode(branch),
         width: width,
         height: height,
         dpr: operation.size.dpr,
         enlarge: operation.enlargement == :allow
       }}
    end
  end

  defp dimension_rule_mode(:cover), do: :fill
  defp dimension_rule_mode(:fit), do: :fit

  defp legacy_dimension(%Dimension{unit: :auto}), do: {:ok, :auto}
  defp legacy_dimension(%Dimension{unit: :logical_px, value: value}), do: {:ok, {:pixels, value}}

  defp legacy_dimension(%Dimension{} = dimension),
    do: {:error, {:unsupported_resize_auto_dimension, dimension}}

  defp executable_operations(:cover, %DimensionRule{} = rule) do
    [
      %Resize{rule: rule},
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: @default_gravity,
        target_rule: rule
      }
    ]
  end

  defp executable_operations(:fit, %DimensionRule{} = rule), do: [%Resize{rule: rule}]

  defp derivation(branch, context) do
    %Derivation{
      code: :resize_auto_branch,
      value: branch,
      pipeline_index: context.pipeline_index,
      operation_index: context.operation_index,
      material?: false
    }
  end
end
