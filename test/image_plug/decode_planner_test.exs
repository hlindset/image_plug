defmodule ImagePlug.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.DecodePlanner
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Resize

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

  test "width-only fit resize opens sequentially" do
    chain = [
      %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 120}, height: :auto}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "height-only fit resize opens sequentially" do
    chain = [
      %Resize{rule: %DimensionRule{mode: :fit, width: :auto, height: {:pixels, 120}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "auto-orient-only chains open sequentially" do
    assert DecodePlanner.open_options([
             %AutoOrient{}
           ]) == [access: :sequential, fail_on: :error]
  end

  test "two-dimensional fit resize opens sequentially" do
    chain = [
      %Resize{
        rule: %DimensionRule{mode: :fit, width: {:pixels, 120}, height: {:pixels, 90}}
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

  test "crops stay random" do
    assert DecodePlanner.open_options([
             %Crop{width: {:pixels, 80}, height: {:pixels, 80}, crop_from: :gravity}
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
    assert {:ok, resize_auto} = Operation.resize(:auto, {:px, 80}, {:px, 80})

    assert {:ok, crop_region} =
             Operation.crop_region(
               {:ratio, 1, 4},
               {:ratio, 1, 4},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert DecodePlanner.open_options([resize_auto]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([crop_region]) == [access: :random, fail_on: :error]
  end

  test "semantic fit and stretch with requested dimensions stay sequential" do
    assert {:ok, fit} = Operation.resize(:fit, {:px, 100}, :auto)
    assert {:ok, stretch} = Operation.resize(:stretch, {:px, 100}, :auto)

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
      %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 120}, height: :auto}}
    ]

    assert Keyword.keys(DecodePlanner.open_options(chain)) == [:access, :fail_on]
  end
end
