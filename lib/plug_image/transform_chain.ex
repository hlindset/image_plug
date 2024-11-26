defmodule PlugImage.TransformChain do
  require Logger

  alias PlugImage.TransformState
  alias PlugImage.ParamParser

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   {PlugImage.Transform.Focus, %PlugImage.Transform.Focus.FocusParams{left: 20, top: 30}},
      ...>   {PlugImage.Transform.Crop, %PlugImage.Transform.Crop.CropParams{width: {:int, 100}, height: {:int, 150}, crop_from: :focus}}
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %PlugImage.TransformState{image: empty_image}
      ...> {:ok, %PlugImage.TransformState{}} = PlugImage.TransformChain.execute(initial_state, chain)
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
