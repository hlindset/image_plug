defmodule ImagePipe.Transform.Chain do
  @moduledoc """
  Executes ordered transform operation chains.

  A chain is the ordered list of product-neutral operation structs already
  selected by parser or planner code. Execution proceeds left to right through
  `ImagePipe.Transform` and stops at the first operation error.
  """

  require Logger

  alias ImagePipe.Transform
  alias ImagePipe.Transform.State

  @typedoc """
  A struct whose module implements `ImagePipe.Transform`.
  """
  @type item() :: Transform.operation()

  @type t() :: [item()]

  @doc """
  Executes a transform chain.

  ## Examples

      iex> chain = [
      ...>   %ImagePipe.Transform.Operation.Resize{
      ...>     mode: :fit,
      ...>     width: {:pixels, 100},
      ...>     height: :auto
      ...>   }
      ...> ]
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %ImagePipe.Transform.State{image: empty_image}
      ...> {:ok, %ImagePipe.Transform.State{}} = ImagePipe.Transform.Chain.execute(initial_state, chain)
  """
  @spec execute(State.t(), t()) ::
          {:ok, State.t()} | {:error, {:transform_error, term()}}
  def execute(%State{} = state, transform_chain) do
    Enum.reduce_while(transform_chain, {:ok, state}, fn operation, {:ok, state} ->
      Logger.debug(fn ->
        name = Transform.transform_name(operation)
        "executing transform: #{name} with operation #{inspect(operation)}"
      end)

      case Transform.execute(operation, state) do
        {:ok, %State{} = next_state} -> {:cont, {:ok, next_state}}
        {:error, reason} -> {:halt, {:error, {:transform_error, reason}}}
      end
    end)
  end
end
