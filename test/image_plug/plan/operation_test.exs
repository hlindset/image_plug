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

      assert Operation.resize_fit(size: size, enlargement: :allow, min_heigth: 100) ==
               {:error, {:unknown_operation_options, :resize_fit, [:min_heigth]}}

      assert Operation.resize_fit(size: :not_size, enlargement: :allow) ==
               {:error, {:invalid_operation, :resize_fit, [size: :not_size, enlargement: :allow]}}

      assert Operation.resize_fit(size: size, enlargement: :maybe) ==
               {:error, {:invalid_operation, :resize_fit, [size: size, enlargement: :maybe]}}

      assert Operation.resize_cover(size: size, enlargement: :allow, guide: :center) ==
               {:error,
                {:invalid_operation, :resize_cover,
                 [size: size, enlargement: :allow, guide: :center]}}

      assert Operation.resize_cover(
               size: size,
               enlargement: :allow,
               guide: guide,
               placement: guide
             ) ==
               {:error, {:unknown_operation_options, :resize_cover, [:placement]}}

      assert Operation.resize_cover(size: size, enlargement: :deny, guide: guide) ==
               {:ok, %Operation.ResizeCover{size: size, enlargement: :deny, guide: guide}}

      assert Operation.resize_stretch(size: :not_size, enlargement: :allow) ==
               {:error,
                {:invalid_operation, :resize_stretch, [size: :not_size, enlargement: :allow]}}

      assert Operation.resize_stretch(size: size, enlargement: :allow, fit: :cover) ==
               {:error, {:unknown_operation_options, :resize_stretch, [:fit]}}

      assert Operation.resize_auto(size: size, enlargement: :maybe) ==
               {:error, {:invalid_operation, :resize_auto, [size: size, enlargement: :maybe]}}

      assert Operation.resize_auto(size: size, enlargement: :allow, guide: guide, focal: guide) ==
               {:error, {:unknown_operation_options, :resize_auto, [:focal]}}
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

      assert Operation.crop_guided(size: size, guide: guide, gravity: guide) ==
               {:error, {:unknown_operation_options, :crop_guided, [:gravity]}}

      assert Operation.crop_region(region: :not_region) ==
               {:error, {:invalid_operation, :crop_region, [region: :not_region]}}

      assert Operation.crop_region(region: region, space: :source) ==
               {:error, {:unknown_operation_options, :crop_region, [:space]}}

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

      assert Operation.canvas(
               size: size,
               placement: placement,
               background: :white,
               overflow: :reject,
               source: :image
             ) ==
               {:error, {:unknown_operation_options, :canvas, [:source]}}
    end
  end

  describe "orientation constructors" do
    test "build orientation operations through exported constructors" do
      assert {:ok, %Operation.AutoOrient{}} = Operation.auto_orient()
      assert {:ok, %Operation.Rotate{angle: 90}} = Operation.rotate(90)
      assert {:ok, %Operation.Flip{axis: :horizontal}} = Operation.flip(:horizontal)
    end

    test "reject invalid orientation inputs without raising" do
      assert Operation.rotate(45) == {:error, {:invalid_operation, :rotate, 45}}
      assert Operation.flip(:diagonal) == {:error, {:invalid_operation, :flip, :diagonal}}
    end
  end

  describe "access metadata" do
    test "reports semantic operation decode access metadata" do
      assert {:ok, size} = size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)
      assert {:ok, region} = region()
      assert {:ok, fit} = Operation.resize_fit(size: size, enlargement: :deny)
      assert {:ok, cover} = Operation.resize_cover(size: size, enlargement: :deny, guide: guide)
      assert {:ok, stretch} = Operation.resize_stretch(size: size, enlargement: :deny)
      assert {:ok, auto} = Operation.resize_auto(size: size, enlargement: :deny)
      assert {:ok, guided} = Operation.crop_guided(size: size, guide: guide)
      assert {:ok, region_crop} = Operation.crop_region(region: region)

      assert Operation.access_metadata(fit) == %{access: :sequential}
      assert Operation.access_metadata(stretch) == %{access: :sequential}
      assert Operation.access_metadata(cover) == %{access: :random}
      assert Operation.access_metadata(auto) == %{access: :random}
      assert Operation.access_metadata(guided) == %{access: :random}
      assert Operation.access_metadata(region_crop) == %{access: :random}

      assert {:ok, canvas} =
               Operation.canvas(
                 size: size,
                 placement: guide,
                 background: :white,
                 overflow: :reject
               )

      assert {:ok, auto_orient} = Operation.auto_orient()
      assert {:ok, rotate} = Operation.rotate(90)
      assert {:ok, flip} = Operation.flip(:horizontal)

      assert Operation.access_metadata(canvas) == %{access: :random}
      assert Operation.access_metadata(auto_orient) == %{access: :sequential}
      assert Operation.access_metadata(rotate) == %{access: :random}
      assert Operation.access_metadata(flip) == %{access: :random}
    end

    test "reports fit and stretch without requested dimensions as random access" do
      assert {:ok, auto_width} = Dimension.auto()
      assert {:ok, auto_height} = Dimension.auto()
      assert {:ok, size} = Size.new(width: auto_width, height: auto_height, dpr: 1.0)
      assert {:ok, fit} = Operation.resize_fit(size: size, enlargement: :deny)
      assert {:ok, stretch} = Operation.resize_stretch(size: size, enlargement: :deny)

      assert Operation.access_metadata(fit) == %{access: :random}
      assert Operation.access_metadata(stretch) == %{access: :random}
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
