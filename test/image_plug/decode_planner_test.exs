defmodule ImagePlug.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Contain
  alias ImagePlug.Transform.Operation.Cover
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.DecodePlanner
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Focus
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Scale

  defmodule NoGeometryTransform do
    defstruct []

    def name(%__MODULE__{}), do: :no_geometry
    def validate(%__MODULE__{}), do: :ok
    def metadata(%__MODULE__{}), do: %{access: :neutral}
    def execute(%__MODULE__{}, state), do: state
  end

  defmodule MissingMetadataCallbackTransform do
    defstruct []

    def name(%__MODULE__{}), do: :missing_metadata_callback
    def validate(%__MODULE__{}), do: :ok
    def execute(%__MODULE__{}, state), do: state
  end

  defmodule RaisingMetadataTransform do
    defstruct []

    def name(%__MODULE__{}), do: :raising_metadata
    def validate(%__MODULE__{}), do: :ok
    def metadata(%__MODULE__{}), do: raise("metadata failed")
    def execute(%__MODULE__{}, state), do: state
  end

  defmodule ThrowingMetadataTransform do
    defstruct []

    def name(%__MODULE__{}), do: :throwing_metadata
    def validate(%__MODULE__{}), do: :ok
    def metadata(%__MODULE__{}), do: throw(:metadata_failed)
    def execute(%__MODULE__{}, state), do: state
  end

  defmodule ExitingMetadataTransform do
    defstruct []

    def name(%__MODULE__{}), do: :exiting_metadata
    def validate(%__MODULE__{}), do: :ok
    def metadata(%__MODULE__{}), do: exit(:metadata_failed)
    def execute(%__MODULE__{}, state), do: state
  end

  test "empty chains open randomly with fail_on error" do
    assert DecodePlanner.open_options([]) == [access: :random, fail_on: :error]
  end

  test "no-geometry chains open randomly" do
    assert DecodePlanner.open_options([
             %NoGeometryTransform{}
           ]) == [access: :random, fail_on: :error]
  end

  test "width-only scale opens sequentially" do
    chain = [
      %Scale{type: :dimensions, width: {:pixels, 120}, height: :auto}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "height-only scale opens sequentially" do
    chain = [
      %Scale{type: :dimensions, width: :auto, height: {:pixels, 120}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "auto-orient-only chains open sequentially" do
    assert DecodePlanner.open_options([
             %AutoOrient{}
           ]) == [access: :sequential, fail_on: :error]
  end

  test "two-dimensional scale stays random" do
    chain = [
      %Scale{type: :dimensions, width: {:pixels, 120}, height: {:pixels, 90}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "ratio scale stays random" do
    chain = [
      %Scale{type: :ratio, ratio: {4, 3}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "regular non-letterboxed dimension contain opens sequentially" do
    chain = [
      %Contain{
        type: :dimensions,
        width: {:pixels, 120},
        height: {:pixels, 90},
        constraint: :regular,
        letterbox: false
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "force resize with requested dimensions opens sequentially" do
    chain = [
      %Resize{
        rule: %DimensionRule{
          mode: :force,
          width: {:pixels, 120},
          height: :auto
        }
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]

    chain = [
      %Resize{
        rule: %DimensionRule{
          mode: :force,
          width: {:pixels, 120},
          height: {:pixels, 90}
        }
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "width-only and height-only regular non-letterboxed contain open sequentially" do
    assert DecodePlanner.open_options([
             %Contain{
               type: :dimensions,
               width: {:pixels, 120},
               height: :auto,
               constraint: :regular,
               letterbox: false
             }
           ]) == [access: :sequential, fail_on: :error]

    assert DecodePlanner.open_options([
             %Contain{
               type: :dimensions,
               width: :auto,
               height: {:pixels, 90},
               constraint: :regular,
               letterbox: false
             }
           ]) == [access: :sequential, fail_on: :error]
  end

  test "ratio contain stays random" do
    chain = [
      %Contain{type: :ratio, ratio: {4, 3}, letterbox: false}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "min contain stays random" do
    chain = [
      %Contain{
        type: :dimensions,
        width: {:pixels, 120},
        height: {:pixels, 90},
        constraint: :min,
        letterbox: false
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "max contain stays random" do
    chain = [
      %Contain{
        type: :dimensions,
        width: {:pixels, 120},
        height: {:pixels, 90},
        constraint: :max,
        letterbox: false
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "letterboxed contain stays random" do
    chain = [
      %Contain{
        type: :dimensions,
        width: {:pixels, 120},
        height: {:pixels, 90},
        constraint: :regular,
        letterbox: true
      }
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "focus crop and cover stay random" do
    assert DecodePlanner.open_options([
             %Focus{type: {:anchor, :left, :top}},
             %Scale{type: :dimensions, width: {:pixels, 120}, height: :auto}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             %Crop{width: {:pixels, 80}, height: {:pixels, 80}, crop_from: :focus}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             %Cover{
               type: :dimensions,
               width: {:pixels, 80},
               height: {:pixels, 80},
               constraint: :none
             }
           ]) == [access: :random, fail_on: :error]
  end

  test "fill resize and extend canvas stay random" do
    assert DecodePlanner.open_options([
             %Resize{
               rule: %DimensionRule{
                 mode: :fill,
                 width: {:pixels, 80},
                 height: {:pixels, 80}
               }
             }
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             %ExtendCanvas{
               rule: {:dimensions, {:pixels, 80}, {:pixels, 80}},
               gravity: {:anchor, :center, :center},
               background: :white
             }
           ]) == [access: :random, fail_on: :error]
  end

  test "unresolved semantic source-dependent operations stay random before metadata" do
    assert {:ok, width} = Dimension.pixels(80)
    assert {:ok, height} = Dimension.pixels(80)
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, resize_auto} = Operation.resize_auto(size: size, enlargement: :deny)

    assert {:ok, x} = Dimension.ratio(1, 4)
    assert {:ok, y} = Dimension.ratio(1, 4)
    assert {:ok, region_width} = Dimension.ratio(1, 2)
    assert {:ok, region_height} = Dimension.ratio(1, 2)

    assert {:ok, region} =
             Region.new(
               x: x,
               y: y,
               width: region_width,
               height: region_height,
               space: :source
             )

    assert {:ok, crop_region} = Operation.crop_region(region: region)

    assert DecodePlanner.open_options([resize_auto]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([crop_region]) == [access: :random, fail_on: :error]
  end

  test "semantic fit and stretch with requested dimensions stay sequential" do
    assert {:ok, width} = Dimension.pixels(100)
    assert {:ok, height} = Dimension.auto()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)

    assert {:ok, fit} = Operation.resize_fit(size: size, enlargement: :deny)
    assert {:ok, stretch} = Operation.resize_stretch(size: size, enlargement: :deny)

    assert DecodePlanner.open_options([fit]) == [access: :sequential, fail_on: :error]
    assert DecodePlanner.open_options([stretch]) == [access: :sequential, fail_on: :error]
  end

  test "trusted transform metadata callback failures propagate" do
    assert_raise UndefinedFunctionError, fn ->
      DecodePlanner.open_options([
        %MissingMetadataCallbackTransform{}
      ])
    end

    assert_raise RuntimeError, "metadata failed", fn ->
      DecodePlanner.open_options([
        %RaisingMetadataTransform{}
      ])
    end

    assert catch_throw(
             DecodePlanner.open_options([
               %ThrowingMetadataTransform{}
             ])
           ) == :metadata_failed

    assert catch_exit(
             DecodePlanner.open_options([
               %ExitingMetadataTransform{}
             ])
           ) == :metadata_failed
  end

  test "planned options include only access and fail_on" do
    chain = [
      %Scale{type: :dimensions, width: {:pixels, 120}, height: :auto}
    ]

    assert Keyword.keys(DecodePlanner.open_options(chain)) == [:access, :fail_on]
  end
end
