defmodule ImagexWeb.ImagesController do
  use ImagexWeb, :controller

  alias Imagex.Images

  action_fallback ImagexWeb.FallbackController

  @root "http://localhost:4000"

  defp crop_changeset(params) do
    {%{}, %{top: :integer, left: :integer, width: :integer, height: :integer}}
    |> Ecto.Changeset.cast(params, [:top, :left, :width, :height])
    |> Ecto.Changeset.validate_required([:top, :left, :width, :height])
  end

  defp crop_to_quadrilateral(%{top: top, left: left, width: width, height: height}) do
    [
      {top, left},
      {top, left + width},
      {top + height, left + width},
      {top + height, left}
    ]
  end

  defp split_crop_and_coordinates(crop) do
    case String.split(crop, "@") do
      [crop, coordinates] -> {:ok, {crop, coordinates}}
      _ -> {:error, :invalid_crop_param}
    end
  end

  defp split_dimensions(dimensions) do
    case String.split(dimensions, "x") |> IO.inspect() do
      [x, y] -> {:ok, {x, y}}
      _ -> {:error, :invalid_crop_param}
    end
  end

  defp maybe_crop_image(image, crop) do
    with {:ok, {crop_size, coordinates}} <- split_crop_and_coordinates(crop),
         {:ok, {width, height}} <- split_dimensions(crop_size),
         {:ok, {left, top}} <- split_dimensions(coordinates),
         {:ok, crop_values} <- {:ok, %{top: top, left: left, width: width, height: height}},
         {:ok, %{left: left, top: top, width: width, height: height}} <-
           Ecto.Changeset.apply_action(crop_changeset(crop_values), :validate) do
      case Image.crop(image, left, top, width, height) do
        {:ok, cropped_image} -> cropped_image
        _ -> image
      end
    end
  end

  def parse_transformation_chain(%{"transform" => chain}) do
    chain =
      String.split(chain, "/")
      |> Enum.map(fn transformation ->
        case String.split(transformation, "=") do
          [k, v] -> {k, v}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reverse()
      |> Enum.uniq_by(fn {k, _v} -> k end)
      |> Enum.reverse()

    {:ok, chain}
  end

  def execute_transform(image, transform)
  def execute_transform(image, {"crop", crop}), do: maybe_crop_image(image, crop)
  def execute_transform(image, transform), do: image

  def execute_transformation_chain(image, chain) do
    image =
      Enum.reduce(chain, image, fn transform, image ->
        execute_transform(image, transform)
      end)

    {:ok, image}
  end

  def process(conn, %{"url" => parts} = params) do
    path = Enum.join(parts, "/")
    url = "#{@root}/#{path}"
    image_resp = Req.get!(url)

    conn = send_chunked(conn, 200)

    with {:ok, image} <- Image.from_binary(image_resp.body),
         {:ok, chain} <- parse_transformation_chain(params) ,
         {:ok, transformed_image} <- execute_transformation_chain(image, chain) do
      stream = Image.stream!(transformed_image, suffix: ".jpg")

      Enum.reduce_while(stream, conn, fn data, conn ->
        case chunk(conn, data) do
          {:ok, conn} -> {:cont, conn}
          {:error, :closed} -> {:halt, conn}
        end
      end)
    end
  end
end
