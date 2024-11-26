defmodule ImagePlug.Transform.Output do
  @behaviour ImagePlug.Transform

  alias ImagePlug.TransformState

  defmodule OutputParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Output`.
    """
    defstruct [:format]

    @type t :: %__MODULE__{format: TransformState.output_format()}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %OutputParams{format: format}) do
    %ImagePlug.TransformState{state | output: format}
  end
end
