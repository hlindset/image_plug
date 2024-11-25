defmodule Imagex.TransformChain do
  require Logger

  alias Imagex.TransformState

  @typedoc """
  A module implementing the `Imagex.Transform` behaviour.
  """
  @type transform_module() :: module()

  @typedoc """
  A tuple of a `transform_module()` (a module implementing `Imagex.Transform`) and the unparsed parameters for that transform.
  """
  @type chain_item() :: {transform_module(), String.t()}

  @all_transforms %{
    "crop" => Imagex.Transform.Crop,
    "scale" => Imagex.Transform.Scale,
    "focus" => Imagex.Transform.Focus
  }

  @doc """
  Parses a string into a transform chain.

  ## Examples

      iex> Imagex.TransformChain.parse("focus=20x30;scale=50p")
      {:ok, [{Imagex.Transform.Focus, "20x30"}, {Imagex.Transform.Scale, "50p"}]}
  """
  @spec parse(String.t()) :: {:ok, list(chain_item())}
  def parse(chain_str) do
    chain =
      String.split(chain_str, ";")
      |> Enum.map(fn transformation ->
        case String.split(transformation, "=") do
          [k, v] when is_map_key(@all_transforms, k) -> {Map.get(@all_transforms, k), v}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {k, _v} -> k end)
      |> Enum.reverse()

    {:ok, chain}
  end

  @doc """
  Executes a transform chain.

  ## Examples

      iex> {:ok, parsed_chain} = Imagex.TransformChain.parse("focus=20x30;crop=100x150")
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %Imagex.TransformState{image: empty_image}
      ...> {:ok, %Imagex.TransformState{}} = Imagex.TransformChain.execute(initial_state, parsed_chain)
  """
  @spec execute(TransformState.t(), list(chain_item())) ::
          {:ok, TransformState.t()} | {:error, {:transform_error, TransformState.t()}}
  def execute(%TransformState{} = state, transformation_chain) do
    transformed_state =
      for {module, parameters} <- transformation_chain, reduce: state do
        state ->
          Logger.info("executing transform: #{module} with paramters '#{parameters}'")
          module.execute(state, parameters)
      end

    case transformed_state do
      %TransformState{errors: []} = state -> {:ok, state}
      %TransformState{errors: _errors} = state -> {:error, {:transform_error, state}}
    end
  end
end
