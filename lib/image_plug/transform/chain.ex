defmodule ImagePlug.Transform.Chain do
  @moduledoc """
  Executes ordered transform operation chains.

  A chain is the ordered list of product-neutral operation structs already
  selected by parser or planner code. Execution proceeds left to right through
  `ImagePlug.Transform` and stops at the first operation that records an error
  in `ImagePlug.Transform.State`.
  """

  require Logger

  alias ImagePlug.Transform
  alias ImagePlug.Transform.State

  @typedoc """
  A struct whose module implements `ImagePlug.Transform`.
  """
  @type item() :: Transform.operation()

  @type t() :: [item()]

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   %ImagePlug.Transform.Operation.Focus{type: {:coordinate, {:pixels, 20}, {:pixels, 30}}},
      ...>   %ImagePlug.Transform.Operation.Crop{width: {:pixels, 100}, height: {:pixels, 150}, crop_from: :focus}
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePlug.Transform.State{image: empty_image}
      ...> {:ok, %ImagePlug.Transform.State{}} = ImagePlug.Transform.Chain.execute(initial_state, chain)
  """
  @spec execute(State.t(), t()) ::
          {:ok, State.t()} | {:error, {:transform_error, State.t()}}
  def execute(%State{} = state, transform_chain) do
    transform_chain
    |> Enum.reduce_while(state, fn operation, state ->
      Logger.debug(fn ->
        name = Transform.transform_name(operation)
        "executing transform: #{name} with operation #{inspect(operation)}"
      end)

      next_state = Transform.execute(operation, state)

      case next_state do
        %State{errors: []} -> {:cont, next_state}
        %State{} -> {:halt, next_state}
      end
    end)
    |> case do
      %State{errors: []} = state -> {:ok, state}
      %State{} = state -> {:error, {:transform_error, state}}
    end
  end
end
