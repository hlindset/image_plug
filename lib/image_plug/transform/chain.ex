defmodule ImagePlug.Transform.Chain do
  @moduledoc false

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
      ...>   %ImagePlug.Transform.Focus{type: {:coordinate, {:pixels, 20}, {:pixels, 30}}},
      ...>   %ImagePlug.Transform.Crop{width: {:pixels, 100}, height: {:pixels, 150}, crop_from: :focus}
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
      Logger.info(fn ->
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
