defmodule Imagex.Transform.Crop do
  @behaviour Imagex.Transformation

  alias Imagex.TransformState

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, {crop_size, coordinates}} <- split_crop_size_and_coordinates(parameters),
         {:ok, {width, height}} <- split_dimensions(crop_size, "invalid crop size"),
         {:ok, {left, top}} <- split_dimensions(coordinates, "invalid coordinates"),
         {:ok, crop_values} <- {:ok, %{top: top, left: left, width: width, height: height}},
         {:ok, %{left: left, top: top, width: width, height: height}} <-
           Ecto.Changeset.apply_action(crop_changeset(crop_values), :validate) do
      case Image.crop(image, left, top, width, height) do
        {:ok, image} -> %Imagex.TransformState{state | image: image}
        error -> %Imagex.TransformState{state | errors: [{:crop, error} | state.errors]}
      end
    end
  end

  defp crop_changeset(params) do
    {%{}, %{top: :integer, left: :integer, width: :integer, height: :integer}}
    |> Ecto.Changeset.cast(params, [:top, :left, :width, :height])
    |> Ecto.Changeset.validate_required([:top, :left, :width, :height])
  end

  defp split_crop_size_and_coordinates(crop) do
    case String.split(crop, "@") do
      [crop, coordinates] -> {:ok, {crop, coordinates}}
      _ -> {:error, "invalid crop parameter"}
    end
  end

  defp split_dimensions(dimensions, err_msg) do
    case String.split(dimensions, "x") do
      [x, y] -> {:ok, {x, y}}
      _ -> {:error, err_msg}
    end
  end
end
