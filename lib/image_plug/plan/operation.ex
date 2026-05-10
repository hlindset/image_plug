defmodule ImagePlug.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.ResizeAuto
  alias ImagePlug.Plan.Operation.ResizeCover
  alias ImagePlug.Plan.Operation.ResizeFit
  alias ImagePlug.Plan.Operation.ResizeStretch

  @enlargements [:allow, :deny]

  @type resize_operation ::
          ResizeFit.t()
          | ResizeCover.t()
          | ResizeStretch.t()
          | ResizeAuto.t()

  @type crop_operation ::
          CropGuided.t()
          | CropRegion.t()

  @type semantic_operation :: resize_operation() | crop_operation()

  @type error :: {:invalid_operation, atom(), term()}

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

  defp invalid(operation, attrs), do: {:error, {:invalid_operation, operation, attrs}}
end
