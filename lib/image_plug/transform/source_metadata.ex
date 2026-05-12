defmodule ImagePlug.Transform.SourceMetadata do
  @moduledoc """
  Source properties available after origin fetch/open that are not available
  from the current image.
  """

  defstruct orientation: :unknown,
            has_alpha?: false,
            format: nil,
            source_type: :raster

  @type orientation :: :normal | :unknown | {:exif, 1..8}
  @type source_type :: :raster | :animated_raster | :vector

  @type t :: %__MODULE__{
          orientation: orientation(),
          has_alpha?: boolean(),
          format: atom() | nil,
          source_type: source_type()
        }
end
