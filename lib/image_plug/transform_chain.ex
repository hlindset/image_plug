defmodule ImagePlug.TransformChain do
  require Logger

  alias ImagePlug.TransformState
  alias ImagePlug.ParamParser

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   {ImagePlug.Transform.Focus, %ImagePlug.Transform.Focus.FocusParams{type: {:coordinate, {:pixels, 20}, {:pixels, 30}}}},
      ...>   {ImagePlug.Transform.Crop, %ImagePlug.Transform.Crop.CropParams{width: {:pixels, 100}, height: {:pixels, 150}, crop_from: :focus}}
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePlug.TransformState{image: empty_image}
      ...> {:ok, %ImagePlug.TransformState{}} = ImagePlug.TransformChain.execute(initial_state, chain)
  """
  @spec execute(TransformState.t(), ParamParser.transform_chain()) ::
          {:ok, TransformState.t()} | {:error, {:transform_error, TransformState.t()}}
  def execute(%TransformState{} = state, transform_chain) do
    transform_chain
    |> Enum.reduce_while(state, fn {module, parameters}, state ->
      Logger.info("executing transform: #{inspect(module)} with params #{inspect(parameters)}")

      next_state = module.execute(state, parameters)

      case next_state do
        %TransformState{errors: []} -> {:cont, next_state}
        %TransformState{} -> {:halt, next_state}
      end
    end)
    |> case do
      %TransformState{errors: []} = state -> {:ok, state}
      %TransformState{} = state -> {:error, {:transform_error, state}}
    end
  end
end
