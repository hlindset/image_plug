defmodule ImagePlug.Transform.Resolver do
  @moduledoc """
  Resolves semantic Plan operations to executable transform work after cache miss.
  """

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.Geometry
  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.ResolvedPlan
  alias ImagePlug.Transform.Resolver.Lowering
  alias ImagePlug.Transform.SourceMetadata

  @spec resolve(Plan.t(), SourceMetadata.t(), keyword()) ::
          {:ok, ResolvedPlan.t()} | {:error, term()}
  def resolve(%Plan{} = plan, %SourceMetadata{} = source_metadata, _opts \\ []) do
    with {:ok, pipelines} <- resolve_pipelines(plan.pipelines, source_metadata) do
      {:ok, %ResolvedPlan{pipelines: pipelines}}
    end
  end

  defp resolve_pipelines(pipelines, %SourceMetadata{} = source_metadata) do
    context = %{
      source_width: source_metadata.width,
      source_height: source_metadata.height,
      source_orientation: source_metadata.orientation,
      current_width: source_metadata.width,
      current_height: source_metadata.height,
      current_dimensions_known?: true,
      source_aligned: true
    }

    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], context}, fn {pipeline, pipeline_index},
                                                {:ok, pipelines, context} ->
      context = Map.put(context, :pipeline_index, pipeline_index)

      case resolve_pipeline(pipeline, context) do
        {:ok, operations, context} ->
          {:cont, {:ok, [operations | pipelines], context}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pipelines, _context} ->
        {:ok, Enum.reverse(pipelines)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_pipeline(%Pipeline{operations: operations}, context) do
    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], context}, fn {operation, operation_index},
                                                {:ok, resolved, context} ->
      operation_context = Map.put(context, :operation_index, operation_index)

      executable_operations = Lowering.lower(operation, lowering_context(operation_context))

      case advance_context(operation_context, executable_operations) do
        {:ok, context} ->
          {:cont, {:ok, prepend_reversed(executable_operations, resolved), context}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved, context} ->
        {:ok, Enum.reverse(resolved), context}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepend_reversed(items, acc) do
    Enum.reduce(items, acc, fn item, acc -> [item | acc] end)
  end

  defp lowering_context(%{current_dimensions_known?: false} = context) do
    %{context | current_width: :unknown, current_height: :unknown}
  end

  defp lowering_context(context), do: context

  defp advance_context(context, operations) do
    Enum.reduce_while(operations, {:ok, context}, fn operation, {:ok, context} ->
      case advance_context_for_operation(context, operation) do
        {:ok, context} -> {:cont, {:ok, context}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp advance_context_for_operation(%{current_dimensions_known?: false} = context, %Resize{}) do
    {:ok, context}
  end

  defp advance_context_for_operation(context, %Resize{rule: %DimensionRule{} = rule}) do
    with {:ok, dimensions} <- resolve_dimensions(context, rule) do
      {:ok,
       put_current_dimensions(
         context,
         dimensions.intermediate_width,
         dimensions.intermediate_height
       )}
    end
  end

  defp advance_context_for_operation(context, %Crop{target_rule: %DimensionRule{} = rule}) do
    with {:ok, dimensions} <- resolve_dimensions(context, rule) do
      {:ok,
       put_current_dimensions(
         context,
         concrete_axis(dimensions.target_width, context.current_width),
         concrete_axis(dimensions.target_height, context.current_height)
       )}
    end
  end

  defp advance_context_for_operation(context, %Crop{} = crop) do
    with {:ok, width} <- crop_axis(crop.width, context.current_width),
         {:ok, height} <- crop_axis(crop.height, context.current_height) do
      {:ok, put_current_dimensions(context, width, height)}
    end
  end

  defp advance_context_for_operation(context, %ExtendCanvas{rule: {:dimensions, width, height}}) do
    with {:ok, width} <- canvas_axis(width, context.current_width),
         {:ok, height} <- canvas_axis(height, context.current_height) do
      {:ok,
       put_current_dimensions(
         context,
         max(context.current_width, width),
         max(context.current_height, height)
       )}
    end
  end

  defp advance_context_for_operation(context, %ExtendCanvas{
         rule: {:aspect_ratio, {ratio_width, ratio_height}}
       })
       when is_number(ratio_width) and is_number(ratio_height) and ratio_width > 0 and
              ratio_height > 0 do
    target_ratio = ratio_width / ratio_height
    current_ratio = context.current_width / context.current_height

    {width, height} =
      if current_ratio > target_ratio do
        {context.current_width, round(context.current_width / target_ratio)}
      else
        {round(context.current_height * target_ratio), context.current_height}
      end

    {:ok,
     put_current_dimensions(
       context,
       max(context.current_width, width),
       max(context.current_height, height)
     )}
  end

  defp advance_context_for_operation(context, %Rotate{angle: angle}) when angle in [90, 270] do
    {:ok, put_current_dimensions(context, context.current_height, context.current_width)}
  end

  defp advance_context_for_operation(context, %Rotate{angle: 0}), do: {:ok, context}

  defp advance_context_for_operation(context, %Rotate{angle: angle}) when angle in [180] do
    {:ok, mark_source_unaligned(context)}
  end

  defp advance_context_for_operation(context, %Flip{}) do
    {:ok, mark_source_unaligned(context)}
  end

  defp advance_context_for_operation(context, %AutoOrient{}),
    do: advance_auto_orient_context(context.source_orientation, context)

  defp advance_auto_orient_context({:exif, orientation}, context) when orientation in 5..8 do
    {:ok, put_current_dimensions(context, context.current_height, context.current_width)}
  end

  defp advance_auto_orient_context(:unknown, context) do
    {:ok, mark_current_dimensions_unknown(context)}
  end

  defp advance_auto_orient_context(_orientation, context) do
    {:ok, mark_source_unaligned(context)}
  end

  defp resolve_dimensions(context, %DimensionRule{} = rule) do
    DimensionResolver.resolve(rule,
      source_width: context.current_width,
      source_height: context.current_height
    )
  end

  defp crop_axis(:auto, current_axis), do: {:ok, current_axis}

  defp crop_axis(axis, current_axis) do
    with {:ok, pixels} <- Geometry.to_pixels(current_axis, axis) do
      {:ok, max(1, min(current_axis, pixels))}
    end
  end

  defp canvas_axis(:auto, current_axis), do: {:ok, current_axis}

  defp canvas_axis(axis, current_axis) do
    with {:ok, pixels} <- Geometry.to_pixels(current_axis, axis) do
      {:ok, pixels}
    end
  end

  defp concrete_axis(:auto, current_axis), do: current_axis
  defp concrete_axis(axis, _current_axis), do: axis

  defp put_current_dimensions(context, width, height) do
    %{
      context
      | current_width: width,
        current_height: height,
        current_dimensions_known?: true,
        source_aligned: false
    }
  end

  defp mark_current_dimensions_unknown(context) do
    %{context | current_dimensions_known?: false, source_aligned: false}
  end

  defp mark_source_unaligned(context), do: %{context | source_aligned: false}
end
