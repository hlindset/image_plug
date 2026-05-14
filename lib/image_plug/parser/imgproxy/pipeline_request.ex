defmodule ImagePlug.Parser.Imgproxy.PipelineRequest do
  @moduledoc false

  alias ImagePlug.Parser.Imgproxy.CropRequest
  alias ImagePlug.Plan.Color
  alias ImagePlug.Plan.Orientation

  @type resizing_type() :: :fit | :fill | :fill_down | :force | :auto
  @type gravity_anchor() :: {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type gravity() :: gravity_anchor() | {:fp, float(), float()} | :sm
  @type gravity_offset() :: {:pixels, float()} | {:scale, float()}

  @type t() :: %__MODULE__{
          width: ImagePlug.imgp_pixels() | nil,
          height: ImagePlug.imgp_pixels() | nil,
          min_width: ImagePlug.imgp_pixels() | nil,
          min_height: ImagePlug.imgp_pixels() | nil,
          resizing_type: resizing_type(),
          zoom_x: float() | nil,
          zoom_y: float() | nil,
          dpr: float() | nil,
          enlarge: boolean(),
          extend: boolean(),
          extend_requested: boolean(),
          extend_gravity: gravity_anchor() | nil,
          extend_x_offset: float() | nil,
          extend_y_offset: float() | nil,
          extend_aspect_ratio: ImagePlug.imgp_ratio() | nil,
          padding_top: non_neg_integer() | nil,
          padding_right: non_neg_integer() | nil,
          padding_bottom: non_neg_integer() | nil,
          padding_left: non_neg_integer() | nil,
          background_color: Color.t() | nil,
          background_alpha: Color.alpha() | nil,
          gravity: gravity(),
          gravity_x_offset: gravity_offset(),
          gravity_y_offset: gravity_offset(),
          crop: CropRequest.t() | nil,
          orientation_requested: boolean(),
          orientation: Orientation.t()
        }

  defstruct width: nil,
            height: nil,
            min_width: nil,
            min_height: nil,
            resizing_type: :fit,
            zoom_x: nil,
            zoom_y: nil,
            dpr: nil,
            enlarge: false,
            extend: false,
            extend_requested: false,
            extend_gravity: nil,
            extend_x_offset: nil,
            extend_y_offset: nil,
            extend_aspect_ratio: nil,
            padding_top: nil,
            padding_right: nil,
            padding_bottom: nil,
            padding_left: nil,
            background_color: nil,
            background_alpha: nil,
            gravity: {:anchor, :center, :center},
            gravity_x_offset: {:pixels, 0.0},
            gravity_y_offset: {:pixels, 0.0},
            crop: nil,
            orientation_requested: false,
            orientation: %Orientation{}
end
