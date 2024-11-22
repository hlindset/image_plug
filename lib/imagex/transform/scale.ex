defmodule Imagex.Transform.Scale do
  @behaviour Imagex.Transform

  alias Imagex.TransformState

  #  int() <> "x" <> int() -> %{width: width, height: height}
  #    "*" <> "x" <> int() -> %{width: width, height: nil}
  #  int() <> "x" <> "*"   -> %{width: nil,   height: height}
  #  int()                 -> %{width: width, height: nil}
  defmodule ParametersParser do
    import NimbleParsec

    defcombinator(:auto_size, ignore(ascii_char([?*])))
    defcombinator(:by, ignore(ascii_char([?x])))

    defcombinator(
      :explicit,
      unwrap_and_tag(integer(min: 1), :width)
      |> parsec(:by)
      |> unwrap_and_tag(integer(min: 1), :height)
    )

    defcombinator(
      :auto_height,
      unwrap_and_tag(integer(min: 1), :width) |> parsec(:by) |> parsec(:auto_size)
    )

    defcombinator(
      :auto_width,
      parsec(:auto_size) |> parsec(:by) |> unwrap_and_tag(integer(min: 1), :height)
    )

    defcombinator(:width, unwrap_and_tag(integer(min: 1), :width))

    defparsec(
      :internal_parse,
      choice([
        parsec(:explicit),
        parsec(:auto_height),
        parsec(:auto_width),
        parsec(:width)
      ])
      |> eos()
    )

    def parse(parameters) do
      case __MODULE__.internal_parse(parameters) do
        {:ok, [width: width], _, _, _, _} ->
          {:ok, %{width: width, height: :auto}}

        {:ok, [height: height], _, _, _, _} ->
          {:ok, %{width: :auto, height: height}}

        {:ok, [width: width, height: height], _, _, _, _} ->
          {:ok, %{width: width, height: height}}

        {:error, _, _, _, _, _} ->
          {:error, :parameter_parse_error}
      end
    end
  end

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, scale_params} <- ParametersParser.parse(parameters),
         {:ok, scaled_image} <- do_scale(image, scale_params) do
      %TransformState{state | image: scaled_image}
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

  def do_scale(image, _) do
    {:ok, image}
  end
end
