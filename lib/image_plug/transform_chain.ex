defmodule ImagePlug.TransformChain do
  require Logger

  alias ImagePlug.TransformState
  alias ImagePlug.ParamParser

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   {ImagePlug.Transform.Focus, %ImagePlug.Transform.Focus.FocusParams{type: {:coordinate, {:int, 20}, {:int, 30}}}},
      ...>   {ImagePlug.Transform.Crop, %ImagePlug.Transform.Crop.CropParams{width: {:int, 100}, height: {:int, 150}, crop_from: :focus}}
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePlug.TransformState{image: empty_image}
      ...> {:ok, %ImagePlug.TransformState{}} = ImagePlug.TransformChain.execute(initial_state, chain)
  """
  @spec execute(TransformState.t(), ParamParser.transform_chain()) ::
          {:ok, TransformState.t()} | {:error, {:transform_error, TransformState.t()}}
  def execute(%TransformState{} = state, transform_chain) do
    transformed_state =
      for {module, parameters} <- transform_chain, reduce: state do
        state ->
          Logger.info(
            "executing transform: #{inspect(module)} with params #{inspect(parameters)}"
          )

          module.execute(state, parameters)
      end

    case transformed_state do
      %TransformState{errors: []} = state -> {:ok, state}
      %TransformState{errors: _errors} = state -> {:error, {:transform_error, state}}
    end
  end
end
