defmodule Imagex.Transform.Crop do
  @behaviour Imagex.Transform

  alias Imagex.TransformState

  #  crop_size[@coordinates]
  #
  #  crop_size: int() <> "x" <> int()
  #  coordinates: int() <> "x" <> int()
  defmodule ParametersParser do
    import NimbleParsec

    defcombinator(
      :dimensions,
      unwrap_and_tag(integer(min: 1), :x)
      |> ignore(ascii_char([?x]))
      |> unwrap_and_tag(integer(min: 1), :y)
    )

    defparsec(
      :internal_parse,
      tag(parsec(:dimensions), :crop_size)
      |> ignore(ascii_char([?@]))
      |> tag(parsec(:dimensions), :coordinates)
      |> eos()
    )

    def parse(parameters) do
      case __MODULE__.internal_parse(parameters) do
        {:ok, [crop_size: [x: width, y: height], coordinates: [x: left, y: top]], _, _, _, _} ->
          {:ok, %{width: width, height: height, left: left, top: top}}

        {:error, _, _, _, _, _} ->
          {:error, :parameter_parse_error}
      end
    end
  end

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, %{left: left, top: top, width: width, height: height}} <-
           ParametersParser.parse(parameters) do
      case Image.crop(image, left, top, width, height) do
        {:ok, image} -> %Imagex.TransformState{state | image: image}
        error -> %Imagex.TransformState{state | errors: [{:crop, error} | state.errors]}
      end
    end
  end
end
