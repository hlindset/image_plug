defmodule ImagePlug.Transform.DimensionResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule

  test "min width interacts with fit without zoom" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)

    assert result.requested_width == 100
    assert result.requested_height == 100
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "zoom scales requested dimensions but not min constraints" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      zoom_x: 2.0,
      zoom_y: 2.0,
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)

    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 300
    assert result.intermediate_height == 300
  end

  test "dpr scales requested dimensions and participates in min-limited scale" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_width: {:pixels, 300},
      dpr: 2.0,
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 1000)

    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 600
    assert result.intermediate_height == 600
  end

  test "min height interacts with fit as a scale constraint" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto,
      min_height: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 500)

    assert result.requested_width == 100
    assert result.requested_height == 50
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill resolves intermediate dimensions to the cover resize box" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints after resolving the cover resize box" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_width: {:pixels, 500},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints after cover for the opposite aspect ratio" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_height: {:pixels, 500},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionResolver.resolve(rule, source_width: 500, source_height: 1000)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.intermediate_width == 300
    assert result.intermediate_height == 600
  end

  test "effective dpr clamps below requested dpr for small non-vector sources when enlarge is false" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 500},
      height: :auto,
      dpr: 3.0,
      enlarge: false
    }

    assert {:ok, result} = DimensionResolver.resolve(rule, source_width: 800, source_height: 800)
    assert result.effective_dpr == 1.6
    assert result.requested_width == 800
    assert result.requested_height == 800
    assert result.intermediate_width == 800
    assert result.intermediate_height == 800
  end
end
