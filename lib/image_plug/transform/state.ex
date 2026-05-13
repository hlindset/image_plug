defmodule ImagePlug.Transform.State do
  @moduledoc """
  Execution state carried through a transform chain.

  State holds the current image and debug flag used by product-neutral
  operations. Operations return an updated state instead of mutating images in
  place.
  """

  defstruct image: nil,
            debug: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end
end
