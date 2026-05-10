defmodule ImagePlug.Transform.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.BackendProfile
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.SourceMetadata

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end

  test "resize auto derives cover for matching current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])

    assert [
             [
               %Resize{rule: %DimensionRule{mode: :fill, enlarge: false}},
               %Crop{
                 target_rule: %DimensionRule{mode: :fill, enlarge: false},
                 crop_from: :gravity
               }
             ]
           ] = resolved.pipelines

    assert [%{code: :resize_auto_branch, value: :cover, material?: false}] =
             resolved.derivations

    assert resolved.selections == []
    assert resolved.resolver_material == []
    assert resolved.backend_profile_material == BackendProfile.material(BackendProfile.default())
  end

  test "resize auto derives fit for differing current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(200, 300), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])
    assert [[%Resize{rule: %DimensionRule{mode: :fit, enlarge: false}}]] = resolved.pipelines

    assert [%{code: :resize_auto_branch, value: :fit, material?: false}] =
             resolved.derivations
  end

  test "resize auto derives fit when target orientation is unknown" do
    assert {:ok, width} = Dimension.pixels(300)
    assert {:ok, height} = Dimension.auto()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, operation} = Operation.resize_auto(size: size, enlargement: :deny)

    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])
    assert [[%Resize{rule: %DimensionRule{mode: :fit}}]] = resolved.pipelines
  end

  test "source metadata constructor validates required resolver inputs" do
    assert {:ok, %SourceMetadata{width: 300, height: 200}} =
             SourceMetadata.new(width: 300, height: 200, format: :jpeg)

    assert SourceMetadata.new(width: 0, height: 200) ==
             {:error, {:invalid_source_metadata, {:width, 0}}}

    assert SourceMetadata.new(width: 300, height: 200, orientation: {:exif, 9}) ==
             {:error, {:invalid_source_metadata, {:orientation, {:exif, 9}}}}
  end
end
