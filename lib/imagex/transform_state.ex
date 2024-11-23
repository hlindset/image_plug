defmodule Imagex.TransformState do
  defstruct image: nil, focus: :center, errors: []

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          focus: :center | {:coordinate, integer(), integer()},
          errors: keyword(String.t()) | keyword(atom())
        }
end
