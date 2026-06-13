defmodule ImagePipe.Transform.Operation.Bitonal do
  @moduledoc """
  Executable bitonal (black-and-white threshold) operation. Converts to grayscale
  (`:bw` colourspace), then applies a `>= 128` threshold so each band value becomes
  either 0 (black) or 255 (white). Per-pixel point op: sequential-safe.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation, as: VixOperation

  defstruct []

  @type t :: %__MODULE__{}

  @threshold 128

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :bitonal

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    with {:ok, gray} <- Image.to_colorspace(state.image, :bw),
         {:ok, bw} <-
           VixOperation.relational_const(
             gray,
             :VIPS_OPERATION_RELATIONAL_MOREEQ,
             [@threshold]
           ) do
      {:ok, set_image(state, bw)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
