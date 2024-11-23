defmodule Imagex.Transform.Focus do
  @behaviour Imagex.Transform

  alias Imagex.TransformState

  # coordinates: int() <> "x" <> int()
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
      |> eos()
    )

    def parse(parameters) do
      case __MODULE__.internal_parse(parameters) do
        {:ok, [crop_size: [x: left, y: top]], _, _, _, _} ->
          {:ok, %{left: left, top: top}}

        {:error, _, _, _, _, _} ->
          {:error, :parameter_parse_error}
      end
    end
  end

  def clamp(%TransformState{image: image}, %{top: top, left: left}) do
    clamped_left = min(Image.width(image), left)
    clamped_top = min(Image.height(image), top)
    %{left: clamped_left, top: clamped_top}
  end

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, %{left: left, top: top}} <- ParametersParser.parse(parameters),
         left_and_top <- clamp(state, %{left: left, top: top}) do
      %Imagex.TransformState{state | image: image, focus: left_and_top}
    else
      {:error, error} ->
        %Imagex.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end
end
