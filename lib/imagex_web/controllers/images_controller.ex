defmodule ImagexWeb.ImagesController do
  use ImagexWeb, :controller

  alias Imagex.Images
  alias Imagex.TransformState

  require Logger

  # action_fallback ImagexWeb.FallbackController

  @root "http://localhost:4000"
  @all_transforms %{
    "crop" => Imagex.Transform.Crop,
    "scale" => Imagex.Transform.Scale,
    "focus" => Imagex.Transform.Focus
  }

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

  def parse_transformation_chain(_params), do: {:ok, []}

  defp execute_transformation_chain(state, transformation_chain) do
    transformed_state =
      for {module, parameters} <- transformation_chain, reduce: state do
        state ->
          Logger.info("executing transform: #{module} with paramters '#{parameters}'")
          module.execute(state, parameters)
      end

    case transformed_state do
      %TransformState{errors: []} = state -> {:ok, state}
      %TransformState{errors: _errors} = state -> {:error, {:transform_error, state}}
    end
  end

  defp send_image(conn, image) do
    conn = send_chunked(conn, 200)
    # todo: set correct suffix
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
         {:ok, initial_state} <- {:ok, %TransformState{image: image}},
         {:ok, chain} <- parse_transformation_chain(params),
         {:ok, %TransformState{image: image}} <-
           execute_transformation_chain(initial_state, chain) do
      send_image(conn, image)
    else
      {:error, {:transform_error, %TransformState{errors: errors, image: image}}} ->
        # TODO: handle transform error - debug mode + graceful mode switch?
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_image(conn, image)
    end
  end
end
