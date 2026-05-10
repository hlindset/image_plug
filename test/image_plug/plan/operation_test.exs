defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation

  describe "resize constructors" do
    test "build resize operations through exported constructors" do
      assert {:ok, size} = size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)

      assert {:ok, %Operation.ResizeFit{size: ^size, enlargement: :allow}} =
               Operation.resize_fit(size: size, enlargement: :allow)

      assert {:ok, %Operation.ResizeCover{size: ^size, enlargement: :deny, guide: ^guide}} =
               Operation.resize_cover(size: size, enlargement: :deny, guide: guide)

      assert {:ok, %Operation.ResizeStretch{size: ^size, enlargement: :allow}} =
               Operation.resize_stretch(size: size, enlargement: :allow)

      assert {:ok, %Operation.ResizeAuto{size: ^size, enlargement: :deny}} =
               Operation.resize_auto(size: size, enlargement: :deny)
    end

    test "reject invalid resize constructor inputs without raising" do
      assert {:ok, size} = size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)

      assert Operation.resize_fit(size: :not_size, enlargement: :allow) ==
               {:error, {:invalid_operation, :resize_fit, [size: :not_size, enlargement: :allow]}}

      assert Operation.resize_fit(size: size, enlargement: :maybe) ==
               {:error, {:invalid_operation, :resize_fit, [size: size, enlargement: :maybe]}}

      assert Operation.resize_cover(size: size, enlargement: :allow, guide: :center) ==
               {:error,
                {:invalid_operation, :resize_cover,
                 [size: size, enlargement: :allow, guide: :center]}}

      assert Operation.resize_cover(size: size, enlargement: :deny, guide: guide) ==
               {:ok, %Operation.ResizeCover{size: size, enlargement: :deny, guide: guide}}

      assert Operation.resize_stretch(size: :not_size, enlargement: :allow) ==
               {:error,
                {:invalid_operation, :resize_stretch, [size: :not_size, enlargement: :allow]}}

      assert Operation.resize_auto(size: size, enlargement: :maybe) ==
               {:error, {:invalid_operation, :resize_auto, [size: size, enlargement: :maybe]}}
    end
  end

  describe "crop constructors" do
    test "build crop operations through exported constructors" do
      assert {:ok, size} = size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)
      assert {:ok, region} = region()

      assert {:ok, %Operation.CropGuided{size: ^size, guide: ^guide}} =
               Operation.crop_guided(size: size, guide: guide)

      assert {:ok, %Operation.CropRegion{region: ^region}} =
               Operation.crop_region(region: region)
    end

    test "reject invalid crop constructor inputs without raising" do
      assert {:ok, size} = size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)
      assert {:ok, region} = region()

      assert Operation.crop_guided(size: :not_size, guide: guide) ==
               {:error, {:invalid_operation, :crop_guided, [size: :not_size, guide: guide]}}

      assert Operation.crop_guided(size: size, guide: :center) ==
               {:error, {:invalid_operation, :crop_guided, [size: size, guide: :center]}}

      assert Operation.crop_region(region: :not_region) ==
               {:error, {:invalid_operation, :crop_region, [region: :not_region]}}

      assert Operation.crop_region(region: region) == {:ok, %Operation.CropRegion{region: region}}
    end
  end

  describe "canvas constructor" do
    test "builds canvas operation through exported constructor" do
      assert {:ok, size} = size()
      assert {:ok, placement} = Gravity.anchor(:center, :center)

      assert {:ok,
              %Operation.Canvas{
                size: ^size,
                placement: ^placement,
                background: :white,
                overflow: :reject
              }} =
               Operation.canvas(
                 size: size,
                 placement: placement,
                 background: :white,
                 overflow: :reject
               )
    end

    test "rejects unsupported canvas values without raising" do
      assert {:ok, size} = size()
      assert {:ok, placement} = Gravity.anchor(:center, :center)

      assert Operation.canvas(
               size: :not_size,
               placement: placement,
               background: :white,
               overflow: :reject
             ) ==
               {:error,
                {:invalid_operation, :canvas,
                 [size: :not_size, placement: placement, background: :white, overflow: :reject]}}

      assert Operation.canvas(
               size: size,
               placement: placement,
               background: :transparent,
               overflow: :reject
             ) ==
               {:error,
                {:invalid_operation, :canvas,
                 [size: size, placement: placement, background: :transparent, overflow: :reject]}}

      assert Operation.canvas(
               size: size,
               placement: placement,
               background: :white,
               overflow: :crop
             ) ==
               {:error,
                {:invalid_operation, :canvas,
                 [size: size, placement: placement, background: :white, overflow: :crop]}}
    end
  end

  defp size do
    with {:ok, width} <- Dimension.pixels(300),
         {:ok, height} <- Dimension.auto() do
      Size.new(width: width, height: height, dpr: 1.0)
    end
  end

  defp region do
    with {:ok, x} <- Dimension.ratio(1, 10),
         {:ok, y} <- Dimension.ratio(1, 10),
         {:ok, width} <- Dimension.ratio(1, 2),
         {:ok, height} <- Dimension.ratio(1, 2) do
      Region.new(x: x, y: y, width: width, height: height, space: :source)
    end
  end
end
