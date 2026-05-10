defmodule ImagePlug.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation.AutoOrient
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Flip
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Plan.Operation.ResizeCover
  alias ImagePlug.Plan.Operation.ResizeFit
  alias ImagePlug.Plan.Operation.ResizeStretch
  alias ImagePlug.Plan.Operation.Rotate

  @enlargements [:allow, :deny]
  @right_angles [0, 90, 180, 270]
  @flip_axes [:horizontal, :vertical, :both]
  @prefetch_spaces [:source, :current]
  @x_anchors [:left, :center, :right]
  @y_anchors [:top, :center, :bottom]
  @semantic_modules [
    CropGuided,
    CropRegion,
    Canvas,
    AutoOrient,
    Rotate,
    Flip,
    ResizeFit,
    ResizeCover,
    ResizeStretch,
    ResizeAuto
  ]

  @type resize_operation ::
          ResizeFit.t()
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

  @type error :: {:invalid_operation, atom(), term()}
  @type validation_error :: {:invalid_pipeline_operation, term()}

  @spec crop_guided(keyword()) :: {:ok, CropGuided.t()} | {:error, error()}
  def crop_guided(size: %Size{} = size, guide: %Gravity{} = guide) do
    {:ok, %CropGuided{size: size, guide: guide}}
  end

  def crop_guided(attrs), do: invalid(:crop_guided, attrs)

  @spec crop_region(keyword()) :: {:ok, CropRegion.t()} | {:error, error()}
  def crop_region(region: %Region{} = region) do
    {:ok, %CropRegion{region: region}}
  end

  def crop_region(attrs), do: invalid(:crop_region, attrs)

  @spec canvas(keyword()) :: {:ok, Canvas.t()} | {:error, error()}
  def canvas(
        size: %Size{} = size,
        placement: %Gravity{} = placement,
        background: :white,
        overflow: :reject
      ) do
    {:ok, %Canvas{size: size, placement: placement, background: :white, overflow: :reject}}
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

  @spec resize_fit(keyword()) :: {:ok, ResizeFit.t()} | {:error, error()}
  def resize_fit(size: %Size{} = size, enlargement: enlargement)
      when enlargement in @enlargements do
    {:ok, %ResizeFit{size: size, enlargement: enlargement}}
  end

  def resize_fit(attrs), do: invalid(:resize_fit, attrs)

  @spec resize_cover(keyword()) :: {:ok, ResizeCover.t()} | {:error, error()}
  def resize_cover(size: %Size{} = size, enlargement: enlargement, guide: %Gravity{} = guide)
      when enlargement in @enlargements do
    {:ok, %ResizeCover{size: size, enlargement: enlargement, guide: guide}}
  end

  def resize_cover(attrs), do: invalid(:resize_cover, attrs)

  @spec resize_stretch(keyword()) :: {:ok, ResizeStretch.t()} | {:error, error()}
  def resize_stretch(size: %Size{} = size, enlargement: enlargement)
      when enlargement in @enlargements do
    {:ok, %ResizeStretch{size: size, enlargement: enlargement}}
  end

  def resize_stretch(attrs), do: invalid(:resize_stretch, attrs)

  @spec resize_auto(keyword()) :: {:ok, ResizeAuto.t()} | {:error, error()}
  def resize_auto(size: %Size{} = size, enlargement: enlargement)
      when enlargement in @enlargements do
    {:ok, %ResizeAuto{size: size, enlargement: enlargement}}
  end

  def resize_auto(attrs), do: invalid(:resize_auto, attrs)

  @spec semantic?(term()) :: boolean()
  def semantic?(%module{}), do: module in @semantic_modules
  def semantic?(_operation), do: false

  @spec validate_prefetch_safe(term()) :: :ok | {:error, validation_error()}
  def validate_prefetch_safe(%ResizeFit{size: size, enlargement: enlargement} = operation)
      when enlargement in @enlargements do
    validate_resize_size(size, operation)
  end

  def validate_prefetch_safe(
        %ResizeCover{
          size: size,
          enlargement: enlargement,
          guide: guide
        } = operation
      )
      when enlargement in @enlargements do
    with :ok <- validate_resize_size(size, operation) do
      validate_gravity(guide, operation)
    end
  end

  def validate_prefetch_safe(%ResizeStretch{size: size, enlargement: enlargement} = operation)
      when enlargement in @enlargements do
    validate_resize_size(size, operation)
  end

  def validate_prefetch_safe(%ResizeAuto{size: size, enlargement: enlargement} = operation)
      when enlargement in @enlargements do
    validate_resize_size(size, operation)
  end

  def validate_prefetch_safe(%CropGuided{size: size, guide: guide} = operation) do
    with :ok <- validate_crop_size(size, operation) do
      validate_gravity(guide, operation)
    end
  end

  def validate_prefetch_safe(%CropRegion{region: region} = operation) do
    validate_region(region, operation)
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

  defp validate_resize_size(%Size{} = size, operation) do
    with :ok <- validate_resize_dimension(size.width, operation),
         :ok <- validate_resize_dimension(size.height, operation) do
      validate_dpr(size.dpr, operation)
    end
  end

  defp validate_resize_size(_size, operation), do: invalid_pipeline_operation(operation)

  defp validate_crop_size(%Size{} = size, operation) do
    with :ok <- validate_crop_dimension(size.width, operation),
         :ok <- validate_crop_dimension(size.height, operation) do
      validate_dpr(size.dpr, operation)
    end
  end

  defp validate_crop_size(_size, operation), do: invalid_pipeline_operation(operation)

  defp validate_canvas_size(%Size{} = size, operation) do
    with :ok <- validate_resize_dimension(size.width, operation),
         :ok <- validate_resize_dimension(size.height, operation) do
      validate_dpr(size.dpr, operation)
    end
  end

  defp validate_canvas_size(_size, operation), do: invalid_pipeline_operation(operation)

  defp validate_region(%Region{} = region, operation) when region.space in @prefetch_spaces do
    with :ok <- validate_region_dimension(region.x, operation),
         :ok <- validate_region_dimension(region.y, operation),
         :ok <- validate_region_dimension(region.width, operation) do
      validate_region_dimension(region.height, operation)
    end
  end

  defp validate_region(_region, operation), do: invalid_pipeline_operation(operation)

  defp validate_gravity(%Gravity{type: :anchor, x: x, y: y, space: space}, _operation)
       when x in @x_anchors and y in @y_anchors and space in @prefetch_spaces,
       do: :ok

  defp validate_gravity(%Gravity{type: :focal_point, x: x, y: y, space: space}, operation)
       when space in @prefetch_spaces do
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

  defp validate_crop_dimension(
         %Dimension{unit: :full_axis, value: nil, numerator: nil, denominator: nil},
         _operation
       ),
       do: :ok

  defp validate_crop_dimension(
         %Dimension{unit: :logical_px, value: value, numerator: nil, denominator: nil},
         _operation
       )
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_crop_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_region_dimension(
         %Dimension{unit: :logical_px, value: value, numerator: nil, denominator: nil},
         _operation
       )
       when is_integer(value) and value > 0,
       do: :ok

  defp validate_region_dimension(
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

  defp validate_region_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_ratio_dimension(
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

  defp validate_ratio_dimension(_dimension, operation), do: invalid_pipeline_operation(operation)

  defp validate_dpr(dpr, _operation) when is_number(dpr) and dpr > 0, do: :ok
  defp validate_dpr(_dpr, operation), do: invalid_pipeline_operation(operation)

  defp invalid_pipeline_operation(operation),
    do: {:error, {:invalid_pipeline_operation, operation}}
end
