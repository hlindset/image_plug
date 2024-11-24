defmodule Imagex.Transform.Scale do
  @behaviour Imagex.Transform

  alias Imagex.TransformState
  alias Imagex.Transform.Scale.Parameters

  def execute(%TransformState{} = state, parameters) do
    with {:ok, parsed_params} <- Parameters.parse(parameters),
         coord_mapped_params <- map_params_to_coords(state.image, parsed_params),
         {:ok, scaled_image} <- do_scale(state.image, coord_mapped_params) do
      # reset focus to :center on scale
      %TransformState{state | image: scaled_image, focus: :center}
    end
  end

  def do_scale(image, %{width: width, height: :auto}) do
    scale = width / Image.width(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %{width: :auto, height: height}) do
    scale = height / Image.height(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)
    Image.resize(image, width_scale, vertical_scale: height_scale)
  end

  def do_scale(_image, parameters) do
    {:error, {:unhandled_scale_parameters, parameters}}
  end

  def to_coord(size, {:pct, pct}), do: round(size * pct / 100)
  def to_coord(_size, {:int, int}), do: int
  def to_coord(_size, :auto), do: :auto

  def map_params_to_coords(image, %Parameters{width: width, height: height}) do
    %{
      width: to_coord(Image.width(image), width),
      height: to_coord(Image.height(image), height)
    }
  end
end
