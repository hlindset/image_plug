defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation

  describe "resize constructors" do
    test "build unified resize operations through exported constructor" do
      for mode <- [:fit, :cover, :stretch, :auto] do
        assert {:ok,
                %Operation.Resize{
                  mode: ^mode,
                  width: {:px, 300},
                  height: :auto,
                  dpr: {:ratio, 1, 1},
                  enlargement: :deny,
                  guide: :center,
                  min_width: nil,
                  min_height: nil,
                  zoom_x: 1.0,
                  zoom_y: 1.0
                }} = Operation.resize(mode, {:px, 300}, :auto)
      end
    end

    test "builds resize operation with explicit optional fields" do
      assert {:ok,
              %Operation.Resize{
                mode: :cover,
                width: {:px, 300},
                height: {:px, 200},
                dpr: {:ratio, 3, 2},
                enlargement: :allow,
                guide: {:anchor, :center, :bottom},
                min_width: {:px, 100},
                min_height: {:px, 50},
                zoom_x: 1.25,
                zoom_y: 2
              }} =
               Operation.resize(:cover, {:px, 300}, {:px, 200},
                 dpr: "1.50",
                 enlargement: :allow,
                 guide: {:anchor, :center, :bottom},
                 min_width: {:px, 100},
                 min_height: {:px, 50},
                 zoom_x: 1.25,
                 zoom_y: 2
               )
    end

    test "reject malformed resize construction without raising" do
      assert Operation.resize(:fill, {:px, 300}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fill, {:px, 300}, :auto, []]}}

      assert Operation.resize(:fit, {:px, 0}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 0}, :auto, []]}}

      assert Operation.resize(:fit, {:ratio, 1, 2}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fit, {:ratio, 1, 2}, :auto, []]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, min_width: {:px, 0}) ==
               {:error,
                {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [min_width: {:px, 0}]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, dpr: 0) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [dpr: 0]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.x") ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [dpr: "1.x"]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, zoom_x: 0) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [zoom_x: 0]]}}
    end
  end

  describe "crop constructors" do
    test "build crop operations through exported constructors" do
      assert {:ok, size} = crop_size()
      assert {:ok, guide} = Gravity.anchor(:center, :center)
      assert {:ok, region} = region()

      assert {:ok, %Operation.CropGuided{size: ^size, guide: ^guide}} =
               Operation.crop_guided(size: size, guide: guide)

      assert {:ok, %Operation.CropRegion{region: ^region}} =
               Operation.crop_region(region: region)
    end

    test "reject invalid crop constructor inputs without raising" do
      assert {:ok, size} = crop_size()
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

    test "reject unsupported crop region dimensions and spaces at construction" do
      assert {:ok, zero} = Dimension.ratio(0, 1)
      assert {:ok, x} = Dimension.ratio(0, 1)
      assert {:ok, y} = Dimension.ratio(0, 1)
      assert {:ok, positive} = Dimension.ratio(1, 2)

      for attrs <- [
            [x: x, y: y, width: zero, height: positive, space: :source],
            [x: x, y: y, width: positive, height: zero, space: :source],
            [x: x, y: y, width: positive, height: positive, space: :post_orient]
          ] do
        assert {:ok, region} = Region.new(attrs)

        assert Operation.crop_region(region: region) ==
                 {:error, {:invalid_operation, :crop_region, [region: region]}}
      end
    end

    test "allow zero crop region coordinates at construction" do
      assert {:ok, zero} = Dimension.pixels(0)
      assert {:ok, width} = Dimension.pixels(100)
      assert {:ok, height} = Dimension.pixels(50)

      assert {:ok, region} =
               Region.new(x: zero, y: zero, width: width, height: height, space: :source)

      assert Operation.crop_region(region: region) == {:ok, %Operation.CropRegion{region: region}}
    end

    test "reject unsupported crop guide values at construction" do
      assert {:ok, size} = crop_size()
      assert {:ok, point} = Dimension.pixels(10)
      pixel_focal = %Gravity{type: :focal_point, x: point, y: point, space: :current}
      source_anchor = %Gravity{type: :anchor, x: :center, y: :center, space: :source}

      assert Operation.crop_guided(size: size, guide: pixel_focal) ==
               {:error, {:invalid_operation, :crop_guided, [size: size, guide: pixel_focal]}}

      assert Operation.crop_guided(size: size, guide: source_anchor) ==
               {:error, {:invalid_operation, :crop_guided, [size: size, guide: source_anchor]}}
    end
  end

  describe "canvas constructor" do
    test "builds canvas operation through exported constructor" do
      assert {:ok, size} = crop_size()
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
      assert {:ok, fit} = Operation.resize(:fit, {:px, 300}, :auto)
      assert {:ok, cover} = Operation.resize(:cover, {:px, 300}, :auto)
      assert {:ok, stretch} = Operation.resize(:stretch, {:px, 300}, :auto)
      assert {:ok, auto} = Operation.resize(:auto, {:px, 300}, :auto)
      assert {:ok, crop_size} = crop_size()
      assert {:ok, guided} = Operation.crop_guided(size: crop_size, guide: guide)
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
      assert {:ok, fit} = Operation.resize(:fit, :auto, :auto)
      assert {:ok, stretch} = Operation.resize(:stretch, :auto, :auto)

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

  defp crop_size do
    with {:ok, width} <- Dimension.pixels(300),
         {:ok, height} <- Dimension.pixels(200) do
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
