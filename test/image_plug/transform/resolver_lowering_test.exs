defmodule ImagePlug.Transform.ResolverLoweringTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.SourceMetadata

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp metadata do
    %SourceMetadata{width: 300, height: 200, orientation: :normal, format: :jpeg}
  end

  defp size(width, height) do
    with {:ok, width} <- Dimension.pixels(width),
         {:ok, height} <- Dimension.pixels(height) do
      Size.new(width: width, height: height, dpr: 1.0)
    end
  end

  test "resize fit, cover, and stretch lower to existing resize rules" do
    assert {:ok, guide} = Gravity.anchor(:center, :center)
    assert {:ok, fit_size} = size(100, 80)
    assert {:ok, cover_size} = size(50, 50)
    assert {:ok, stretch_size} = size(20, 10)
    assert {:ok, fit} = Operation.resize_fit(size: fit_size, enlargement: :deny)

    assert {:ok, cover} =
             Operation.resize_cover(size: cover_size, enlargement: :allow, guide: guide)

    assert {:ok, stretch} = Operation.resize_stretch(size: stretch_size, enlargement: :allow)

    assert {:ok, resolved} = Transform.resolve(plan([fit, cover, stretch]), metadata(), [])

    assert [
             [
               %Resize{
                 rule: %DimensionRule{
                   mode: :fit,
                   width: {:pixels, 100},
                   height: {:pixels, 80},
                   enlarge: false
                 }
               },
               %Resize{
                 rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 50},
                   height: {:pixels, 50},
                   enlarge: true
                 }
               },
               %Crop{
                 target_rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 50},
                   height: {:pixels, 50}
                 },
                 crop_from: :gravity,
                 gravity: {:anchor, :center, :center}
               },
               %Resize{
                 rule: %DimensionRule{
                   mode: :force,
                   width: {:pixels, 20},
                   height: {:pixels, 10},
                   enlarge: true
                 }
               }
             ]
           ] = resolved.pipelines

    assert resolved.selections == []
    assert resolved.resolver_material == []
  end

  test "unified resize modes lower to existing resize rules" do
    assert {:ok, fit} = Operation.resize(:fit, {:px, 100}, {:px, 80}, enlargement: :deny)

    assert {:ok, cover} =
             Operation.resize(:cover, {:px, 50}, {:px, 50},
               enlargement: :allow,
               guide: {:anchor, :center, :center}
             )

    assert {:ok, stretch} =
             Operation.resize(:stretch, {:px, 20}, {:px, 10}, enlargement: :allow)

    assert {:ok, resolved} = Transform.resolve(plan([fit, cover, stretch]), metadata(), [])

    assert [
             [
               %Resize{
                 rule: %DimensionRule{
                   mode: :fit,
                   width: {:pixels, 100},
                   height: {:pixels, 80},
                   enlarge: false
                 }
               },
               %Resize{
                 rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 50},
                   height: {:pixels, 50},
                   enlarge: true
                 }
               },
               %Crop{
                 target_rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 50},
                   height: {:pixels, 50}
                 },
                 crop_from: :gravity,
                 gravity: {:anchor, :center, :center}
               },
               %Resize{
                 rule: %DimensionRule{
                   mode: :force,
                   width: {:pixels, 20},
                   height: {:pixels, 10},
                   enlarge: true
                 }
               }
             ]
           ] = resolved.pipelines
  end

  test "unified resize auto lowers through current source-aware branch rule" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 50}, enlargement: :deny)

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [
             [
               %Resize{
                 rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 100},
                   height: {:pixels, 50}
                 }
               },
               %Crop{
                 target_rule: %DimensionRule{
                   mode: :fill,
                   width: {:pixels, 100},
                   height: {:pixels, 50}
                 },
                 crop_from: :gravity,
                 gravity: {:anchor, :center, :center}
               }
             ]
           ] = resolved.pipelines
  end

  test "guided crop lowers to existing gravity crop" do
    assert {:ok, operation} =
             Operation.crop_guided({:px, 50}, :full_axis, :bottom_right,
               x_offset: {:pixels, 3},
               y_offset: {:scale, 0.25}
             )

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [
             [
               %Crop{
                 width: {:pixels, 50},
                 height: :auto,
                 crop_from: :gravity,
                 gravity: {:anchor, :right, :bottom},
                 x_offset: {:pixels, 3},
                 y_offset: {:scale, 0.25}
               }
             ]
           ] = resolved.pipelines
  end

  test "ratio crop region lowers to executable scale crop" do
    assert {:ok, operation} =
             Operation.crop_region({:ratio, 0, 1}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:ratio, 1, 2})

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [
             [
               %Crop{
                 width: {:scale, 1, 2},
                 height: {:scale, 1, 2},
                 crop_from: %{left: {:scale, 0, 1}, top: {:scale, 0, 1}}
               }
             ]
           ] = resolved.pipelines
  end

  test "source-aware operations use current dimensions after earlier semantic operations" do
    assert {:ok, auto_size} = size(100, 50)
    assert {:ok, crop} = Operation.crop_guided({:px, 100}, {:px, 200}, :center)
    assert {:ok, auto} = Operation.resize_auto(size: auto_size, enlargement: :deny)

    assert {:ok, resolved} = Transform.resolve(plan([crop, auto]), metadata(), [])

    assert [
             [
               %Crop{width: {:pixels, 100}, height: {:pixels, 200}},
               %Resize{
                 rule: %DimensionRule{mode: :fit, width: {:pixels, 100}, height: {:pixels, 50}}
               }
             ]
           ] = resolved.pipelines
  end

  test "crop region scales against dimensions produced by earlier operations" do
    assert {:ok, resize_size} = size(100, 50)
    assert {:ok, resize} = Operation.resize_fit(size: resize_size, enlargement: :deny)

    assert {:ok, crop} =
             Operation.crop_region({:ratio, 0, 1}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:ratio, 1, 2})

    assert {:ok, resolved} = Transform.resolve(plan([resize, crop]), metadata(), [])

    assert [
             [
               %Resize{rule: %DimensionRule{mode: :fit}},
               %Crop{
                 width: {:scale, 1, 2},
                 height: {:scale, 1, 2},
                 crop_from: %{left: {:scale, 0, 1}, top: {:scale, 0, 1}}
               }
             ]
           ] = resolved.pipelines
  end

  test "crop region lowering allows zero pixel coordinates" do
    assert {:ok, operation} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 150}, {:px, 100})

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [
             [
               %Crop{
                 width: {:pixels, 150},
                 height: {:pixels, 100},
                 crop_from: %{left: {:pixels, 0}, top: {:pixels, 0}}
               }
             ]
           ] = resolved.pipelines
  end

  test "canvas lowers to extend canvas without choosing resize scale" do
    assert {:ok, placement} = Gravity.anchor(:center, :center)
    assert {:ok, canvas_size} = size(320, 240)

    assert {:ok, operation} =
             Operation.canvas(
               size: canvas_size,
               placement: placement,
               background: :white,
               overflow: :reject
             )

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata(), [])

    assert [
             [
               %ExtendCanvas{
                 rule: {:dimensions, {:pixels, 320}, {:pixels, 240}},
                 gravity: {:anchor, :center, :center},
                 background: :white
               }
             ]
           ] = resolved.pipelines
  end

  test "orientation operations lower to existing orientation transforms" do
    assert {:ok, auto_orient} = Operation.auto_orient()
    assert {:ok, rotate} = Operation.rotate(90)
    assert {:ok, flip} = Operation.flip(:horizontal)

    assert {:ok, resolved} = Transform.resolve(plan([auto_orient, rotate, flip]), metadata(), [])

    assert [[%AutoOrient{}, %Rotate{angle: 90}, %Flip{axis: :horizontal}]] =
             resolved.pipelines
  end
end
