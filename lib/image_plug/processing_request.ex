defmodule ImagePlug.ProcessingRequest do
  @moduledoc """
  Product-neutral representation of a normalized image processing request.
  """

  @type source_kind() :: :plain
  @type resizing_type() :: :fit | :fill | :fill_down | :force | :auto
  @type output_format() :: :webp | :avif | :jpeg | :png | :best
  @type gravity_anchor() ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type gravity() :: gravity_anchor() | {:fp, float(), float()} | :sm

  @type t() :: %__MODULE__{
          signature: String.t() | nil,
          source_kind: source_kind() | nil,
          source_path: [String.t()],
          width: ImagePlug.imgp_pixels() | nil,
          height: ImagePlug.imgp_pixels() | nil,
          resizing_type: resizing_type(),
          enlarge: boolean(),
          extend: boolean(),
          extend_gravity: gravity_anchor() | nil,
          extend_x_offset: float() | nil,
          extend_y_offset: float() | nil,
          gravity: gravity(),
          gravity_x_offset: float(),
          gravity_y_offset: float(),
          format: output_format() | nil,
          output_extension_from_source: output_format() | nil
        }

  defstruct signature: nil,
            source_kind: nil,
            source_path: [],
            width: nil,
            height: nil,
            resizing_type: :fit,
            enlarge: false,
            extend: false,
            extend_gravity: nil,
            extend_x_offset: nil,
            extend_y_offset: nil,
            gravity: {:anchor, :center, :center},
            gravity_x_offset: 0.0,
            gravity_y_offset: 0.0,
            format: nil,
            output_extension_from_source: nil
end
