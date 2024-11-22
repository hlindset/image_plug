defmodule Imagex.Transform.Scale do
  @behaviour Imagex.Transform

  alias Imagex.TransformState

  #
  #  int() <> "x" <> int() -> %{width: width, height: height}
  #    "" <> "x" <> int() -> %{width: width, height: nil}
  #  int() <> "x" <> "_"   -> %{width: nil,   height: height}
  #  int()                 -> %{width: width, height: nil}
  #
  #  int() <> ":" <> int() -> %{ar_x: ar_x, ar_y: ar_y}
  #  ^-- convert to given aspect ratio (whichever gives the smallest surface)
  #
  defmodule ParametersParser do
    import NimbleParsec

    defcombinator(
      :width_and_height,
      unwrap_and_tag(integer(min: 1), :width)
      |> ignore(ascii_char([?x]))
      |> unwrap_and_tag(integer(min: 1), :height)
    )

    defcombinator(
      :explicit_width,
      unwrap_and_tag(integer(min: 1), :width)
      |> ignore(ascii_char([?x]))
      |> ignore(ascii_char([?_]))
    )

    defcombinator(
      :height,
      ignore(ascii_char([?_]))
      |> ignore(ascii_char([?x]))
      |> unwrap_and_tag(integer(min: 1), :height)
    )

    defcombinator(
      :aspect_ratio,
      unwrap_and_tag(integer(min: 1), :ar_x)
      |> ignore(ascii_char([?:]))
      |> unwrap_and_tag(integer(min: 1), :ar_y)
    )

    defcombinator(
      :implicit_width,
      unwrap_and_tag(integer(min: 1), :width)
    )

    defparsec(
      :internal_parse,
      choice([
        parsec(:width_and_height),
        parsec(:explicit_width),
        parsec(:height),
        parsec(:aspect_ratio),
        parsec(:implicit_width)
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

        {:ok, [ar_x: ar_x, ar_y: ar_y], _, _, _, _} ->
          {:ok, %{ar_x: ar_x, ar_y: ar_y}}

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
