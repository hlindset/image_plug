defmodule ImagePlug.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
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

  defp size do
    with {:ok, width} <- Dimension.pixels(300),
         {:ok, height} <- Dimension.auto() do
      Size.new(width: width, height: height, dpr: 1.0)
    end
  end
end
