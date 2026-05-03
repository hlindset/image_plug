defmodule ImagePlug.TransformChain do
  require Logger

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  @typedoc """
  A tuple of a module implementing `ImagePlug.Transform`
  and the parsed parameters for that transform.
  """
  @type item() ::
          {Transform.Crop, Transform.Crop.CropParams.t()}
          | {Transform.Focus, Transform.Focus.FocusParams.t()}
          | {Transform.Scale, Transform.Scale.ScaleParams.t()}
          | {Transform.Contain, Transform.Contain.ContainParams.t()}
          | {Transform.Cover, Transform.Cover.CoverParams.t()}
          | {Transform.Output, Transform.Output.OutputParams.t()}

  @type t() :: list(item())

  @spec append_output(t(), :avif | :webp | :jpeg | :png) :: t()
  def append_output(chain, format) do
    chain ++ [{Transform.Output, %Transform.Output.OutputParams{format: format}}]
  end

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
  @spec execute(TransformState.t(), t()) ::
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
