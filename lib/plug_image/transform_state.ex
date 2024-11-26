defmodule PlugImage.TransformState do
  defstruct image: nil,
            focus: :center,
            errors: [],
            output: :auto

  @type file_format() :: :avif | :webp | :jpeg | :png
  @type preview_format() :: :blurhash
  @type output_format() :: :auto | file_format() | preview_format()

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          focus: :center | {:coordinate, integer(), integer()},
          errors: keyword(String.t()) | keyword(atom()),
          output: output_format()
        }
end
