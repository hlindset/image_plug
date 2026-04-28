defmodule ImagePlug.ProcessingRequest do
  @moduledoc """
  Product-neutral representation of a native ImagePlug processing request.
  """

  @type source_kind() :: :plain
  @type fit() :: :cover | :contain | :fill | :inside
  @type format() :: :auto | :webp | :avif | :jpeg | :png
  @type focus() ::
          ImagePlug.TransformState.focus_anchor()
          | {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}

  @type t() :: %__MODULE__{
          signature: String.t(),
          source_kind: source_kind(),
          source_path: [String.t()],
          width: ImagePlug.imgp_pixels() | nil,
          height: ImagePlug.imgp_pixels() | nil,
          fit: fit() | nil,
          focus: focus(),
          format: format()
        }

  defstruct signature: nil,
            source_kind: nil,
            source_path: [],
            width: nil,
            height: nil,
            fit: nil,
            focus: {:anchor, :center, :center},
            format: :auto
end
