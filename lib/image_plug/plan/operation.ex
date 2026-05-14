defmodule ImagePlug.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.FlattenBackground
  alias ImagePlug.Plan.Operation.Padding
  alias ImagePlug.Plan.Operation.Resize
  alias ImagePlug.Plan.Color

  @enlargements [:allow, :deny]
  @right_angles [0, 90, 180, 270]
  @flip_axes [:horizontal, :vertical, :both]
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
  @semantic_resize_keys [
    :dpr,
    :enlargement,
    :guide,
    :x_offset,
    :y_offset,
    :min_width,
    :min_height,
    :zoom_x,
    :zoom_y
  ]
  @crop_guided_keys [:x_offset, :y_offset]
  @canvas_keys [:fill, :overflow, :x_offset, :y_offset]
  @padding_keys [:pixel_ratio, :fill]
  @effective_padding_modes [:resize, :canvas_preserving]
  # Keep the orientation primitive allowlist centralized without importing
  # executable operation modules into the Plan operation facade.
  @auto_orient_module :"Elixir.ImagePlug.Transform.Operation.AutoOrient"
  @rotate_module :"Elixir.ImagePlug.Transform.Operation.Rotate"
  @flip_module :"Elixir.ImagePlug.Transform.Operation.Flip"

  @type resize_operation :: Resize.t()

  @type crop_operation ::
          CropGuided.t()
          | CropRegion.t()

  @type canvas_operation :: Canvas.t()

  @type padding_operation :: Padding.t()

  @type flatten_background_operation :: FlattenBackground.t()

  @type orientation_operation ::
          ImagePlug.Transform.Operation.AutoOrient.t()
          | ImagePlug.Transform.Operation.Rotate.t()
          | ImagePlug.Transform.Operation.Flip.t()

  @type semantic_operation ::
          resize_operation()
          | crop_operation()
          | canvas_operation()
          | padding_operation()
          | flatten_background_operation()
          | orientation_operation()

  @type error ::
          {:invalid_operation, atom(), term()} | {:unknown_operation_options, atom(), [atom()]}

  @spec color(term(), term(), term()) :: {:ok, Color.t()} | {:error, term()}
  def color(red, green, blue), do: Color.rgb(red, green, blue)

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

  @spec canvas(term(), term(), term(), keyword()) :: {:ok, Canvas.t()} | {:error, error()}
  def canvas(width, height, placement, opts \\ [])

  def canvas(width, height, placement, opts) when is_list(opts) do
    with :ok <- validate_known_options(:canvas, opts, @canvas_keys),
         {:ok, width} <- tagged_canvas_dimension(width),
         {:ok, height} <- tagged_canvas_dimension(height),
         {:ok, placement} <- tagged_canvas_placement(placement),
         :ok <- validate_canvas_dimension_pair(width, height, :canvas),
         {:ok, fill} <- optional_fill(opts, :fill, :transparent),
         {:ok, :reject} <- optional_exact(opts, :overflow, :reject),
         {:ok, x_offset} <- signed_numeric(opts, :x_offset, 0.0),
         {:ok, y_offset} <- signed_numeric(opts, :y_offset, 0.0) do
      {:ok,
       %Canvas{
         width: width,
         height: height,
         placement: placement,
         fill: fill,
         overflow: :reject,
         x_offset: x_offset,
         y_offset: y_offset
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:canvas, [width, height, placement, opts])
    end
  end

  @spec padding(term(), term(), term(), term(), keyword()) ::
          {:ok, Padding.t()} | {:error, error()}
  def padding(top, right, bottom, left, opts \\ [])

  def padding(top, right, bottom, left, opts) when is_list(opts) do
    with :ok <- validate_known_options(:padding, opts, @padding_keys),
         {:ok, top} <- tagged_padding_side(top),
         {:ok, right} <- tagged_padding_side(right),
         {:ok, bottom} <- tagged_padding_side(bottom),
         {:ok, left} <- tagged_padding_side(left),
         :ok <- validate_positive_padding([top, right, bottom, left]),
         {:ok, pixel_ratio} <-
           opts
           |> Keyword.get(:pixel_ratio, {:ratio, 1, 1})
           |> tagged_padding_pixel_ratio(),
         {:ok, fill} <- optional_fill(opts, :fill, :transparent) do
      {:ok,
       %Padding{
         top: top,
         right: right,
         bottom: bottom,
         left: left,
         pixel_ratio: pixel_ratio,
         fill: fill
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:padding, [top, right, bottom, left, opts])
    end
  end

  @spec flatten_background(term()) :: {:ok, FlattenBackground.t()} | {:error, error()}
  def flatten_background(%Color{} = color) do
    case Color.valid?(color) do
      true -> {:ok, %FlattenBackground{color: color}}
      false -> invalid(:flatten_background, [color])
    end
  end

  def flatten_background(color), do: invalid(:flatten_background, [color])

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
         {:ok, x_offset} <- offset(opts, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(opts, :y_offset, {:pixels, 0.0}),
         {:ok, {x_offset, y_offset}} <- resize_offsets(mode, x_offset, y_offset),
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
         x_offset: x_offset,
         y_offset: y_offset,
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

  @spec semantic?(term()) :: boolean()
  def semantic?(%Resize{} = operation), do: valid_resize?(operation)
  def semantic?(%CropGuided{} = operation), do: valid_crop_guided?(operation)
  def semantic?(%CropRegion{} = operation), do: valid_crop_region?(operation)
  def semantic?(%Canvas{} = operation), do: valid_canvas?(operation)
  def semantic?(%Padding{} = operation), do: valid_padding?(operation)
  def semantic?(%FlattenBackground{} = operation), do: valid_flatten_background?(operation)
  def semantic?(%{__struct__: @auto_orient_module}), do: true
  def semantic?(%{__struct__: @rotate_module, angle: angle}) when angle in @right_angles, do: true
  def semantic?(%{__struct__: @flip_module, axis: axis}) when axis in @flip_axes, do: true
  def semantic?(_operation), do: false

  defp invalid(operation, attrs), do: {:error, {:invalid_operation, operation, attrs}}

  defp valid_resize?(%Resize{} = operation) do
    with {:ok, mode} <- resize_mode(operation.mode),
         {:ok, _width} <- tagged_resize_dimension(operation.width),
         {:ok, _height} <- tagged_resize_dimension(operation.height),
         :ok <- tagged_dpr_ratio(operation.dpr),
         {:ok, _enlargement} <-
           member(operation.enlargement, @enlargements),
         {:ok, _guide} <- resize_guide(operation.guide),
         :ok <- tagged_offset(operation.x_offset),
         :ok <- tagged_offset(operation.y_offset),
         {:ok, _offsets} <- resize_offsets(mode, operation.x_offset, operation.y_offset),
         :ok <- optional_resize_dimension(operation.min_width),
         :ok <- optional_resize_dimension(operation.min_height),
         :ok <- positive_number(operation.zoom_x),
         :ok <- positive_number(operation.zoom_y) do
      true
    else
      _error -> false
    end
  end

  defp valid_crop_guided?(%CropGuided{} = operation) do
    with {:ok, _width} <- tagged_crop_dimension(operation.width),
         {:ok, _height} <- tagged_crop_dimension(operation.height),
         {:ok, _guide} <- tagged_crop_guide(operation.guide),
         :ok <- tagged_offset(operation.x_offset),
         :ok <- tagged_offset(operation.y_offset) do
      true
    else
      _error -> false
    end
  end

  defp valid_crop_region?(%CropRegion{} = operation) do
    with {:ok, _x} <- tagged_crop_coordinate(operation.x),
         {:ok, _y} <- tagged_crop_coordinate(operation.y),
         {:ok, _width} <- tagged_crop_region_dimension(operation.width),
         {:ok, _height} <- tagged_crop_region_dimension(operation.height) do
      true
    else
      _error -> false
    end
  end

  defp valid_canvas?(%Canvas{} = operation) do
    with {:ok, width} <- tagged_canvas_dimension(operation.width),
         {:ok, height} <- tagged_canvas_dimension(operation.height),
         {:ok, _placement} <- tagged_canvas_placement(operation.placement),
         :ok <- validate_canvas_dimension_pair(width, height, :canvas),
         {:ok, _fill} <- tagged_fill(operation.fill),
         {:ok, _overflow} <- member(operation.overflow, [:reject]),
         :ok <- number(operation.x_offset),
         :ok <- number(operation.y_offset) do
      true
    else
      _error -> false
    end
  end

  defp valid_padding?(%Padding{} = operation) do
    with {:ok, top} <- tagged_padding_side(operation.top),
         {:ok, right} <- tagged_padding_side(operation.right),
         {:ok, bottom} <- tagged_padding_side(operation.bottom),
         {:ok, left} <- tagged_padding_side(operation.left),
         :ok <- validate_positive_padding([top, right, bottom, left]),
         {:ok, _pixel_ratio} <- tagged_padding_pixel_ratio(operation.pixel_ratio),
         {:ok, _fill} <- tagged_fill(operation.fill) do
      true
    else
      _error -> false
    end
  end

  defp valid_flatten_background?(%FlattenBackground{color: color}), do: Color.valid?(color)

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

  defp tagged_dpr_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: :ok

  defp tagged_dpr_ratio(_dpr), do: {:error, :dpr}

  defp tagged_padding_pixel_ratio({:ratio, _numerator, _denominator} = ratio) do
    case tagged_dpr_ratio(ratio) do
      :ok -> {:ok, ratio}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tagged_padding_pixel_ratio({:effective, fallback, mode})
       when mode in @effective_padding_modes do
    case tagged_dpr_ratio(fallback) do
      :ok -> {:ok, {:effective, fallback, mode}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tagged_padding_pixel_ratio(_pixel_ratio), do: {:error, :pixel_ratio}

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
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, guide}
    else
      {:error, _reason} -> {:error, :guide}
    end
  end

  defp resize_guide(_guide), do: {:error, :guide}

  defp resize_offsets(mode, x_offset, y_offset) when mode in [:cover, :auto],
    do: {:ok, {x_offset, y_offset}}

  defp resize_offsets(_mode, x_offset, y_offset) do
    if zero_offset?(x_offset) and zero_offset?(y_offset) do
      {:ok, {{:pixels, 0.0}, {:pixels, 0.0}}}
    else
      {:error, :offset}
    end
  end

  defp zero_offset?(value) when is_number(value), do: value == 0

  defp zero_offset?({unit, value}) when unit in [:pixels, :scale] and is_number(value),
    do: value == 0

  defp optional_resize_dimension(nil), do: :ok

  defp optional_resize_dimension(dimension) do
    case tagged_resize_dimension(dimension) do
      {:ok, _dimension} -> :ok
      {:error, _reason} = error -> error
    end
  end

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

  defp tagged_canvas_dimension(:auto), do: {:ok, :auto}

  defp tagged_canvas_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_canvas_dimension({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: canonical_ratio(numerator, denominator)

  defp tagged_canvas_dimension(_dimension), do: {:error, :dimension}

  defp tagged_padding_side({:px, value}) when is_integer(value) and value >= 0,
    do: {:ok, {:px, value}}

  defp tagged_padding_side(_side), do: {:error, :padding}

  defp validate_positive_padding(sides) do
    case Enum.any?(sides, fn {:px, value} -> value > 0 end) do
      true -> :ok
      false -> {:error, :padding}
    end
  end

  defp optional_fill(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> tagged_fill(value)
      :error -> {:ok, default}
    end
  end

  defp tagged_fill(:transparent), do: {:ok, :transparent}

  defp tagged_fill({:solid, %Color{} = color}) do
    case Color.valid?(color) do
      true -> {:ok, {:solid, color}}
      false -> {:error, :fill}
    end
  end

  defp tagged_fill(_fill), do: {:error, :fill}

  defp tagged_canvas_placement(placement) when placement in @crop_anchor_guides,
    do: {:ok, placement}

  defp tagged_canvas_placement({:focal, x, y}) do
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, {:focal, normalize_ratio(x), normalize_ratio(y)}}
    end
  end

  defp tagged_canvas_placement(_placement), do: {:error, :placement}

  defp validate_canvas_dimension_pair(
         {:ratio, _width_numerator, _width_denominator},
         {:ratio, _height_numerator, _height_denominator},
         _context
       ),
       do: :ok

  defp validate_canvas_dimension_pair(
         {:ratio, _width_numerator, _width_denominator},
         _height,
         _context
       ),
       do: {:error, :mixed_canvas_units}

  defp validate_canvas_dimension_pair(
         _width,
         {:ratio, _height_numerator, _height_denominator},
         _context
       ),
       do: {:error, :mixed_canvas_units}

  defp validate_canvas_dimension_pair(_width, _height, _context), do: :ok

  defp tagged_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0,
       do: :ok

  defp tagged_ratio(_ratio), do: {:error, :ratio}

  defp normalize_ratio({:ratio, numerator, denominator}) do
    gcd = Integer.gcd(numerator, denominator)
    {:ratio, div(numerator, gcd), div(denominator, gcd)}
  end

  defp canonical_ratio(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
  end

  defp optional_exact(attrs, key, expected) do
    case Keyword.fetch(attrs, key) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _value} -> {:error, {key, expected}}
      :error -> {:ok, expected}
    end
  end

  defp optional_member(attrs, key, values, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, {key, values}}
      :error -> {:ok, default}
    end
  end

  defp member(value, values) do
    if value in values, do: {:ok, value}, else: {:error, :member}
  end

  defp positive_number(value) when is_number(value) and value > 0, do: :ok
  defp positive_number(_value), do: {:error, :number}

  defp number(value) when is_number(value), do: :ok
  defp number(_value), do: {:error, :number}

  defp tagged_offset(value) when is_number(value), do: :ok

  defp tagged_offset({unit, value}) when unit in [:pixels, :scale] and is_number(value),
    do: :ok

  defp tagged_offset(_value), do: {:error, :offset}

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
end
