defmodule ImagePlug.Transform.MaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.Transform.Material

  test "contain operations emit canonical material" do
    assert Material.material(%Transform.Operation.Contain{
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto,
             constraint: :max,
             letterbox: false
           }) == [
             op: :contain,
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto,
             constraint: :max,
             letterbox: false
           ]
  end

  test "cover operations emit canonical material" do
    assert Material.material(%Transform.Operation.Cover{
             type: :dimensions,
             width: {:pixels, 300},
             height: {:pixels, 200},
             constraint: :none
           }) == [
             op: :cover,
             type: :dimensions,
             width: {:pixels, 300},
             height: {:pixels, 200},
             constraint: :none
           ]
  end

  test "crop operations emit canonical material" do
    assert Material.material(%Transform.Operation.Crop{
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :focus
           }) == [
             op: :crop,
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :focus
           ]
  end

  test "semantic crop operations emit request and orientation material" do
    assert Material.material(%Transform.Operation.Crop{
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :gravity,
             gravity: {:anchor, :left, :top},
             x_offset: 5.0,
             y_offset: -3.0,
             orientation: %ImagePlug.Plan.Orientation{
               auto_orient: true,
               rotate: 90,
               flip: :horizontal
             }
           }) == [
             op: :crop,
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :gravity,
             gravity: {:anchor, :left, :top},
             x_offset: 5.0,
             y_offset: -3.0,
             orientation: [
               auto_orient: true,
               rotate: 90,
               flip: :horizontal
             ]
           ]
  end

  test "result crop operations emit target rule material" do
    assert Material.material(%Transform.Operation.Crop{
             width: :auto,
             height: :auto,
             crop_from: :gravity,
             gravity: {:anchor, :right, :bottom},
             x_offset: 0.0,
             y_offset: 0.0,
             target_rule: %Transform.Geometry.DimensionRule{
               mode: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100}
             }
           }) == [
             op: :crop,
             width: :auto,
             height: :auto,
             crop_from: :gravity,
             gravity: {:anchor, :right, :bottom},
             x_offset: 0.0,
             y_offset: 0.0,
             orientation: [
               auto_orient: false,
               rotate: 0,
               flip: nil
             ],
             target_rule: [
               mode: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               min_width: nil,
               min_height: nil,
               zoom_x: 1.0,
               zoom_y: 1.0,
               dpr: 1.0,
               effective_dpr: :runtime_resolved,
               enlarge: false
             ]
           ]
  end

  test "orientation operations emit canonical material" do
    assert Material.material(%Transform.Operation.AutoOrient{}) == [
             op: :auto_orient
           ]

    assert Material.material(%Transform.Operation.Rotate{angle: 90}) == [
             op: :rotate,
             angle: 90
           ]

    assert Material.material(%Transform.Operation.Flip{axis: :horizontal}) == [
             op: :flip,
             axis: :horizontal
           ]
  end

  test "focus operations emit canonical material" do
    assert Material.material(%Transform.Operation.Focus{
             type: {:coordinate, {:percent, 25.0}, {:percent, 75.0}}
           }) == [
             op: :focus,
             type: {:coordinate, {:percent, 25.0}, {:percent, 75.0}}
           ]
  end

  test "scale operations emit canonical material" do
    assert Material.material(%Transform.Operation.Scale{
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto
           }) == [
             op: :scale,
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto
           ]
  end

  test "resize operations emit canonical rule material" do
    assert Material.material(%Transform.Operation.Resize{
             rule: %Transform.Geometry.DimensionRule{
               mode: :fit,
               width: {:pixels, 300},
               height: :auto,
               min_width: {:pixels, 100},
               min_height: nil,
               zoom_x: 2.0,
               zoom_y: 1.5,
               dpr: 2.0,
               enlarge: false
             }
           }) == [
             op: :resize,
             rule: [
               mode: :fit,
               width: {:pixels, 300},
               height: :auto,
               min_width: {:pixels, 100},
               min_height: nil,
               zoom_x: 2.0,
               zoom_y: 1.5,
               dpr: 2.0,
               effective_dpr: :runtime_resolved,
               enlarge: false
             ]
           ]
  end

  test "adaptive resize and extend canvas operations emit canonical material" do
    assert Material.material(%Transform.Operation.AdaptiveResize{
             rule: %Transform.Geometry.DimensionRule{
               mode: :auto,
               width: {:pixels, 300},
               height: {:pixels, 200}
             }
           })[:op] == :adaptive_resize

    assert Material.material(%Transform.Operation.ExtendCanvas{
             rule: {:aspect_ratio, {16, 9}},
             gravity: {:anchor, :left, :top},
             x_offset: 5.0,
             y_offset: -3.0,
             background: :white
           }) == [
             op: :extend_canvas,
             rule: {:aspect_ratio, {16, 9}},
             gravity: {:anchor, :left, :top},
             x_offset: 5.0,
             y_offset: -3.0,
             background: :white
           ]
  end

  test "output is not represented as transform material" do
    output_transform = Module.concat([ImagePlug, :Transform, :Output])

    refute Code.ensure_loaded?(output_transform)
  end
end
