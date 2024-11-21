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

  defp maybe_crop_image(image, crop) do
    with {:ok, {crop_size, coordinates}} <- split_crop_size_and_coordinates(crop),
         {:ok, {width, height}} <- split_dimensions(crop_size, "invalid crop size"),
         {:ok, {left, top}} <- split_dimensions(coordinates, "invalid coordinates"),
         {:ok, crop_values} <- {:ok, %{top: top, left: left, width: width, height: height}},
         {:ok, %{left: left, top: top, width: width, height: height}} <-
           Ecto.Changeset.apply_action(crop_changeset(crop_values), :validate) do
      Image.crop(image, left, top, width, height)
    end
  end

  @all_transforms %{"crop" => :crop}

  def parse_transformation_chain(%{"transform" => chain}) do
    chain =
      String.split(chain, "/")
      |> Enum.map(fn transformation ->
        case String.split(transformation, "=") do
          [k, v] when is_map_key(@all_transforms, k) -> {Map.get(@all_transforms, k), v}
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
  def execute_transform(image, {:crop, crop}), do: maybe_crop_image(image, crop)
  def execute_transform(image, transform), do: {:ok, image}

  def execute_transformation_chain(image, chain) do
    %{image: image, errors: errors} =
      Enum.reduce(chain, %{image: image, errors: []}, fn {transform_name, _} = transform,
                                                         %{image: image, errors: errors} = acc ->
        case execute_transform(image, transform) do
          {:ok, image} -> %{acc | image: image}
          {:error, error} -> %{acc | errors: [{transform_name, error} | errors]}
        end
      end)

    case errors do
      [] -> {:ok, image}
      _ -> {:error, {:image_transform_error, errors, image}}
    end
  end

  # todo: set correct suffix
  defp send_image(conn, image) do
    conn = send_chunked(conn, 200)
    stream = Image.stream!(image, suffix: ".jpg")

    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end

  def process(conn, %{"url" => parts} = params) do
    path = Enum.join(parts, "/")
    url = "#{@root}/#{path}"
    image_resp = Req.get!(url)

    with {:ok, image} <- Image.from_binary(image_resp.body),
         {:ok, chain} <- parse_transformation_chain(params),
         {:ok, transformed_image} <- execute_transformation_chain(image, chain) do
      send_image(conn, transformed_image)
    else
      {:error, {:image_transform_error, errors, image}} ->
        # TODO: handle transform error - make graceful partial failure optional?
        IO.inspect(errors)
        send_image(conn, image)
    end
  end
end
