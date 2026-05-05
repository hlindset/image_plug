defmodule ImagePlug.Transform.Geometry.DimensionRule do
  @moduledoc false

  @type dimension() :: :auto | ImagePlug.imgp_pixels()
  @type mode() :: :fit | :fill | :fill_down | :force | :auto

  @type t() :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          min_width: ImagePlug.imgp_pixels() | nil,
          min_height: ImagePlug.imgp_pixels() | nil,
          zoom_x: float(),
          zoom_y: float(),
          dpr: float(),
          enlarge: boolean()
        }

  defstruct mode: :fit,
            width: :auto,
            height: :auto,
            min_width: nil,
            min_height: nil,
            zoom_x: 1.0,
            zoom_y: 1.0,
            dpr: 1.0,
            enlarge: false

  @spec validate(t(), keyword()) :: :ok | {:error, {atom(), term()}}
  def validate(rule, opts \\ [])

  def validate(%__MODULE__{} = rule, opts) when is_list(opts) do
    modes = Keyword.get(opts, :modes, [:fit, :fill, :fill_down, :force, :auto])

    with :ok <- validate_mode(rule.mode, modes),
         :ok <- validate_bound_dimension(:width, rule.width),
         :ok <- validate_bound_dimension(:height, rule.height),
         :ok <- validate_min_dimension(:min_width, rule.min_width),
         :ok <- validate_min_dimension(:min_height, rule.min_height),
         :ok <- validate_factor(:zoom_x, rule.zoom_x),
         :ok <- validate_factor(:zoom_y, rule.zoom_y),
         :ok <- validate_factor(:dpr, rule.dpr),
         :ok <- validate_enlarge(rule.enlarge) do
      :ok
    end
  end

  def validate(rule, _opts), do: {:error, {:rule, rule}}

  defp validate_mode(mode, modes) when is_list(modes) do
    if mode in modes, do: :ok, else: {:error, {:mode, mode}}
  end

  defp validate_bound_dimension(_field, nil), do: :ok
  defp validate_bound_dimension(_field, :auto), do: :ok

  defp validate_bound_dimension(_field, {:pixels, value}) when is_number(value) and value >= 0,
    do: :ok

  defp validate_bound_dimension(field, value), do: {:error, {field, value}}

  defp validate_min_dimension(_field, nil), do: :ok
  defp validate_min_dimension(_field, :auto), do: :ok

  defp validate_min_dimension(_field, {:pixels, value}) when is_number(value) and value >= 0,
    do: :ok

  defp validate_min_dimension(field, value), do: {:error, {field, value}}

  defp validate_factor(_field, nil), do: :ok
  defp validate_factor(_field, value) when is_number(value) and value > 0, do: :ok
  defp validate_factor(field, value), do: {:error, {field, value}}

  defp validate_enlarge(enlarge) when enlarge in [true, false], do: :ok
  defp validate_enlarge(enlarge), do: {:error, {:enlarge, enlarge}}
end
