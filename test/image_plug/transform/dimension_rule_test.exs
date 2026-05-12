defmodule ImagePlug.Transform.DimensionRuleTest do
  use ExUnit.Case, async: true

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
             DimensionRule.resolve(rule, source_width: 1000, source_height: 1000)

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
             DimensionRule.resolve(rule, source_width: 1000, source_height: 1000)

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
             DimensionRule.resolve(rule, source_width: 1000, source_height: 1000)

    assert result.requested_width == 200
    assert result.requested_height == 200
    assert result.intermediate_width == 600
    assert result.intermediate_height == 600
  end

  test "zero dimensions with zoom do not enlarge raster sources when enlarge is false" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 0},
      height: {:pixels, 0},
      zoom_x: 2.0,
      zoom_y: 2.0,
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 100, source_height: 50)

    assert result.requested_width == 200
    assert result.requested_height == 100
    assert result.intermediate_width == 100
    assert result.intermediate_height == 50
  end

  test "zero dimensions with dpr do not enlarge raster sources when enlarge is false" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 0},
      height: {:pixels, 0},
      dpr: 2.0,
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 100, source_height: 50)

    assert result.effective_dpr == 1.0
    assert result.requested_width == 100
    assert result.requested_height == 50
    assert result.intermediate_width == 100
    assert result.intermediate_height == 50
  end

  test "force resize auto dimensions preserve source dimensions" do
    rule = %DimensionRule{mode: :force, width: :auto, height: {:pixels, 200}}

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 640, source_height: 480)

    assert result.requested_width == 640
    assert result.requested_height == 200
    assert result.intermediate_width == 640
    assert result.intermediate_height == 200

    rule = %DimensionRule{mode: :force, width: {:pixels, 300}, height: :auto}

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 640, source_height: 480)

    assert result.requested_width == 300
    assert result.requested_height == 480
    assert result.intermediate_width == 300
    assert result.intermediate_height == 480
  end

  test "force zero dimensions honor min dimensions even when enlarge is false" do
    rule = %DimensionRule{
      mode: :force,
      width: :auto,
      height: :auto,
      min_width: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 100, source_height: 50)

    assert result.target_width == 300
    assert result.target_height == 150
    assert result.intermediate_width == 300
    assert result.intermediate_height == 150
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
             DimensionRule.resolve(rule, source_width: 1000, source_height: 500)

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
             DimensionRule.resolve(rule, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints before resolving the cover resize box" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_width: {:pixels, 500},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 1000, source_height: 500)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.target_width == 500
    assert result.target_height == 500
    assert result.intermediate_width == 1000
    assert result.intermediate_height == 500
  end

  test "fill expands target before resolving the cover resize box" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 100},
      height: {:pixels, 100},
      min_width: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 1000, source_height: 500)

    assert result.target_width == 300
    assert result.target_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill-down expands target before resolving the cover resize box" do
    rule = %DimensionRule{
      mode: :fill_down,
      width: {:pixels, 100},
      height: {:pixels, 100},
      min_width: {:pixels, 300},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 1000, source_height: 500)

    assert result.target_width == 300
    assert result.target_height == 300
    assert result.intermediate_width == 600
    assert result.intermediate_height == 300
  end

  test "fill applies min constraints before cover for the opposite aspect ratio" do
    rule = %DimensionRule{
      mode: :fill,
      width: {:pixels, 300},
      height: {:pixels, 300},
      min_height: {:pixels, 500},
      enlarge: false
    }

    assert {:ok, result} =
             DimensionRule.resolve(rule, source_width: 500, source_height: 1000)

    assert result.requested_width == 300
    assert result.requested_height == 300
    assert result.target_width == 500
    assert result.target_height == 500
    assert result.intermediate_width == 500
    assert result.intermediate_height == 1000
  end

  test "effective dpr clamps below requested dpr for small non-vector sources when enlarge is false" do
    rule = %DimensionRule{
      mode: :fit,
      width: {:pixels, 500},
      height: :auto,
      dpr: 3.0,
      enlarge: false
    }

    assert {:ok, result} = DimensionRule.resolve(rule, source_width: 800, source_height: 800)
    assert result.effective_dpr == 1.6
    assert result.requested_width == 800
    assert result.requested_height == 800
    assert result.intermediate_width == 800
    assert result.intermediate_height == 800
  end
end
