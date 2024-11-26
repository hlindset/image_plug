defmodule PlugImage.Transform.Scale do
  @behaviour PlugImage.Transform

  alias PlugImage.TransformState

  defmodule ScaleParams do
    @doc """
    The parsed parameters used by `PlugImage.Transform.Scale`.
    """
    defstruct [:width, :height]

    @type int_or_pct() :: {:int, integer()} | {:pct, integer()}
    @type t ::
            %__MODULE__{width: int_or_pct() | :auto, height: int_or_pct()}
            | %__MODULE__{width: int_or_pct(), height: int_or_pct() | :auto}
  end

  @impl PlugImage.Transform
  def execute(%TransformState{} = state, %ScaleParams{} = parameters) do
    with coord_mapped_params <- map_params_to_coords(state.image, parameters),
         {:ok, scaled_image} <- do_scale(state.image, coord_mapped_params) do
      # reset focus to :center on scale
      %TransformState{state | image: scaled_image, focus: :center}
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

  def do_scale(_image, parameters) do
    {:error, {:unhandled_scale_parameters, parameters}}
  end

  def to_coord(size, {:pct, pct}), do: round(size * pct / 100)
  def to_coord(_size, {:int, int}), do: int
  def to_coord(_size, :auto), do: :auto

  def map_params_to_coords(image, %ScaleParams{width: width, height: height}) do
    %{
      width: to_coord(Image.width(image), width),
      height: to_coord(Image.height(image), height)
    }
  end
end
