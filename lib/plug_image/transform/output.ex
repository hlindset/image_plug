defmodule PlugImage.Transform.Output do
  @behaviour PlugImage.Transform

  alias PlugImage.TransformState

  defmodule OutputParams do
    @doc """
    The parsed parameters used by `PlugImage.Transform.Output`.
    """
    defstruct [:format]

    @type t :: %__MODULE__{format: TransformState.output_format()}
  end

  @impl PlugImage.Transform
  def execute(%TransformState{} = state, %OutputParams{format: format}) do
    %PlugImage.TransformState{state | output: format}
  end
end
