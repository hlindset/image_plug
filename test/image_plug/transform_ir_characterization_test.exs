defmodule ImagePlug.TransformIRCharacterizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.AdaptiveResize
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  defmodule CacheHitProbe do
    def get(key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def put(_key, _entry, _opts), do: raise("cache hit must not write")
  end

  defmodule GeneratedOrigin do
    def call(%Plug.Conn{request_path: "/" <> basename} = conn, _opts) do
      {width, height} = dimensions_from_basename(basename)
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    defp dimensions_from_basename(basename) do
      basename
      |> Path.basename()
      |> Path.rootname()
      |> String.split("x", parts: 2)
      |> case do
        [width, height] -> {String.to_integer(width), String.to_integer(height)}
      end
    end
  end

  defmodule OriginShouldNotFetch do
    def call(_conn, _opts), do: raise("origin should not fetch on cache hit")
  end

  defp parse_plan!(path) do
    conn = conn(:get, path)
    assert {:ok, plan} = Imgproxy.parse(conn, [])
    {conn, plan}
  end

  defp final_dimensions_for_auto_resize(source, target) do
    {target_width, target_height} = target
    source_basename = source_basename(source)

    path =
      "/_/rt:auto/w:#{target_width}/h:#{target_height}/f:jpeg/plain/generated/#{source_basename}"

    {conn, plan} = parse_plan!(path)

    assert {:ok, {:image, %State{image: image}, _resolved_output, _response}} =
             RequestRunner.run(
               conn,
               plan,
               "http://origin.test/#{source_basename}",
               origin_req_options: [plug: GeneratedOrigin]
             )

    {Image.width(image), Image.height(image)}
  end

  defp source_basename({width, height}), do: "#{width}x#{height}.png"

  defp generated_state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp execute_dimensions(operations, source \\ {300, 200}) do
    {width, height} = source

    assert {:ok, %State{image: image}} =
             generated_state(width, height)
             |> Chain.execute(operations)

    {Image.width(image), Image.height(image)}
  end

  defp resolve_dimensions(semantic_operations, source \\ {300, 200}) do
    {width, height} = source

    plan = %ImagePlug.Plan{
      source: %ImagePlug.Plan.Source.Plain{path: ["generated", source_basename(source)]},
      pipelines: [%ImagePlug.Plan.Pipeline{operations: semantic_operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }

    metadata = %SourceMetadata{width: width, height: height, orientation: :normal, format: :jpeg}
    assert {:ok, resolved} = Transform.resolve(plan, metadata, [])

    resolved.pipelines
    |> List.flatten()
    |> execute_dimensions(source)
  end

  defp size(width, height) do
    assert {:ok, width} = semantic_dimension(width)
    assert {:ok, height} = semantic_dimension(height)
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end

  defp semantic_dimension(:auto), do: Dimension.auto()
  defp semantic_dimension(pixels), do: Dimension.pixels(pixels)

  defp center_gravity do
    assert {:ok, gravity} = Gravity.anchor(:center, :center)
    gravity
  end

  test "cache hit returns before origin fetch for auto resize requests" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    path = "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"
    {conn, plan} = parse_plan!(path)

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn,
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHitProbe, entry: entry, test_pid: self()},
               origin_req_options: [plug: OriginShouldNotFetch]
             )

    assert_received {:cache_get, key}
    assert key.material[:origin_identity] == "http://origin.test/images/cat-300.jpg"
  end

  test "parser/request-level resize:auto preserves visible current dimensions" do
    # Current request-visible behavior resolves ResizeAuto through fill plus a
    # result Crop for matching landscape orientation. Executable AdaptiveResize
    # alone produces {100, 67} for 300x200 -> 100x50, while the request path
    # below produces the final visible {100, 50}.
    cases = [
      %{source: {300, 200}, target: {100, 50}, expected: {100, 50}},
      %{source: {300, 200}, target: {50, 100}, expected: {50, 33}},
      %{source: {100, 100}, target: {50, 50}, expected: {50, 50}},
      %{source: {100, 100}, target: {50, 80}, expected: {50, 50}}
    ]

    for %{source: source, target: target, expected: expected} <- cases do
      assert final_dimensions_for_auto_resize(source, target) == expected
    end
  end

  test "parsed imgproxy plans contain only semantic plan operations" do
    {_conn, plan} =
      parse_plan!(
        "/_/ar/rot:90/fl:true:false/rt:auto/w:100/h:50/c:50:50/f:jpeg/plain/images/cat.jpg"
      )

    operations = plan.pipelines |> Enum.flat_map(& &1.operations)

    refute Enum.any?(operations, &transform_operation?/1)
    assert Enum.all?(operations, &Operation.semantic?/1)
  end

  test "semantic lowering preserves current executable dimensions for first-slice examples" do
    assert {:ok, fit} = Operation.resize_fit(size: size(300, 200), enlargement: :deny)

    fill_rule = %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}

    assert {:ok, cover} =
             Operation.resize_cover(
               size: size(100, 100),
               enlargement: :deny,
               guide: center_gravity()
             )

    auto_rule = %DimensionRule{mode: :auto, width: {:pixels, 100}, height: {:pixels, 50}}
    assert {:ok, auto} = Operation.resize_auto(size: size(100, 50), enlargement: :deny)

    assert {:ok, stretch} = Operation.resize_stretch(size: size(:auto, 100), enlargement: :deny)
    assert {:ok, crop} = Operation.crop_guided(size: size(50, 50), guide: center_gravity())

    assert {:ok, canvas_width} = Dimension.pixels(320)
    assert {:ok, canvas_height} = Dimension.pixels(240)
    assert {:ok, canvas_size} = Size.new(width: canvas_width, height: canvas_height, dpr: 1.0)

    assert {:ok, canvas} =
             Operation.canvas(
               size: canvas_size,
               placement: center_gravity(),
               background: :white,
               overflow: :reject
             )

    cases = [
      %{
        name: :fit_300x200,
        old: [
          %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}}
        ],
        semantic: [fit]
      },
      %{
        name: :fill_100x100_center,
        old: [
          %Resize{rule: fill_rule},
          %Crop{
            width: :auto,
            height: :auto,
            crop_from: :gravity,
            gravity: {:anchor, :center, :center},
            target_rule: fill_rule
          }
        ],
        semantic: [cover]
      },
      %{
        name: :auto_landscape_target,
        old: [
          %AdaptiveResize{rule: auto_rule},
          %Crop{
            width: :auto,
            height: :auto,
            crop_from: :gravity,
            gravity: {:anchor, :center, :center},
            x_offset: {:pixels, 0},
            y_offset: {:pixels, 0},
            target_rule: %DimensionRule{auto_rule | mode: :fill}
          }
        ],
        semantic: [auto]
      },
      %{
        name: :force_width_auto,
        old: [%Resize{rule: %DimensionRule{mode: :force, width: :auto, height: {:pixels, 100}}}],
        semantic: [stretch]
      },
      %{
        name: :explicit_crop_center,
        old: [
          %Crop{
            width: {:pixels, 50},
            height: {:pixels, 50},
            crop_from: :gravity,
            gravity: {:anchor, :center, :center}
          }
        ],
        semantic: [crop]
      },
      %{
        name: :canvas_extend_to_320x240,
        old: [
          %ExtendCanvas{
            rule: {:dimensions, {:pixels, 320}, {:pixels, 240}},
            gravity: {:anchor, :center, :center},
            x_offset: 0.0,
            y_offset: 0.0,
            background: :white
          }
        ],
        semantic: [canvas]
      }
    ]

    for %{name: name, old: old, semantic: semantic} <- cases do
      assert execute_dimensions(old) == resolve_dimensions(semantic),
             "dimension mismatch for #{name}"
    end
  end

  defp transform_operation?(%module{}) do
    module
    |> Module.split()
    |> Enum.take(4)
    |> Kernel.==(["ImagePlug", "Transform", "Operation"])
  end

  defp transform_operation?(_operation), do: false
end
