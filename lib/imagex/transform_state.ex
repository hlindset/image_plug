defmodule Imagex.TransformState do
  defstruct image: nil, errors: []

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          errors: keyword(String.t()) | keyword(atom())
        }
end
