defmodule ImagePlug.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
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

  @type error :: {:invalid_operation, atom(), term()}

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
