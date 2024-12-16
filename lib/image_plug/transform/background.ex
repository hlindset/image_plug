defmodule ImagePlug.Transform.Background do
  @behaviour ImagePlug.Transform

  alias ImagePlug.TransformState

  defmodule BackgroundParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Background`.
    """
    defstruct [:backgrounds]

    @type t :: %__MODULE__{backgrounds: list(any())}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %BackgroundParams{backgrounds: backgrounds}) do
    state |> IO.inspect(label: :state)
  end
end
