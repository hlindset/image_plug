defmodule PlugImage.TransformChain do
  require Logger

  alias PlugImage.TransformState

  @typedoc """
  A module implementing the `PlugImage.Transform` behaviour.
  """
  @type transform_module() :: module()

  @typedoc """
  A tuple of a `transform_module()` (a module implementing `PlugImage.Transform`) and the unparsed parameters for that transform.
  """
  @type chain_item() :: {transform_module(), String.t()}

  @all_transforms %{
    "crop" => PlugImage.Transform.Crop,
    "scale" => PlugImage.Transform.Scale,
    "focus" => PlugImage.Transform.Focus
  }

  @doc """
  Parses a string into a transform chain.

  ## Examples

      iex> PlugImage.TransformChain.parse("focus=20x30;scale=50p")
      {:ok, [{PlugImage.Transform.Focus, "20x30"}, {PlugImage.Transform.Scale, "50p"}]}
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

      iex> {:ok, parsed_chain} = PlugImage.TransformChain.parse("focus=20x30;crop=100x150")
      ...> {:ok, empty_image} = Image.new(500, 500)
      ...> initial_state = %PlugImage.TransformState{image: empty_image}
      ...> {:ok, %PlugImage.TransformState{}} = PlugImage.TransformChain.execute(initial_state, parsed_chain)
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
