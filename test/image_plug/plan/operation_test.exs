defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  describe "resize constructors" do
    test "build unified resize operations through exported constructor" do
      default_offset = {:pixels, 0.0}

      for mode <- [:fit, :cover, :stretch, :auto] do
        assert {:ok,
                %Operation.Resize{
                  mode: ^mode,
                  width: {:px, 300},
                  height: :auto,
                  dpr: {:ratio, 1, 1},
                  enlargement: :deny,
                  guide: :center,
                  x_offset: ^default_offset,
                  y_offset: ^default_offset,
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
                x_offset: {:pixels, 12.0},
                y_offset: {:scale, -0.25},
                min_width: {:px, 100},
                min_height: {:px, 50},
                zoom_x: 1.25,
                zoom_y: 2
              }} =
               Operation.resize(:cover, {:px, 300}, {:px, 200},
                 dpr: "1.50",
                 enlargement: :allow,
                 guide: {:anchor, :center, :bottom},
                 x_offset: {:pixels, 12.0},
                 y_offset: {:scale, -0.25},
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

      assert Operation.resize(:cover, {:px, 300}, {:px, 200}, x_offset: {:scale, :bad}) ==
               {:error,
                {:invalid_operation, :resize,
                 [:cover, {:px, 300}, {:px, 200}, [x_offset: {:scale, :bad}]]}}

      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 300}, :auto,
                 x_offset: {:scale, 0.0},
                 y_offset: 0
               )

      assert resize.x_offset == {:pixels, 0.0}
      assert resize.y_offset == {:pixels, 0.0}

      assert Operation.resize(:fit, {:px, 300}, :auto, x_offset: {:pixels, 1.0}) ==
               {:error,
                {:invalid_operation, :resize,
                 [:fit, {:px, 300}, :auto, [x_offset: {:pixels, 1.0}]]}}
    end
  end

  describe "crop constructors" do
    test "build crop operations through exported constructors" do
      default_offset = {:pixels, 0.0}

      assert {:ok,
              %{
                __struct__: Operation.CropGuided,
                width: {:px, 300},
                height: :full_axis,
                guide: :top_left,
                x_offset: ^default_offset,
                y_offset: {:scale, 0.25}
              }} =
               Operation.crop_guided({:px, 300}, :full_axis, :top_left, y_offset: {:scale, 0.25})

      assert {:ok,
              %{
                __struct__: Operation.CropRegion,
                x: {:ratio, 1, 10},
                y: {:px, 0},
                width: {:ratio, 1, 2},
                height: {:px, 100}
              }} =
               Operation.crop_region({:ratio, 1, 10}, {:px, 0}, {:ratio, 1, 2}, {:px, 100})
    end

    test "reject invalid crop constructor inputs without raising" do
      assert Operation.crop_guided({:px, 0}, :full_axis, :center) ==
               {:error, {:invalid_operation, :crop_guided, [{:px, 0}, :full_axis, :center, []]}}

      assert Operation.crop_guided({:px, 300}, :auto, :center) ==
               {:error, {:invalid_operation, :crop_guided, [{:px, 300}, :auto, :center, []]}}

      assert Operation.crop_guided({:px, 300}, :full_axis, {:anchor, :center, :middle}) ==
               {:error,
                {:invalid_operation, :crop_guided,
                 [{:px, 300}, :full_axis, {:anchor, :center, :middle}, []]}}

      assert Operation.crop_guided({:px, 300}, :full_axis, :center, gravity: :center) ==
               {:error, {:unknown_operation_options, :crop_guided, [:gravity]}}

      assert Operation.crop_region({:px, -1}, {:px, 0}, {:px, 100}, {:px, 100}) ==
               {:error,
                {:invalid_operation, :crop_region, [{:px, -1}, {:px, 0}, {:px, 100}, {:px, 100}]}}

      assert Operation.crop_region({:px, 0}, {:px, 0}, {:px, 0}, {:px, 100}) ==
               {:error,
                {:invalid_operation, :crop_region, [{:px, 0}, {:px, 0}, {:px, 0}, {:px, 100}]}}
    end

    test "allow zero crop region coordinates at construction" do
      assert Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:px, 100}, {:ratio, 1, 2}) ==
               {:ok,
                %{
                  __struct__: Operation.CropRegion,
                  x: {:px, 0},
                  y: {:ratio, 0, 1},
                  width: {:px, 100},
                  height: {:ratio, 1, 2}
                }}
    end

    test "allow focal crop guides with ratio coordinates" do
      assert Operation.crop_guided(
               {:px, 300},
               {:px, 200},
               {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}}
             ) ==
               {:ok,
                %{
                  __struct__: Operation.CropGuided,
                  width: {:px, 300},
                  height: {:px, 200},
                  guide: {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                  x_offset: {:pixels, 0.0},
                  y_offset: {:pixels, 0.0}
                }}
    end
  end

  describe "canvas constructor" do
    test "builds canvas operation through exported constructor" do
      assert {:ok,
              %Operation.Canvas{
                width: {:px, 300},
                height: {:px, 200},
                placement: :center,
                fill: :transparent,
                overflow: :reject
              } = operation} =
               Operation.canvas({:px, 300}, {:px, 200}, :center, overflow: :reject)

      assert operation.x_offset == 0.0
      assert operation.y_offset == 0.0

      assert {:ok,
              %Operation.Canvas{
                width: {:ratio, 16, 9},
                height: {:ratio, 1, 1},
                placement: {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                x_offset: 5.0,
                y_offset: -3.0
              }} =
               Operation.canvas(
                 {:ratio, 16, 9},
                 {:ratio, 1, 1},
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                 x_offset: 5.0,
                 y_offset: -3.0
               )
    end

    test "rejects unsupported canvas values without raising" do
      assert Operation.canvas(:full_axis, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [:full_axis, {:px, 200}, :center, []]}}

      assert Operation.canvas({:px, 0}, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [{:px, 0}, {:px, 200}, :center, []]}}

      assert Operation.canvas({:ratio, 16, 9}, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [{:ratio, 16, 9}, {:px, 200}, :center, []]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :middle) ==
               {:error, {:invalid_operation, :canvas, [{:px, 300}, {:px, 200}, :middle, []]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, fill: :white) ==
               {:error,
                {:invalid_operation, :canvas, [{:px, 300}, {:px, 200}, :center, [fill: :white]]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, overflow: :crop) ==
               {:error,
                {:invalid_operation, :canvas,
                 [{:px, 300}, {:px, 200}, :center, [overflow: :crop]]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, source: :image) ==
               {:error, {:unknown_operation_options, :canvas, [:source]}}
    end
  end

  describe "composition operation constructors" do
    test "canvas uses product-neutral fill instead of background" do
      assert {:ok, %Operation.Canvas{fill: :transparent}} =
               Operation.canvas({:px, 300}, {:px, 200}, :center)

      assert {:ok, red} = Operation.color(255, 0, 0)

      assert {:ok, %Operation.Canvas{fill: {:solid, ^red}}} =
               Operation.canvas({:px, 300}, {:px, 200}, :center, fill: {:solid, red})
    end

    test "padding stores logical sides, pixel ratio, and fill" do
      assert {:ok,
              %Operation.Padding{
                top: {:px, 1},
                right: {:px, 2},
                bottom: {:px, 3},
                left: {:px, 4},
                pixel_ratio: {:ratio, 3, 2},
                fill: :transparent
              }} =
               Operation.padding({:px, 1}, {:px, 2}, {:px, 3}, {:px, 4},
                 pixel_ratio: {:ratio, 3, 2}
               )
    end

    test "padding rejects all-zero and malformed sides" do
      assert Operation.padding({:px, 0}, {:px, 0}, {:px, 0}, {:px, 0}) ==
               {:error,
                {:invalid_operation, :padding, [{:px, 0}, {:px, 0}, {:px, 0}, {:px, 0}, []]}}

      assert Operation.padding({:px, -1}, {:px, 0}, {:px, 0}, {:px, 0}) ==
               {:error,
                {:invalid_operation, :padding, [{:px, -1}, {:px, 0}, {:px, 0}, {:px, 0}, []]}}
    end

    test "flatten background stores canonical color" do
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert Operation.flatten_background(red) == {:ok, %Operation.FlattenBackground{color: red}}
    end

    test "semantic validation accepts composition structs" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, flatten} = Operation.flatten_background(red)

      assert Operation.semantic?(padding)
      assert Operation.semantic?(flatten)

      refute Operation.semantic?(%Operation.Padding{
               top: {:px, 0},
               right: {:px, 0},
               bottom: {:px, 0},
               left: {:px, 0},
               pixel_ratio: {:ratio, 1, 1},
               fill: :transparent
             })
    end
  end

  describe "orientation primitive allowlist" do
    test "allows executable orientation primitives as semantic plan operations" do
      assert Operation.semantic?(%AutoOrient{})
      assert Operation.semantic?(%Rotate{angle: 90})
      assert Operation.semantic?(%Flip{axis: :horizontal})
    end

    test "rejects orientation primitive values outside the explicit allowlist" do
      refute Operation.semantic?(%Rotate{angle: 45})
      refute Operation.semantic?(%Flip{axis: :diagonal})
    end
  end
end
