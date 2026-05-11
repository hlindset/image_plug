defmodule ImagePlug.Transform.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
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
    plan_with_pipelines([%Pipeline{operations: operations}])
  end

  defp plan_with_pipelines(pipelines) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: pipelines,
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end

  defp current_ratio_region do
    assert {:ok, x} = Dimension.ratio(1, 10)
    assert {:ok, y} = Dimension.ratio(1, 10)
    assert {:ok, width} = Dimension.ratio(1, 2)
    assert {:ok, height} = Dimension.ratio(1, 2)

    assert {:ok, region} =
             Region.new(x: x, y: y, width: width, height: height, space: :current)

    region
  end

  defp source_ratio_region do
    assert {:ok, x} = Dimension.ratio(1, 10)
    assert {:ok, y} = Dimension.ratio(1, 10)
    assert {:ok, width} = Dimension.ratio(1, 2)
    assert {:ok, height} = Dimension.ratio(1, 2)

    assert {:ok, region} =
             Region.new(x: x, y: y, width: width, height: height, space: :source)

    region
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

  test "executable pipelines facade lowers semantic operations" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert {:ok,
            [
              [
                %Resize{rule: %DimensionRule{mode: :fill, enlarge: false}},
                %Crop{
                  target_rule: %DimensionRule{mode: :fill, enlarge: false},
                  crop_from: :gravity
                }
              ]
            ]} = Transform.executable_pipelines(plan([operation]), metadata, [])
  end

  test "backend profile material follows resolver options" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    backend_profile = %BackendProfile{BackendProfile.default() | material_version: 2}

    assert {:ok, resolved} =
             Transform.resolve(plan([operation]), metadata, backend_profile: backend_profile)

    assert resolved.backend_profile_material == BackendProfile.material(backend_profile)
  end

  test "invalid backend profile material returns a tagged resolver error" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :normal, format: :jpeg}

    assert Transform.resolve(plan([operation]), metadata, backend_profile: :not_a_profile) ==
             {:error, {:invalid_backend_profile, :not_a_profile}}
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

  for exif_orientation <- [6, 8] do
    test "auto orient swaps current dimensions before resize auto for EXIF #{exif_orientation}" do
      assert {:ok, auto_orient} = Operation.auto_orient()
      assert {:ok, resize_auto} = Operation.resize_auto(size: size(200, 300), enlargement: :deny)

      metadata = %SourceMetadata{
        width: 1600,
        height: 900,
        orientation: {:exif, unquote(exif_orientation)},
        format: :jpeg
      }

      assert {:ok, resolved} = Transform.resolve(plan([auto_orient, resize_auto]), metadata, [])

      assert [
               [
                 %ImagePlug.Transform.Operation.AutoOrient{},
                 %Resize{rule: %DimensionRule{mode: :fill}},
                 %Crop{target_rule: %DimensionRule{mode: :fill}}
               ]
             ] = resolved.pipelines

      assert [%{code: :resize_auto_branch, value: :cover, operation_index: 1}] =
               resolved.derivations
    end
  end

  test "auto orient keeps current dimensions for 180 degree EXIF orientation before resize auto" do
    assert {:ok, auto_orient} = Operation.auto_orient()
    assert {:ok, resize_auto} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)

    metadata = %SourceMetadata{width: 1600, height: 900, orientation: {:exif, 3}, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([auto_orient, resize_auto]), metadata, [])

    assert [%{code: :resize_auto_branch, value: :cover, operation_index: 1}] =
             resolved.derivations
  end

  test "auto orient with unknown orientation makes resize auto choose conservative fit" do
    assert {:ok, auto_orient} = Operation.auto_orient()
    assert {:ok, resize_auto} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)

    metadata = %SourceMetadata{width: 1600, height: 900, orientation: :unknown, format: :jpeg}

    assert {:ok, resolved} = Transform.resolve(plan([auto_orient, resize_auto]), metadata, [])

    assert [
             [
               %ImagePlug.Transform.Operation.AutoOrient{},
               %Resize{rule: %DimensionRule{mode: :fit}}
             ]
           ] = resolved.pipelines

    assert [%{code: :resize_auto_branch, value: :fit, operation_index: 1}] =
             resolved.derivations
  end

  test "auto orient keeps source alignment invalidated for later source-space crops" do
    assert {:ok, auto_orient} = Operation.auto_orient()
    assert {:ok, crop} = Operation.crop_region(region: source_ratio_region())

    metadata = %SourceMetadata{width: 1600, height: 900, orientation: {:exif, 6}, format: :jpeg}

    assert Transform.resolve(plan([auto_orient, crop]), metadata, []) ==
             {:error, {:invalid_pipeline_operation, crop}}
  end

  test "preserves pipeline, emitted operation, and derivation order" do
    assert {:ok, first_resize} =
             Operation.resize_auto(size: size(100, 50), enlargement: :deny)

    assert {:ok, current_crop} = Operation.crop_region(region: current_ratio_region())

    assert {:ok, second_resize} =
             Operation.resize_auto(size: size(30, 20), enlargement: :deny)

    metadata = %SourceMetadata{width: 300, height: 200, orientation: :normal, format: :jpeg}

    plan =
      plan_with_pipelines([
        %Pipeline{operations: [first_resize, current_crop]},
        %Pipeline{operations: [second_resize]}
      ])

    assert {:ok, resolved} = Transform.resolve(plan, metadata, [])

    assert [
             [
               %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}}},
               %Crop{target_rule: %DimensionRule{mode: :fill}},
               %Crop{width: {:pixels, 50}, height: {:pixels, 25}}
             ],
             [
               %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 30}}},
               %Crop{target_rule: %DimensionRule{mode: :fill}}
             ]
           ] = resolved.pipelines

    assert [
             %{code: :resize_auto_branch, pipeline_index: 0, operation_index: 0},
             %{code: :crop_region_resolved, pipeline_index: 0, operation_index: 1},
             %{code: :resize_auto_branch, pipeline_index: 1, operation_index: 0}
           ] = resolved.derivations
  end

  for {source, target, expected} <- [
        {{1600, 900}, {300, 200}, :cover},
        {{1600, 900}, {200, 300}, :fit},
        {{1000, 1000}, {300, 300}, :cover},
        {{1000, 1000}, {300, 200}, :fit}
      ] do
    test "resize auto #{inspect(source)} to #{inspect(target)} derives #{expected}" do
      {source_width, source_height} = unquote(Macro.escape(source))
      {target_width, target_height} = unquote(Macro.escape(target))
      expected = unquote(expected)

      assert {:ok, operation} =
               Operation.resize_auto(size: size(target_width, target_height), enlargement: :deny)

      metadata = %SourceMetadata{
        width: source_width,
        height: source_height,
        orientation: :normal,
        format: :jpeg
      }

      assert {:ok, resolved} = Transform.resolve(plan([operation]), metadata, [])

      assert [%{code: :resize_auto_branch, value: ^expected, material?: false}] =
               resolved.derivations

      expected_mode = unquote(if expected == :cover, do: :fill, else: :fit)

      assert [[%Resize{rule: %DimensionRule{mode: ^expected_mode}} | _rest]] = resolved.pipelines
    end
  end

  test "source metadata constructor validates required resolver inputs" do
    assert {:ok, %SourceMetadata{width: 300, height: 200}} =
             SourceMetadata.new(width: 300, height: 200, format: :jpeg)

    assert SourceMetadata.new(width: 0, height: 200) ==
             {:error, {:invalid_source_metadata, {:width, 0}}}

    assert SourceMetadata.new(width: 300, height: 200, orientation: {:exif, 9}) ==
             {:error, {:invalid_source_metadata, {:orientation, {:exif, 9}}}}

    assert SourceMetadata.new(width: 300, height: 200, source: :origin) ==
             {:error, {:unknown_source_metadata_options, [:source]}}
  end
end
