defmodule ImagePipe.Transform.Operation.NormalizeColorProfile do
  @moduledoc """
  Executable color-profile normalization: convert the embedded ICC profile to
  sRGB (ICC-aware, via `Image.to_colorspace/3` -> `icc_transform`).
  No-op when the image carries no profile.
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage

  @icc_field "icc-profile-data"

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :normalize_color_profile

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case normalize(state.image) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp normalize(image) do
    if profile?(image) do
      Image.to_colorspace(image, :srgb, [])
    else
      {:ok, image}
    end
  end

  defp profile?(image) do
    case VixImage.header_field_names(image) do
      {:ok, names} -> @icc_field in names
      _ -> false
    end
  end
end
