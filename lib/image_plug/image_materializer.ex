defmodule ImagePlug.ImageMaterializer do
  @moduledoc false

  @spec materialize(Vix.Vips.Image.t()) :: {:ok, Vix.Vips.Image.t()} | {:error, term()}
  def materialize(%Vix.Vips.Image{} = image) do
    Vix.Vips.Image.copy_memory(image)
  end
end
