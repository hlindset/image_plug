defmodule ImagePlug.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation.AutoOrient
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Flip
  alias ImagePlug.Plan.Operation.Resize
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Plan.Operation.ResizeCover
  alias ImagePlug.Plan.Operation.ResizeFit
  alias ImagePlug.Plan.Operation.ResizeStretch
  alias ImagePlug.Plan.Operation.Rotate

  @enlargements [:allow, :deny]
  @right_angles [0, 90, 180, 270]
  @flip_axes [:horizontal, :vertical, :both]
  @prefetch_gravity_spaces [:current]
  @x_anchors [:left, :center, :right]
  @y_anchors [:top, :center, :bottom]
  @crop_anchor_guides [
    :center,
    :top_left,
    :top,
    :top_right,
    :left,
    :right,
    :bottom_left,
    :bottom,
    :bottom_right
  ]
  @resize_modes [:fit, :cover, :stretch, :auto]
  @semantic_resize_keys [:dpr, :enlargement, :guide, :min_width, :min_height, :zoom_x, :zoom_y]
  @resize_keys [:size, :enlargement, :min_width, :min_height, :zoom_x, :zoom_y]
  @resize_placement_keys [:guide, :x_offset, :y_offset]
  @crop_guided_keys [:x_offset, :y_offset]
  @canvas_keys [:size, :placement, :background, :overflow, :x_offset, :y_offset]
  @semantic_modules [
    CropGuided,
    CropRegion,
    Canvas,
    AutoOrient,
    Rotate,
    Flip,
    Resize,
    ResizeFit,
    ResizeCover,
    ResizeStretch,
    ResizeAuto
  ]

  @type resize_operation ::
          Resize.t()
          | ResizeFit.t()
          | ResizeCover.t()
          | ResizeStretch.t()
          | ResizeAuto.t()

  @type crop_operation ::
          CropGuided.t()
          | CropRegion.t()

  @type canvas_operation :: Canvas.t()

  @type orientation_operation :: AutoOrient.t() | Rotate.t() | Flip.t()

  @type semantic_operation ::
          resize_operation()
          | crop_operation()
          | canvas_operation()
          | orientation_operation()

  @type error ::
          {:invalid_operation, atom(), term()} | {:unknown_operation_options, atom(), [atom()]}
  @type validation_error :: {:invalid_pipeline_operation, term()}
  @type access_requirement :: :sequential | :random | :neutral

  @spec crop_guided(term(), term(), term(), keyword()) ::
          {:ok, CropGuided.t()} | {:error, error()}
  def crop_guided(width, height, guide, opts \\ [])

  def crop_guided(width, height, guide, opts) when is_list(opts) do
    with :ok <- validate_known_options(:crop_guided, opts, @crop_guided_keys),
         {:ok, width} <- tagged_crop_dimension(width),
         {:ok, height} <- tagged_crop_dimension(height),
         {:ok, guide} <- tagged_crop_guide(guide),
         {:ok, x_offset} <- offset(opts, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(opts, :y_offset, {:pixels, 0.0}) do
      {:ok,
       %CropGuided{
         width: width,
         height: height,
         guide: guide,
         x_offset: x_offset,
         y_offset: y_offset
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:crop_guided, [width, height, guide, opts])
    end
  end

  def crop_guided(width, height, guide, opts),
    do: invalid(:crop_guided, [width, height, guide, opts])

  def crop_guided(attrs), do: invalid(:crop_guided, attrs)

  @spec crop_region(term(), term(), term(), term()) :: {:ok, CropRegion.t()} | {:error, error()}
  def crop_region(x, y, width, height) do
    with {:ok, x} <- tagged_crop_coordinate(x),
         {:ok, y} <- tagged_crop_coordinate(y),
         {:ok, width} <- tagged_crop_region_dimension(width),
         {:ok, height} <- tagged_crop_region_dimension(height) do
      {:ok, %CropRegion{x: x, y: y, width: width, height: height}}
    else
      {:error, _reason} -> invalid(:crop_region, [x, y, width, height])
    end
  end

  def crop_region(attrs), do: invalid(:crop_region, attrs)

  @spec canvas(keyword()) :: {:ok, Canvas.t()} | {:error, error()}
  def canvas(attrs) when is_list(attrs) do
    with :ok <- validate_known_options(:canvas, attrs, @canvas_keys),
         {:ok, size} <- fetch_struct(attrs, :size, Size),
         {:ok, placement} <- fetch_struct(attrs, :placement, Gravity),
         {:ok, :white} <- fetch_exact(attrs, :background, :white),
         {:ok, :reject} <- fetch_exact(attrs, :overflow, :reject),
         {:ok, x_offset} <- signed_numeric(attrs, :x_offset, 0.0),
         {:ok, y_offset} <- signed_numeric(attrs, :y_offset, 0.0) do
      %Canvas{
        size: size,
        placement: placement,
        background: :white,
        overflow: :reject,
        x_offset: x_offset,
        y_offset: y_offset
      }
      |> validate_constructed(:canvas, attrs)
    else
      error -> constructor_error(error, :canvas, attrs)
    end
  end

  def canvas(attrs), do: invalid(:canvas, attrs)

  @spec auto_orient() :: {:ok, AutoOrient.t()}
  def auto_orient, do: {:ok, %AutoOrient{}}

  @spec rotate(term()) :: {:ok, Rotate.t()} | {:error, error()}
  def rotate(angle) when angle in @right_angles do
    {:ok, %Rotate{angle: angle}}
  end

  def rotate(angle), do: invalid(:rotate, angle)

  @spec flip(term()) :: {:ok, Flip.t()} | {:error, error()}
  def flip(axis) when axis in @flip_axes do
    {:ok, %Flip{axis: axis}}
  end

  def flip(axis), do: invalid(:flip, axis)

  @spec resize(Resize.mode(), term(), term(), keyword()) ::
          {:ok, Resize.t()} | {:error, error()}
  def resize(mode, width, height, opts \\ [])

  def resize(mode, width, height, opts) when is_list(opts) do
    with :ok <- validate_known_options(:resize, opts, @semantic_resize_keys),
         {:ok, mode} <- resize_mode(mode),
         {:ok, width} <- tagged_resize_dimension(width),
         {:ok, height} <- tagged_resize_dimension(height),
         {:ok, dpr} <- resize_dpr(Keyword.get(opts, :dpr, 1)),
         {:ok, enlargement} <-
           optional_member(opts, :enlargement, @enlargements, :deny),
         {:ok, guide} <- resize_guide(Keyword.get(opts, :guide, :center)),
         {:ok, min_width} <- optional_tagged_resize_dimension(opts, :min_width),
         {:ok, min_height} <- optional_tagged_resize_dimension(opts, :min_height),
         {:ok, zoom_x} <- numeric(opts, :zoom_x, 1.0),
         {:ok, zoom_y} <- numeric(opts, :zoom_y, 1.0) do
      {:ok,
       %Resize{
         mode: mode,
         width: width,
         height: height,
         dpr: dpr,
         enlargement: enlargement,
         guide: guide,
         min_width: min_width,
         min_height: min_height,
         zoom_x: zoom_x,
         zoom_y: zoom_y
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:resize, [mode, width, height, opts])
    end
  end

  def resize(mode, width, height, opts), do: invalid(:resize, [mode, width, height, opts])

  @spec resize_fit(keyword()) :: {:ok, ResizeFit.t()} | {:error, error()}
  def resize_fit(attrs) when is_list(attrs) do
    with :ok <- validate_known_options(:resize_fit, attrs, @resize_keys),
         {:ok, attrs} <- resize_attrs(:resize_fit, attrs) do
      ResizeFit
      |> struct!(attrs)
      |> validate_constructed(:resize_fit, attrs)
    end
  end

  def resize_fit(attrs), do: invalid(:resize_fit, attrs)

  @spec resize_cover(keyword()) :: {:ok, ResizeCover.t()} | {:error, error()}
  def resize_cover(attrs) when is_list(attrs) do
    with :ok <-
           validate_known_options(:resize_cover, attrs, @resize_keys ++ @resize_placement_keys),
         {:ok, resize_attrs} <- resize_attrs(:resize_cover, attrs),
         {:ok, guide} <- fetch_struct(attrs, :guide, Gravity),
         {:ok, x_offset} <- offset(attrs, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(attrs, :y_offset, {:pixels, 0.0}) do
      ResizeCover
      |> struct!(
        Keyword.merge(resize_attrs, guide: guide, x_offset: x_offset, y_offset: y_offset)
      )
      |> validate_constructed(:resize_cover, attrs)
    else
      error -> constructor_error(error, :resize_cover, attrs)
    end
  end

  def resize_cover(attrs), do: invalid(:resize_cover, attrs)

  @spec resize_stretch(keyword()) :: {:ok, ResizeStretch.t()} | {:error, error()}
  def resize_stretch(attrs) when is_list(attrs) do
    with :ok <- validate_known_options(:resize_stretch, attrs, @resize_keys),
         {:ok, attrs} <- resize_attrs(:resize_stretch, attrs) do
      ResizeStretch
      |> struct!(attrs)
      |> validate_constructed(:resize_stretch, attrs)
    end
  end

  def resize_stretch(attrs), do: invalid(:resize_stretch, attrs)

  @spec resize_auto(keyword()) :: {:ok, ResizeAuto.t()} | {:error, error()}
  def resize_auto(attrs) when is_list(attrs) do
    with :ok <-
           validate_known_options(:resize_auto, attrs, @resize_keys ++ @resize_placement_keys),
         {:ok, resize_attrs} <- resize_attrs(:resize_auto, attrs),
         {:ok, guide} <-
           optional_struct(attrs, :guide, Gravity, fn -> Gravity.anchor(:center, :center) end),
         {:ok, x_offset} <- offset(attrs, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(attrs, :y_offset, {:pixels, 0.0}) do
      ResizeAuto
      |> struct!(
        Keyword.merge(resize_attrs, guide: guide, x_offset: x_offset, y_offset: y_offset)
      )
      |> validate_constructed(:resize_auto, attrs)
    else
      error -> constructor_error(error, :resize_auto, attrs)
    end
  end

  def resize_auto(attrs), do: invalid(:resize_auto, attrs)

  @spec semantic?(term()) :: boolean()
  def semantic?(%module{}), do: module in @semantic_modules
  def semantic?(_operation), do: false

  @spec decode_access(semantic_operation()) :: access_requirement()
  def decode_access(operation) do
    operation
    |> access_metadata()
    |> Map.fetch!(:access)
  end

  @spec access_metadata(semantic_operation()) :: %{access: access_requirement()}
  def access_metadata(%Resize{mode: :fit} = operation), do: resize_access_metadata(operation)
  def access_metadata(%Resize{mode: :stretch} = operation), do: resize_access_metadata(operation)
  def access_metadata(%Resize{mode: mode}) when mode in [:cover, :auto], do: %{access: :random}
  def access_metadata(%ResizeFit{} = operation), do: resize_access_metadata(operation)
  def access_metadata(%ResizeStretch{} = operation), do: resize_access_metadata(operation)
  def access_metadata(%AutoOrient{}), do: %{access: :sequential}
  def access_metadata(%ResizeCover{}), do: %{access: :random}
  def access_metadata(%ResizeAuto{}), do: %{access: :random}
  def access_metadata(%CropGuided{}), do: %{access: :random}
  def access_metadata(%CropRegion{}), do: %{access: :random}
  def access_metadata(%Canvas{}), do: %{access: :random}
  def access_metadata(%Rotate{}), do: %{access: :random}
  def access_metadata(%Flip{}), do: %{access: :random}

  @spec validate_prefetch_safe(term()) :: :ok | {:error, validation_error()}
  def validate_prefetch_safe(
        %Resize{
          mode: mode,
          width: width,
          height: height,
          dpr: dpr,
          enlargement: enlargement,
          guide: guide
        } = operation
      )
      when mode in @resize_modes and enlargement in @enlargements do
    with :ok <- validate_tagged_resize_dimension(width, operation),
         :ok <- validate_tagged_resize_dimension(height, operation),
         :ok <- validate_tagged_dpr(dpr, operation),
         :ok <- validate_tagged_guide(guide, operation),
         :ok <- validate_tagged_resize_modifiers(operation) do
      validate_tagged_resize_access(mode, operation)
    end
  end

  def validate_prefetch_safe(%ResizeFit{size: size, enlargement: enlargement} = operation)
      when enlargement in @enlargements do
    with :ok <- validate_resize_size(size, operation) do
      validate_resize_modifiers(operation)
    end
  end

  def validate_prefetch_safe(
        %ResizeCover{
          size: size,
          enlargement: enlargement,
          guide: guide
        } = operation
      )
      when enlargement in @enlargements do
    with :ok <- validate_resize_size(size, operation),
         :ok <- validate_resize_modifiers(operation) do
      validate_gravity(guide, operation)
    end
  end

  def validate_prefetch_safe(%ResizeStretch{size: size, enlargement: enlargement} = operation)
      when enlargement in @enlargements do
    with :ok <- validate_resize_size(size, operation) do
      validate_resize_modifiers(operation)
    end
  end

  def validate_prefetch_safe(
        %ResizeAuto{size: size, enlargement: enlargement, guide: guide} = operation
      )
      when enlargement in @enlargements do
    with :ok <- validate_resize_size(size, operation),
         :ok <- validate_resize_modifiers(operation) do
      validate_gravity(guide, operation)
    end
  end

  def validate_prefetch_safe(%CropGuided{width: width, height: height, guide: guide} = operation) do
    with :ok <- validate_tagged_crop_dimension(width, operation),
         :ok <- validate_tagged_crop_dimension(height, operation),
         :ok <- validate_tagged_crop_guide(guide, operation),
         :ok <- validate_tagged_offset(operation.x_offset, operation) do
      validate_tagged_offset(operation.y_offset, operation)
    end
  end

  def validate_prefetch_safe(%CropRegion{x: x, y: y, width: width, height: height} = operation) do
    with :ok <- validate_tagged_crop_coordinate(x, operation),
         :ok <- validate_tagged_crop_coordinate(y, operation),
         :ok <- validate_tagged_crop_region_dimension(width, operation) do
      validate_tagged_crop_region_dimension(height, operation)
    end
  end

  def validate_prefetch_safe(
        %Canvas{
          size: size,
          placement: placement,
          background: :white,
          overflow: :reject
        } = operation
      ) do
    with :ok <- validate_canvas_size(size, operation) do
      validate_gravity(placement, operation)
    end
  end

  def validate_prefetch_safe(%AutoOrient{}), do: :ok

  def validate_prefetch_safe(%Rotate{angle: angle}) when angle in @right_angles, do: :ok

  def validate_prefetch_safe(%Flip{axis: axis}) when axis in @flip_axes, do: :ok

  def validate_prefetch_safe(operation), do: invalid_pipeline_operation(operation)

  defp invalid(operation, attrs), do: {:error, {:invalid_operation, operation, attrs}}

  defp resize_access_metadata(%Resize{
         width: width,
         height: height,
         min_width: nil,
         min_height: nil
       }) do
    case requested_tagged_resize_dimension?(width) or requested_tagged_resize_dimension?(height) do
      true -> %{access: :sequential}
      false -> %{access: :random}
    end
  end

  defp resize_access_metadata(%{size: size, min_width: nil, min_height: nil}) do
    case requested_resize_dimension?(size.width) or requested_resize_dimension?(size.height) do
      true -> %{access: :sequential}
      false -> %{access: :random}
    end
  end

  defp resize_access_metadata(_operation), do: %{access: :random}

  defp requested_tagged_resize_dimension?({:px, value}) when is_integer(value) and value > 0,
    do: true

  defp requested_tagged_resize_dimension?(_dimension), do: false

  defp requested_resize_dimension?(%Dimension{unit: :logical_px, value: value})
       when is_integer(value) and value > 0,
       do: true

  defp requested_resize_dimension?(_dimension), do: false

  defp constructor_error(
         {:error, {:unknown_operation_options, _operation, _keys} = reason},
         _op,
         _attrs
       ),
       do: {:error, reason}

  defp constructor_error({:error, _reason}, operation, attrs), do: invalid(operation, attrs)

  defp validate_constructed(operation, operation_name, attrs) do
    case validate_prefetch_safe(operation) do
      :ok -> {:ok, operation}
      {:error, _reason} -> invalid(operation_name, attrs)
    end
  end

  defp validate_known_options(operation, attrs, known_keys) do
    case Keyword.keys(attrs) -- known_keys do
      [] -> :ok
      unknown_keys -> {:error, {:unknown_operation_options, operation, Enum.uniq(unknown_keys)}}
    end
  end

  defp resize_mode(mode) when mode in @resize_modes, do: {:ok, mode}
  defp resize_mode(_mode), do: {:error, :mode}

  defp tagged_resize_dimension(:auto), do: {:ok, :auto}

  defp tagged_resize_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_resize_dimension(_dimension), do: {:error, :dimension}

  defp optional_tagged_resize_dimension(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> tagged_resize_dimension(value)
      :error -> {:ok, nil}
    end
  end

  defp resize_dpr(value) when is_integer(value) and value > 0, do: {:ok, {:ratio, value, 1}}

  defp resize_dpr(value) when is_float(value) and value > 0.0 do
    value
    |> Float.round(7)
    |> :erlang.float_to_binary(decimals: 7)
    |> decimal_string_ratio()
  end

  defp resize_dpr(value) when is_binary(value), do: decimal_string_ratio(value)
  defp resize_dpr(_value), do: {:error, :dpr}

  defp decimal_string_ratio(value) do
    value
    |> String.split(".", parts: 2)
    |> decimal_string_parts_ratio()
  end

  defp decimal_string_parts_ratio([integer]) do
    with {:ok, numerator} <- parse_non_negative_digits(integer) do
      canonical_dpr_ratio(numerator, 1)
    end
  end

  defp decimal_string_parts_ratio([integer, fraction]) when byte_size(fraction) > 0 do
    with {:ok, integer} <- parse_non_negative_digits(integer),
         {:ok, fraction_value} <- parse_non_negative_digits(fraction) do
      denominator = integer_power(10, byte_size(fraction))
      canonical_dpr_ratio(integer * denominator + fraction_value, denominator)
    end
  end

  defp decimal_string_parts_ratio(_parts), do: {:error, :dpr}

  defp parse_non_negative_digits(value) when byte_size(value) > 0 do
    if digits?(value) do
      {:ok, String.to_integer(value)}
    else
      {:error, :dpr}
    end
  end

  defp parse_non_negative_digits(_value), do: {:error, :dpr}

  defp digits?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp canonical_dpr_ratio(numerator, denominator) when numerator > 0 do
    gcd = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
  end

  defp canonical_dpr_ratio(_numerator, _denominator), do: {:error, :dpr}

  defp resize_guide(:center), do: {:ok, :center}

  defp resize_guide({:anchor, x, y} = guide) when x in @x_anchors and y in @y_anchors,
    do: {:ok, guide}

  defp resize_guide({:focal, x, y} = guide) do
    with :ok <- validate_tagged_ratio(x, guide),
         :ok <- validate_tagged_ratio(y, guide) do
      {:ok, guide}
    else
      {:error, _reason} -> {:error, :guide}
    end
  end

  defp resize_guide(_guide), do: {:error, :guide}

  defp tagged_crop_dimension(:full_axis), do: {:ok, :full_axis}

  defp tagged_crop_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_crop_dimension({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: {:ok, {:ratio, numerator, denominator}}

  defp tagged_crop_dimension(_dimension), do: {:error, :dimension}

  defp tagged_crop_coordinate({:px, value}) when is_integer(value) and value >= 0,
    do: {:ok, {:px, value}}

  defp tagged_crop_coordinate({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0,
       do: {:ok, {:ratio, numerator, denominator}}

  defp tagged_crop_coordinate(_coordinate), do: {:error, :coordinate}

  defp tagged_crop_region_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_crop_region_dimension({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: {:ok, {:ratio, numerator, denominator}}

  defp tagged_crop_region_dimension(_dimension), do: {:error, :dimension}

  defp tagged_crop_guide(guide) when guide in @crop_anchor_guides, do: {:ok, guide}

  defp tagged_crop_guide({:anchor, x, y} = guide) when x in @x_anchors and y in @y_anchors,
    do: {:ok, guide}

  defp tagged_crop_guide({:focal, x, y} = guide) do
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, guide}
    end
  end

  defp tagged_crop_guide(_guide), do: {:error, :guide}

  defp validate_tagged_resize_dimension(:auto, _operation), do: :ok

  defp validate_tagged_resize_dimension({:px, value}, _operation)
       when is_integer(value) and value > 0, do: :ok

  defp validate_tagged_resize_dimension(_dimension, operation),
    do: invalid_pipeline_operation(operation)

  defp validate_tagged_dpr({:ratio, numerator, denominator}, operation)
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0 do
    if Integer.gcd(numerator, denominator) == 1 do
      :ok
    else
      invalid_pipeline_operation(operation)
    end
  end

  defp validate_tagged_dpr(_dpr, operation), do: invalid_pipeline_operation(operation)

  defp validate_tagged_guide(:center, _operation), do: :ok

  defp validate_tagged_guide({:anchor, x, y}, _operation)
       when x in @x_anchors and y in @y_anchors,
       do: :ok

  defp validate_tagged_guide({:focal, x, y}, operation) do
    with :ok <- validate_tagged_ratio(x, operation) do
      validate_tagged_ratio(y, operation)
    end
  end

  defp validate_tagged_guide(_guide, operation), do: invalid_pipeline_operation(operation)

  defp validate_tagged_resize_modifiers(operation) do
    with :ok <- validate_optional_tagged_resize_dimension(operation.min_width, operation),
         :ok <- validate_optional_tagged_resize_dimension(operation.min_height, operation),
         :ok <- validate_factor(operation.zoom_x, operation) do
      validate_factor(operation.zoom_y, operation)
    end
  end

  defp validate_optional_tagged_resize_dimension(nil, _operation), do: :ok

  defp validate_optional_tagged_resize_dimension(dimension, operation),
    do: validate_tagged_resize_dimension(dimension, operation)

  defp validate_tagged_resize_access(mode, operation) when mode in [:fit, :stretch] do
    case resize_access_metadata(operation) do
      %{access: :sequential} -> :ok
      %{access: :random} -> :ok
    end
  end

  defp validate_tagged_resize_access(_mode, _operation), do: :ok

  defp validate_tagged_crop_dimension(:full_axis, _operation), do: :ok

  defp validate_tagged_crop_dimension({:px, value}, _operation)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_tagged_crop_dimension({:ratio, numerator, denominator}, _operation)
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: :ok

  defp validate_tagged_crop_dimension(_dimension, operation),
    do: invalid_pipeline_operation(operation)

  defp validate_tagged_crop_coordinate({:px, value}, _operation)
       when is_integer(value) and value >= 0,
       do: :ok

  defp validate_tagged_crop_coordinate({:ratio, numerator, denominator}, _operation)
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0,
       do: :ok

  defp validate_tagged_crop_coordinate(_coordinate, operation),
    do: invalid_pipeline_operation(operation)

  defp validate_tagged_crop_region_dimension({:px, value}, _operation)
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_tagged_crop_region_dimension({:ratio, numerator, denominator}, _operation)
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: :ok

  defp validate_tagged_crop_region_dimension(_dimension, operation),
    do: invalid_pipeline_operation(operation)

  defp validate_tagged_crop_guide(guide, _operation) when guide in @crop_anchor_guides, do: :ok

  defp validate_tagged_crop_guide({:anchor, x, y}, _operation)
       when x in @x_anchors and y in @y_anchors,
       do: :ok

  defp validate_tagged_crop_guide({:focal, x, y}, operation) do
    with :ok <- validate_tagged_ratio(x, operation) do
      validate_tagged_ratio(y, operation)
    end
  end

  defp validate_tagged_crop_guide(_guide, operation), do: invalid_pipeline_operation(operation)

  defp validate_tagged_offset(value, _operation) when is_number(value), do: :ok

  defp validate_tagged_offset({unit, value}, _operation)
       when unit in [:pixels, :scale] and is_number(value),
       do: :ok

  defp validate_tagged_offset(_value, operation), do: invalid_pipeline_operation(operation)

  defp validate_tagged_ratio(
         {:ratio, numerator, denominator},
         operation
       )
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0 do
    if Integer.gcd(numerator, denominator) == 1 do
      :ok
    else
      invalid_pipeline_operation(operation)
    end
  end

  defp validate_tagged_ratio(_ratio, operation), do: invalid_pipeline_operation(operation)

  defp tagged_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0,
       do: :ok

  defp tagged_ratio(_ratio), do: {:error, :ratio}

  defp validate_resize_size(%Size{} = size, operation) do
    with :ok <- validate_resize_dimension(size.width, operation),
         :ok <- validate_resize_dimension(size.height, operation) do
      validate_dpr(size.dpr, operation)
    end
  end

  defp validate_resize_size(_size, operation), do: invalid_pipeline_operation(operation)

  defp validate_resize_modifiers(operation) do
    with :ok <- validate_optional_resize_dimension(operation.min_width, operation),
         :ok <- validate_optional_resize_dimension(operation.min_height, operation),
         :ok <- validate_factor(operation.zoom_x, operation) do
      validate_factor(operation.zoom_y, operation)
    end
  end

  defp validate_canvas_size(%Size{} = size, operation) do
    with :ok <- validate_canvas_dimension(size.width, operation),
         :ok <- validate_canvas_dimension(size.height, operation) do
      validate_dpr(size.dpr, operation)
    end
  end

  defp validate_canvas_size(_size, operation), do: invalid_pipeline_operation(operation)

  defp validate_gravity(%Gravity{type: :anchor, x: x, y: y, space: space}, _operation)
       when x in @x_anchors and y in @y_anchors and space in @prefetch_gravity_spaces,
       do: :ok

  defp validate_gravity(%Gravity{type: :focal_point, x: x, y: y, space: space}, operation)
       when space in @prefetch_gravity_spaces do
    with :ok <- validate_ratio_dimension(x, operation) do
      validate_ratio_dimension(y, operation)
    end
  end

  defp validate_gravity(_gravity, operation), do: invalid_pipeline_operation(operation)

  defp validate_resize_dimension(
         %Dimension{unit: :auto, value: nil, numerator: nil, denominator: nil},
         _operation
       ),
       do: :ok

  defp validate_resize_dimension(
         %Dimension{unit: :logical_px, value: value, numerator: nil, denominator: nil},
         _operation
       )
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_resize_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_optional_resize_dimension(nil, _operation), do: :ok

  defp validate_optional_resize_dimension(%Dimension{} = dimension, operation),
    do: validate_resize_dimension(dimension, operation)

  defp validate_canvas_dimension(%Dimension{unit: :auto}, _operation), do: :ok

  defp validate_canvas_dimension(
         %Dimension{unit: :logical_px, value: value, numerator: nil, denominator: nil},
         _operation
       )
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_canvas_dimension(
         %Dimension{unit: :ratio, value: nil, numerator: numerator, denominator: denominator},
         operation
       )
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0 do
    if Integer.gcd(numerator, denominator) == 1 do
      :ok
    else
      invalid_pipeline_operation(operation)
    end
  end

  defp validate_canvas_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_ratio_dimension(
         %Dimension{unit: :ratio, value: nil, numerator: numerator, denominator: denominator},
         operation
       )
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0 do
    if Integer.gcd(numerator, denominator) == 1 do
      :ok
    else
      invalid_pipeline_operation(operation)
    end
  end

  defp validate_ratio_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_dpr(dpr, _operation) when is_number(dpr) and dpr > 0, do: :ok
  defp validate_dpr(_dpr, operation), do: invalid_pipeline_operation(operation)

  defp validate_factor(value, _operation) when is_number(value) and value > 0, do: :ok
  defp validate_factor(_value, operation), do: invalid_pipeline_operation(operation)

  defp resize_attrs(operation, attrs) do
    with {:ok, size} <- fetch_struct(attrs, :size, Size),
         {:ok, enlargement} <- fetch_member(attrs, :enlargement, @enlargements),
         {:ok, min_width} <- optional_nilable_struct(attrs, :min_width, Dimension),
         {:ok, min_height} <- optional_nilable_struct(attrs, :min_height, Dimension),
         {:ok, zoom_x} <- numeric(attrs, :zoom_x, 1.0),
         {:ok, zoom_y} <- numeric(attrs, :zoom_y, 1.0) do
      {:ok,
       [
         size: size,
         enlargement: enlargement,
         min_width: min_width,
         min_height: min_height,
         zoom_x: zoom_x,
         zoom_y: zoom_y
       ]}
    else
      {:error, _reason} -> invalid(operation, attrs)
    end
  end

  defp fetch_struct(attrs, key, module) do
    case Keyword.fetch(attrs, key) do
      {:ok, %^module{} = value} -> {:ok, value}
      {:ok, nil} -> {:error, {key, module}}
      _other -> {:error, {key, module}}
    end
  end

  defp optional_nilable_struct(attrs, key, module) do
    case Keyword.fetch(attrs, key) do
      {:ok, %^module{} = value} -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {key, module}}
      :error -> {:ok, nil}
    end
  end

  defp optional_struct(attrs, key, module, default_fun) do
    case Keyword.fetch(attrs, key) do
      {:ok, %^module{} = value} -> {:ok, value}
      {:ok, nil} -> {:error, {key, module}}
      {:ok, _value} -> {:error, {key, module}}
      :error -> default_fun.()
    end
  end

  defp fetch_exact(attrs, key, expected) do
    case Keyword.fetch(attrs, key) do
      {:ok, ^expected} -> {:ok, expected}
      _other -> {:error, {key, expected}}
    end
  end

  defp fetch_member(attrs, key, values) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, {key, values}}
      _other -> {:error, {key, values}}
    end
  end

  defp optional_member(attrs, key, values, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, {key, values}}
      :error -> {:ok, default}
    end
  end

  defp numeric(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, key}
      :error -> {:ok, default}
    end
  end

  defp signed_numeric(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, key}
      :error -> {:ok, default}
    end
  end

  defp offset(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) ->
        {:ok, value}

      {:ok, {unit, value}} when unit in [:pixels, :scale] and is_number(value) ->
        {:ok, {unit, value}}

      {:ok, _value} ->
        {:error, key}

      :error ->
        {:ok, default}
    end
  end

  defp integer_power(base, exponent) do
    Enum.reduce(1..exponent//1, 1, fn _step, product -> product * base end)
  end

  defp invalid_pipeline_operation(operation),
    do: {:error, {:invalid_pipeline_operation, operation}}
end
