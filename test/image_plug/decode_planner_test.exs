defmodule ImagePlug.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.DecodePlanner
  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Contain.ContainParams
  alias ImagePlug.Transform.Cover
  alias ImagePlug.Transform.Cover.CoverParams
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.Crop.CropParams
  alias ImagePlug.Transform.Focus
  alias ImagePlug.Transform.Focus.FocusParams
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams

  defmodule UnknownTransform do
    defstruct []
  end

  defmodule BogusMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: %{access: :bogus}
  end

  defmodule MissingAccessMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: %{other: :metadata}
  end

  defmodule NilMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: nil
  end

  defmodule KeywordMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: [access: :sequential]
  end

  defmodule RaisingMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: raise("metadata failed")
  end

  defmodule ThrowingMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: throw(:metadata_failed)
  end

  defmodule ExitingMetadataTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: exit(:metadata_failed)
  end

  test "empty chains open randomly with fail_on error" do
    assert DecodePlanner.open_options([]) == [access: :random, fail_on: :error]
  end

  test "width-only scale opens sequentially" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "height-only scale opens sequentially" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 120}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "two-dimensional scale stays random" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: {:pixels, 90}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "ratio scale stays random" do
    chain = [
      {Scale, %ScaleParams{type: :ratio, ratio: {4, 3}}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "regular non-letterboxed dimension contain opens sequentially" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :sequential, fail_on: :error]
  end

  test "width-only and height-only regular non-letterboxed contain open sequentially" do
    assert DecodePlanner.open_options([
             {Contain,
              %ContainParams{
                type: :dimensions,
                width: {:pixels, 120},
                height: :auto,
                constraint: :regular,
                letterbox: false
              }}
           ]) == [access: :sequential, fail_on: :error]

    assert DecodePlanner.open_options([
             {Contain,
              %ContainParams{
                type: :dimensions,
                width: :auto,
                height: {:pixels, 90},
                constraint: :regular,
                letterbox: false
              }}
           ]) == [access: :sequential, fail_on: :error]
  end

  test "ratio contain stays random" do
    chain = [
      {Contain, %ContainParams{type: :ratio, ratio: {4, 3}, letterbox: false}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "min contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :min,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "max contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :max,
         letterbox: false
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "letterboxed contain stays random" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: true
       }}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "focus crop and cover stay random" do
    assert DecodePlanner.open_options([
             {Focus, %FocusParams{type: {:anchor, :left, :top}}},
             {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {Crop, %CropParams{width: {:pixels, 80}, height: {:pixels, 80}, crop_from: :focus}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {Cover,
              %CoverParams{
                type: :dimensions,
                width: {:pixels, 80},
                height: {:pixels, 80},
                constraint: :none
              }}
           ]) == [access: :random, fail_on: :error]
  end

  test "unknown transform modules stay random" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}},
      {UnknownTransform, %UnknownTransform{}}
    ]

    assert DecodePlanner.open_options(chain) == [access: :random, fail_on: :error]
  end

  test "malformed transform metadata stays random" do
    assert DecodePlanner.open_options([
             {BogusMetadataTransform, %BogusMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {MissingAccessMetadataTransform, %MissingAccessMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {NilMetadataTransform, %NilMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {KeywordMetadataTransform, %KeywordMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]
  end

  test "failing transform metadata stays random" do
    assert DecodePlanner.open_options([
             {RaisingMetadataTransform, %RaisingMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {ThrowingMetadataTransform, %ThrowingMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]

    assert DecodePlanner.open_options([
             {ExitingMetadataTransform, %ExitingMetadataTransform{}}
           ]) == [access: :random, fail_on: :error]
  end

  test "planned options include only access and fail_on" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
    ]

    assert Keyword.keys(DecodePlanner.open_options(chain)) == [:access, :fail_on]
  end

  test "planned options for plans use the first pipeline only" do
    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{
          operations: [
            {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 120}, height: :auto}}
          ]
        },
        %Pipeline{
          operations: [
            {Cover,
             %CoverParams{
               type: :dimensions,
               width: {:pixels, 80},
               height: {:pixels, 80},
               constraint: :none
             }}
          ]
        }
      ],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }

    assert DecodePlanner.open_options(plan) == [access: :sequential, fail_on: :error]
  end
end
