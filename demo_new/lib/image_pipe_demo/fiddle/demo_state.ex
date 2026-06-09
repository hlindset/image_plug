defmodule ImagePipeDemo.Fiddle.DemoState do
  @moduledoc "Flat demo state for spike 1 (Request + Crop). Crop px derive from the source."

  alias ImagePipeDemo.Fiddle.SampleImages

  defstruct source: "images/dog.jpg",
            crop_enabled: false,
            crop_width_unit: :px,
            crop_width: 0,
            crop_width_percent: 50,
            crop_height_unit: :px,
            crop_height: 0,
            crop_height_percent: 50,
            crop_gravity: "inherit"

  @type unit :: :px | :percent | :full
  @type t :: %__MODULE__{}

  def default, do: reset_crop_pixels_to_source(%__MODULE__{})

  defp reset_crop_pixels_to_source(%__MODULE__{source: source} = state) do
    %{state | crop_width: SampleImages.width(source), crop_height: SampleImages.height(source)}
  end

  def put_source(%__MODULE__{} = state, source) do
    if SampleImages.valid?(source) do
      reset_crop_pixels_to_source(%{state | source: source})
    else
      state
    end
  end
end
