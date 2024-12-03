defmodule ImagePlug.TransformState do
  defstruct image: nil,
            focus: {:anchor, {:center, :center}},
            errors: [],
            output: :auto

  @type file_format() :: :avif | :webp | :jpeg | :png
  @type preview_format() :: :blurhash
  @type output_format() :: :auto | file_format() | preview_format()
  @type anchor_position()  ::

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          focus: {:anchor, anchor_position()} | {:coordinate, integer(), integer()},
          errors: keyword(String.t()) | keyword(atom()),
          output: output_format()
        }

  def reset_focus(%__MODULE__{} = state) do
    %__MODULE__{state | focus: {:anchor, {:center, :center}}}
  end
end
