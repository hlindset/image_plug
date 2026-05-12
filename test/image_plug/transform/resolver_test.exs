defmodule ImagePlug.Transform.ResolverTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AutoOrient
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

  defp metadata(orientation \\ :normal),
    do: %SourceMetadata{orientation: orientation, format: :jpeg}

  defp resolve(%Plan{} = plan, %SourceMetadata{} = metadata, {source_width, source_height}) do
    Transform.resolve(plan, metadata, source_width: source_width, source_height: source_height)
  end

  defp resolve(%Plan{} = plan, %SourceMetadata{} = metadata) do
    resolve(plan, metadata, {1600, 900})
  end

  test "resize auto derives cover for matching current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = metadata()

    assert {:ok, resolved} = resolve(plan([operation]), metadata)

    assert [
             [
               %Resize{rule: %DimensionRule{mode: :fill, enlarge: false}},
               %Crop{
                 target_rule: %DimensionRule{mode: :fill, enlarge: false},
                 crop_from: :gravity
               }
             ]
           ] = resolved.pipelines

    assert resolved.selections == []
    assert resolved.resolver_material == []
  end

  test "executable pipelines facade lowers semantic operations" do
    assert {:ok, operation} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)
    metadata = metadata()

    assert {:ok,
            [
              [
                %Resize{rule: %DimensionRule{mode: :fill, enlarge: false}},
                %Crop{
                  target_rule: %DimensionRule{mode: :fill, enlarge: false},
                  crop_from: :gravity
                }
              ]
            ]} =
             Transform.executable_pipelines(plan([operation]), metadata,
               source_width: 1600,
               source_height: 900
             )
  end

  test "resize auto derives fit for differing current and target orientation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(200, 300), enlargement: :deny)
    metadata = metadata()

    assert {:ok, resolved} = resolve(plan([operation]), metadata)
    assert [[%Resize{rule: %DimensionRule{mode: :fit, enlarge: false}}]] = resolved.pipelines
  end

  test "resize auto derives fit when target orientation is unknown" do
    assert {:ok, width} = Dimension.pixels(300)
    assert {:ok, height} = Dimension.auto()
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, operation} = Operation.resize_auto(size: size, enlargement: :deny)

    metadata = metadata()

    assert {:ok, resolved} = resolve(plan([operation]), metadata)
    assert [[%Resize{rule: %DimensionRule{mode: :fit}}]] = resolved.pipelines
  end

  for exif_orientation <- [6, 8] do
    test "auto orient swaps current dimensions before resize auto for EXIF #{exif_orientation}" do
      auto_orient = %AutoOrient{}
      assert {:ok, resize_auto} = Operation.resize_auto(size: size(200, 300), enlargement: :deny)

      metadata = metadata({:exif, unquote(exif_orientation)})

      assert {:ok, resolved} = resolve(plan([auto_orient, resize_auto]), metadata)

      assert [
               [
                 %ImagePlug.Transform.Operation.AutoOrient{},
                 %Resize{rule: %DimensionRule{mode: :fill}},
                 %Crop{target_rule: %DimensionRule{mode: :fill}}
               ]
             ] = resolved.pipelines
    end
  end

  test "auto orient keeps current dimensions for 180 degree EXIF orientation before resize auto" do
    auto_orient = %AutoOrient{}
    assert {:ok, resize_auto} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)

    metadata = metadata({:exif, 3})

    assert {:ok, resolved} = resolve(plan([auto_orient, resize_auto]), metadata)

    assert [
             [
               %ImagePlug.Transform.Operation.AutoOrient{},
               %Resize{rule: %DimensionRule{mode: :fill}},
               %Crop{target_rule: %DimensionRule{mode: :fill}}
             ]
           ] = resolved.pipelines
  end

  test "auto orient with unknown orientation makes resize auto choose conservative fit" do
    auto_orient = %AutoOrient{}
    assert {:ok, resize_auto} = Operation.resize_auto(size: size(300, 200), enlargement: :deny)

    metadata = metadata(:unknown)

    assert {:ok, resolved} = resolve(plan([auto_orient, resize_auto]), metadata)

    assert [
             [
               %ImagePlug.Transform.Operation.AutoOrient{},
               %Resize{rule: %DimensionRule{mode: :fit}}
             ]
           ] = resolved.pipelines
  end

  test "preserves pipeline and emitted operation order" do
    assert {:ok, first_resize} =
             Operation.resize_auto(size: size(100, 50), enlargement: :deny)

    assert {:ok, current_crop} =
             Operation.crop_region(
               {:ratio, 1, 10},
               {:ratio, 1, 10},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert {:ok, second_resize} =
             Operation.resize_auto(size: size(30, 20), enlargement: :deny)

    metadata = metadata()

    plan =
      plan_with_pipelines([
        %Pipeline{operations: [first_resize, current_crop]},
        %Pipeline{operations: [second_resize]}
      ])

    assert {:ok, resolved} = resolve(plan, metadata, {300, 200})

    assert [
             [
               %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}}},
               %Crop{target_rule: %DimensionRule{mode: :fill}},
               %Crop{
                 width: {:scale, 1, 2},
                 height: {:scale, 1, 2},
                 crop_from: %{left: {:scale, 1, 10}, top: {:scale, 1, 10}}
               }
             ],
             [
               %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 30}}},
               %Crop{target_rule: %DimensionRule{mode: :fill}}
             ]
           ] = resolved.pipelines
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

      assert {:ok, operation} =
               Operation.resize_auto(size: size(target_width, target_height), enlargement: :deny)

      metadata = metadata()

      assert {:ok, resolved} =
               resolve(plan([operation]), metadata, {source_width, source_height})

      expected_mode = unquote(if expected == :cover, do: :fill, else: :fit)

      assert [[%Resize{rule: %DimensionRule{mode: ^expected_mode}} | _rest]] = resolved.pipelines
    end
  end

  test "source metadata constructor validates source-only facts" do
    assert {:ok, %SourceMetadata{format: :jpeg, orientation: :normal}} =
             SourceMetadata.new(format: :jpeg)

    assert SourceMetadata.new(width: 300, height: 200, format: :jpeg) ==
             {:error, {:unknown_source_metadata_options, [:width, :height]}}

    assert SourceMetadata.new(orientation: {:exif, 9}) ==
             {:error, {:invalid_source_metadata, {:orientation, {:exif, 9}}}}

    assert SourceMetadata.new(source: :origin) ==
             {:error, {:unknown_source_metadata_options, [:source]}}
  end
end
