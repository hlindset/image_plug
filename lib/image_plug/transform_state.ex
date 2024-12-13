defmodule ImagePlug.TransformState do
  @default_focus {:anchor, :center, :center}

  defstruct image: nil,
            focus: @default_focus,
            errors: [],
            output: :auto

  @type file_format() :: :avif | :webp | :jpeg | :png
  @type preview_format() :: :blurhash
  @type output_format() :: :auto | file_format() | preview_format()
  @type focus_anchor() ::
          {:anchor, :center, :center}
          | {:anchor, :center, :bottom}
          | {:anchor, :left, :bottom}
          | {:anchor, :right, :bottom}
          | {:anchor, :left, :center}
          | {:anchor, :center, :top}
          | {:anchor, :left, :top}
          | {:anchor, :right, :top}
          | {:anchor, :right, :center}

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t(),
          focus: {:coordinate, integer(), integer()} | focus_anchor(),
          errors: keyword(String.t()) | keyword(atom()),
          output: output_format()
        }

  defp default_focus, do: @default_focus

  def set_focus(%__MODULE__{} = state, focus) do
    %__MODULE__{state | focus: focus}
  end

  def reset_focus(%__MODULE__{} = state) do
    set_focus(state, default_focus())
  end

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end

  def add_error(%__MODULE__{} = state, error) do
    %__MODULE__{state | errors: [error | state.errors]}
  end
end
