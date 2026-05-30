defmodule ImagePipe.Plan.Operation.NormalizeColorProfile do
  @moduledoc """
  Semantic request to normalize the image to sRGB and drop the embedded ICC
  profile. Product-neutral; the imgproxy `strip_color_profile` (`scp`) option
  maps to this. A future target-profile field is the `cp` (#119) seam.
  """

  defstruct []

  @type t :: %__MODULE__{}
end
