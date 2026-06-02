defmodule ImagePipe.Transform.Operation.Blur do
  @moduledoc """
  Executable Gaussian blur operation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :blur

  @impl ImagePipe.Transform
  def execute(%__MODULE__{sigma: sigma}, %State{} = state) do
    case with_alpha_premultiplied(state.image, &Image.blur(&1, sigma: sigma)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp with_alpha_premultiplied(%VipsImage{} = image, callback) do
    if Image.has_alpha?(image) do
      band_format = VipsImage.format(image)

      with {:ok, premultiplied} <- Operation.premultiply(image),
           {:ok, cast} <- Operation.cast(premultiplied, band_format),
           {:ok, filtered} <- callback.(cast),
           {:ok, unpremultiplied} <- Operation.unpremultiply(filtered) do
        Operation.cast(unpremultiplied, band_format)
      end
    else
      callback.(image)
    end
  end
end
