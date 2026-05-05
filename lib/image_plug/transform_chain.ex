defmodule ImagePlug.TransformChain do
  @moduledoc false

  require Logger

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  @typedoc """
  A struct whose module implements `ImagePlug.Transform`.
  """
  @type item() :: Transform.operation()

  @type t() :: [item()]

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   %ImagePlug.Transform.Focus{type: {:coordinate, {:pixels, 20}, {:pixels, 30}}},
      ...>   %ImagePlug.Transform.Crop{width: {:pixels, 100}, height: {:pixels, 150}, crop_from: :focus}
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePlug.TransformState{image: empty_image}
      ...> {:ok, %ImagePlug.TransformState{}} = ImagePlug.TransformChain.execute(initial_state, chain)
  """
  @spec execute(TransformState.t(), t()) ::
          {:ok, TransformState.t()} | {:error, {:transform_error, TransformState.t()}}
  def execute(%TransformState{} = state, transform_chain) do
    transform_chain
    |> Enum.reduce_while(state, fn operation, state ->
      Logger.info(fn ->
        name = Transform.transform_name(operation)
        "executing transform: #{name} with operation #{inspect(operation)}"
      end)

      next_state = Transform.execute(operation, state)

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
