defmodule ImagePlug.Transform.State do
  @moduledoc """
  Execution state carried through a transform chain.

  State holds the current image, accumulated transform errors, and debug flag
  used by product-neutral operations. Operations return an updated state instead
  of mutating images in place, allowing chain execution to stop cleanly when an
  error is recorded.
  """

  defstruct image: nil,
            errors: [],
            debug: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          errors: [term()],
          debug: boolean()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end

  @spec add_error(t(), term()) :: t()
  def add_error(%__MODULE__{} = state, error) do
    %__MODULE__{state | errors: [error | state.errors]}
  end
end
