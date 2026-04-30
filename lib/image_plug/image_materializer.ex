defmodule ImagePlug.ImageMaterializer do
  @moduledoc """
  Internal boundary for forcing lazy image graphs into memory.

  Sequential input decode can defer origin reads until transform execution. ImagePlug
  uses this module before cache writes or response headers so request handling can
  materialize pixels, then check whether the origin stream finished or failed.
  """

  @spec materialize(Vix.Vips.Image.t()) :: {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def materialize(%Vix.Vips.Image{} = image) do
    Vix.Vips.Image.copy_memory(image)
  end
end
