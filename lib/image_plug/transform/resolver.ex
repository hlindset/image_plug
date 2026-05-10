defmodule ImagePlug.Transform.Resolver do
  @moduledoc """
  Resolves semantic Plan operations to executable transform work after cache miss.
  """

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.BackendProfile
  alias ImagePlug.Transform.ResolvedPlan
  alias ImagePlug.Transform.Resolver.Lowering
  alias ImagePlug.Transform.SourceMetadata

  @spec resolve(Plan.t(), SourceMetadata.t(), keyword()) ::
          {:ok, ResolvedPlan.t()} | {:error, term()}
  def resolve(%Plan{} = plan, %SourceMetadata{} = source_metadata, _opts \\ []) do
    with :ok <- SourceMetadata.validate(source_metadata),
         {:ok, pipelines, derivations} <- resolve_pipelines(plan.pipelines, source_metadata) do
      {:ok,
       %ResolvedPlan{
         pipelines: pipelines,
         derivations: derivations,
         backend_profile_material: BackendProfile.material(BackendProfile.default())
       }}
    end
  end

  defp resolve_pipelines(pipelines, %SourceMetadata{} = source_metadata) do
    pipelines
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {pipeline, pipeline_index},
                                           {:ok, pipelines, derivations} ->
      case resolve_pipeline(pipeline, pipeline_index, source_metadata) do
        {:ok, operations, pipeline_derivations} ->
          {:cont, {:ok, [operations | pipelines], derivations ++ pipeline_derivations}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pipelines, derivations} -> {:ok, Enum.reverse(pipelines), derivations}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_pipeline(
         %Pipeline{operations: operations},
         pipeline_index,
         %SourceMetadata{} = metadata
       ) do
    context = %{
      current_width: metadata.width,
      current_height: metadata.height,
      pipeline_index: pipeline_index
    }

    operations
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {operation, operation_index},
                                           {:ok, resolved, derivations} ->
      operation_context = Map.put(context, :operation_index, operation_index)

      case Lowering.lower(operation, operation_context) do
        {:ok, executable_operations, operation_derivations} ->
          {:cont, {:ok, resolved ++ executable_operations, derivations ++ operation_derivations}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
