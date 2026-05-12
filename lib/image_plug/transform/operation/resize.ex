defmodule ImagePlug.Transform.Operation.Resize do
  @moduledoc """
  Represents an executable resize operation whose dimension mode is known
  before execution.

  Transform Plan execution may convert semantic Plan operations to this
  executable operation after a cache miss. Parser modules should construct
  `ImagePlug.Plan.Operation.*` through Plan constructors.

  `Resize` does not perform result cropping. Transform Plan execution for
  cover-style output should include a separate crop operation after a fill-like
  resize when that matches the requested semantics.
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  @type dimension() :: :auto | ImagePlug.imgp_pixels()
  @type mode() :: :fit | :fill | :fill_down | :force

  @type t :: %__MODULE__{
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

  @type resolved_dimensions() :: %{
          requested_width: pos_integer() | :auto,
          requested_height: pos_integer() | :auto,
          target_width: pos_integer() | :auto,
          target_height: pos_integer() | :auto,
          intermediate_width: pos_integer(),
          intermediate_height: pos_integer(),
          effective_dpr: float()
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

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :resize

  @impl ImagePlug.Transform
  def validate(%__MODULE__{} = operation) do
    with :ok <- validate_mode(operation.mode),
         :ok <- validate_bound_dimension(:width, operation.width),
         :ok <- validate_bound_dimension(:height, operation.height),
         :ok <- validate_min_dimension(:min_width, operation.min_width),
         :ok <- validate_min_dimension(:min_height, operation.min_height),
         :ok <- Validation.number("resize", :zoom_x, operation.zoom_x),
         :ok <- validate_positive_factor(:zoom_x, operation.zoom_x),
         :ok <- Validation.number("resize", :zoom_y, operation.zoom_y),
         :ok <- validate_positive_factor(:zoom_y, operation.zoom_y),
         :ok <- Validation.number("resize", :dpr, operation.dpr),
         :ok <- validate_positive_factor(:dpr, operation.dpr) do
      Validation.boolean("resize", :enlarge, operation.enlarge)
    end
  end

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{
        mode: mode,
        width: width,
        height: height,
        min_width: nil,
        min_height: nil
      })
      when mode in [:fit, :force] do
    if requested_dimension?(width) or requested_dimension?(height) do
      %{access: :sequential}
    else
      %{access: :random}
    end
  end

  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = operation, %State{} = state) do
    opts = [
      source_width: image_width(state),
      source_height: image_height(state)
    ]

    with {:ok, dimensions} <- resolve_dimensions(operation, opts),
         {:ok, image} <-
           resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
      set_image(state, image)
    else
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  @doc false
  @spec resolve_dimensions(t(), keyword()) :: {:ok, resolved_dimensions()} | {:error, term()}
  def resolve_dimensions(%__MODULE__{} = operation, opts) when is_list(opts) do
    with {:ok, source} <- source_dimensions(opts),
         {:ok, operation} <- normalize(operation),
         {:ok, base} <- resolve_base_dimensions(operation, source) do
      effective_dpr = effective_dpr(operation, base, source, opts)
      requested = apply_dpr(base, effective_dpr)
      min_dimensions = resolve_min_dimensions(operation, source, effective_dpr)

      target =
        target_dimensions(operation.mode, requested, min_dimensions, source, operation.enlarge)

      intermediate =
        intermediate_dimensions(
          operation.mode,
          requested,
          min_dimensions,
          source,
          operation.enlarge
        )

      {:ok,
       %{
         requested_width: requested.width,
         requested_height: requested.height,
         target_width: target.width,
         target_height: target.height,
         intermediate_width: intermediate.width,
         intermediate_height: intermediate.height,
         effective_dpr: effective_dpr
       }}
    end
  end

  defp resize_image(%State{} = state, width, height) do
    source_width = image_width(state)
    source_height = image_height(state)

    cond do
      source_width <= 0 or source_height <= 0 ->
        {:error, {:invalid_source_dimensions, source_width, source_height}}

      width == source_width and height == source_height ->
        {:ok, state.image}

      true ->
        width_scale = width / source_width
        height_scale = height / source_height

        Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp source_dimensions(opts) do
    with {:ok, source_width} <- fetch_positive_integer(opts, :source_width),
         {:ok, source_height} <- fetch_positive_integer(opts, :source_height) do
      {:ok, %{width: source_width, height: source_height}}
    end
  end

  defp fetch_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value > 0 ->
        {:ok, positive_round(value)}

      {:ok, value} ->
        {:error, {:invalid_source_dimension, key, value}}

      :error ->
        {:error, {:missing_source_dimension, key}}
    end
  end

  defp normalize(%__MODULE__{} = operation) do
    with {:ok, mode} <- normalize_mode(operation.mode),
         {:ok, width} <- normalize_bound_dimension(:width, operation.width),
         {:ok, height} <- normalize_bound_dimension(:height, operation.height),
         {:ok, min_width} <- normalize_min_dimension(:min_width, operation.min_width),
         {:ok, min_height} <- normalize_min_dimension(:min_height, operation.min_height),
         {:ok, zoom_x} <- normalize_factor(:zoom_x, operation.zoom_x, 1.0),
         {:ok, zoom_y} <- normalize_factor(:zoom_y, operation.zoom_y, 1.0),
         {:ok, dpr} <- normalize_factor(:dpr, operation.dpr, 1.0),
         :ok <- validate_enlarge(operation.enlarge) do
      {:ok,
       %__MODULE__{
         operation
         | mode: mode,
           width: width,
           height: height,
           min_width: min_width,
           min_height: min_height,
           zoom_x: zoom_x,
           zoom_y: zoom_y,
           dpr: dpr
       }}
    end
  end

  defp validate_mode(mode) when mode in [:fit, :fill, :fill_down, :force], do: :ok
  defp validate_mode(mode), do: Validation.invalid("resize", :mode, mode)

  defp normalize_mode(mode) when mode in [:fit, :fill, :fill_down, :force], do: {:ok, mode}
  defp normalize_mode(mode), do: {:error, {:invalid_resize_mode, mode}}

  defp validate_bound_dimension(field, value) do
    case normalize_bound_dimension(field, value) do
      {:ok, _value} ->
        :ok

      {:error, {:invalid_resize_dimension, ^field, _value}} ->
        Validation.invalid("resize", field, value)
    end
  end

  defp normalize_bound_dimension(_field, nil), do: {:ok, :auto}
  defp normalize_bound_dimension(_field, :auto), do: {:ok, :auto}
  defp normalize_bound_dimension(_field, {:pixels, 0}), do: {:ok, :auto}

  defp normalize_bound_dimension(_field, {:pixels, value}) when is_number(value) and value > 0,
    do: {:ok, positive_round(value)}

  defp normalize_bound_dimension(field, value),
    do: {:error, {:invalid_resize_dimension, field, value}}

  defp validate_min_dimension(field, value) do
    case normalize_min_dimension(field, value) do
      {:ok, _value} ->
        :ok

      {:error, {:invalid_resize_dimension, ^field, _value}} ->
        Validation.invalid("resize", field, value)
    end
  end

  defp normalize_min_dimension(_field, nil), do: {:ok, nil}
  defp normalize_min_dimension(_field, :auto), do: {:ok, nil}
  defp normalize_min_dimension(_field, {:pixels, 0}), do: {:ok, nil}

  defp normalize_min_dimension(_field, {:pixels, value}) when is_number(value) and value > 0,
    do: {:ok, positive_round(value)}

  defp normalize_min_dimension(field, value),
    do: {:error, {:invalid_resize_dimension, field, value}}

  defp validate_positive_factor(_field, value) when value > 0, do: :ok
  defp validate_positive_factor(field, value), do: Validation.invalid("resize", field, value)

  defp normalize_factor(_field, nil, default), do: {:ok, default}

  defp normalize_factor(_field, value, _default) when is_number(value) and value > 0,
    do: {:ok, value * 1.0}

  defp normalize_factor(field, value, _default),
    do: {:error, {:invalid_resize_factor, field, value}}

  defp validate_enlarge(enlarge) when enlarge in [true, false], do: :ok
  defp validate_enlarge(enlarge), do: {:error, {:invalid_resize_enlarge, enlarge}}

  defp resolve_base_dimensions(%__MODULE__{width: :auto, height: :auto} = operation, source) do
    if factor_requested?(operation) do
      source
      |> apply_zoom(operation)
      |> ok()
    else
      {:ok, %{width: :auto, height: :auto}}
    end
  end

  defp resolve_base_dimensions(%__MODULE__{mode: :fit} = operation, source) do
    operation
    |> requested_box(source)
    |> fit_inside(source)
    |> apply_zoom(operation)
    |> ok()
  end

  defp resolve_base_dimensions(%__MODULE__{mode: mode} = operation, source)
       when mode in [:fill, :fill_down, :force] do
    operation
    |> requested_box(source)
    |> apply_zoom(operation)
    |> ok()
  end

  defp requested_box(%__MODULE__{mode: :force, width: :auto, height: height}, source) do
    %{width: source.width, height: height}
  end

  defp requested_box(%__MODULE__{mode: :force, width: width, height: :auto}, source) do
    %{width: width, height: source.height}
  end

  defp requested_box(%__MODULE__{width: :auto, height: height}, source) do
    %{width: positive_round(height * source.width / source.height), height: height}
  end

  defp requested_box(%__MODULE__{width: width, height: :auto}, source) do
    %{width: width, height: positive_round(width * source.height / source.width)}
  end

  defp requested_box(%__MODULE__{width: width, height: height}, _source) do
    %{width: width, height: height}
  end

  defp fit_inside(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: width, height: positive_round(width / source_ratio)}
    else
      %{width: positive_round(height * source_ratio), height: height}
    end
  end

  defp apply_zoom(%{width: width, height: height}, %__MODULE__{zoom_x: zoom_x, zoom_y: zoom_y}) do
    %{width: positive_round(width * zoom_x), height: positive_round(height * zoom_y)}
  end

  defp effective_dpr(%__MODULE__{enlarge: true, dpr: dpr}, _base, _source, _opts), do: dpr
  defp effective_dpr(%__MODULE__{dpr: 1.0}, _base, _source, _opts), do: 1.0

  defp effective_dpr(%__MODULE__{dpr: dpr}, %{width: :auto, height: :auto}, _source, _opts),
    do: dpr

  defp effective_dpr(%__MODULE__{dpr: dpr}, base, source, opts) do
    if vector_source?(opts) do
      dpr
    else
      max_dpr = min(source.width / base.width, source.height / base.height)
      min(dpr, max_dpr)
    end
  end

  defp vector_source?(opts) do
    Keyword.get(opts, :vector?, false) or Keyword.get(opts, :source_type) == :vector
  end

  defp apply_dpr(%{width: :auto, height: :auto}, _effective_dpr),
    do: %{width: :auto, height: :auto}

  defp apply_dpr(%{width: width, height: height}, effective_dpr) do
    %{
      width: positive_round(width * effective_dpr),
      height: positive_round(height * effective_dpr)
    }
  end

  defp resolve_min_dimensions(
         %__MODULE__{min_width: nil, min_height: nil},
         _source,
         _effective_dpr
       ),
       do: nil

  defp resolve_min_dimensions(%__MODULE__{} = operation, source, effective_dpr) do
    width = scaled_min(operation.min_width, effective_dpr)
    height = scaled_min(operation.min_height, effective_dpr)

    requested_box(%__MODULE__{operation | width: width || :auto, height: height || :auto}, source)
  end

  defp scaled_min(nil, _effective_dpr), do: nil
  defp scaled_min(value, effective_dpr), do: positive_round(value * effective_dpr)

  defp factor_requested?(%__MODULE__{} = operation) do
    operation.zoom_x != 1.0 or operation.zoom_y != 1.0 or operation.dpr != 1.0
  end

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, nil, _source, _enlarge),
    do: %{width: :auto, height: :auto}

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, min_dimensions, source, _enlarge) do
    target_box_dimensions(source, min_dimensions)
  end

  defp target_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp intermediate_dimensions(_mode, %{width: :auto, height: :auto}, nil, source, _enlarge),
    do: source

  defp intermediate_dimensions(
         _mode,
         %{width: :auto, height: :auto},
         min_dimensions,
         source,
         _enlarge
       ) do
    target_box_dimensions(source, min_dimensions)
  end

  defp intermediate_dimensions(:fill, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(_mode, requested, nil, source, enlarge) do
    clamp_to_source(requested, source, enlarge)
  end

  defp intermediate_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_box_dimensions(requested, nil), do: requested

  defp target_box_dimensions(requested, min_dimensions) do
    width_scale = min_dimensions.width / requested.width
    height_scale = min_dimensions.height / requested.height
    scale = max(1.0, max(width_scale, height_scale))

    scale_dimensions(requested, scale)
  end

  defp cover_resize_dimensions(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: positive_round(height * source_ratio), height: height}
    else
      %{width: width, height: positive_round(width / source_ratio)}
    end
  end

  defp scale_dimensions(%{width: width, height: height}, scale) do
    %{width: positive_round(width * scale), height: positive_round(height * scale)}
  end

  defp clamp_to_source(dimensions, _source, true), do: dimensions

  defp clamp_to_source(%{width: width, height: height} = dimensions, source, false) do
    scale = min(1.0, min(source.width / width, source.height / height))

    if scale < 1.0 do
      scale_dimensions(dimensions, scale)
    else
      dimensions
    end
  end

  defp positive_round(value) when is_number(value) do
    value
    |> round()
    |> max(1)
  end

  defp requested_dimension?(:auto), do: false
  defp requested_dimension?({:pixels, value}) when is_number(value) and value <= 0, do: false
  defp requested_dimension?(_dimension), do: true

  defp ok(value), do: {:ok, value}
end
