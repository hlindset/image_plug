defmodule ImagePlug.Parser.Native.PlanBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Native
  alias ImagePlug.Parser.Native.ParsedRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.PlanBuilder
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  test "converts one native pipeline request into a product-neutral plan" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: %ImagePlug.Parser.Native.OutputRequest{}
    }

    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [
                %Pipeline{operations: operations}
              ],
              output: %Output{mode: :automatic}
            }} = PlanBuilder.to_plan(request, [])

    assert [%Transform.Resize{} = params] = operations
    assert params.rule.width == {:pixels, 300}
  end

  test "plans fit requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: false)

    assert [
             %Transform.Resize{
               rule: %Transform.Geometry.DimensionRule{
                 mode: :fit,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: false
               }
             }
           ] = operations

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: true)

    assert [
             %Transform.Resize{
               rule: %Transform.Geometry.DimensionRule{
                 mode: :fit,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true
               }
             }
           ] = operations
  end

  test "plans fill requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: false
             )

    assert [
             %Transform.Resize{
               rule: %Transform.Geometry.DimensionRule{
                 mode: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: false
               }
             },
             %Transform.Crop{
               crop_from: :gravity,
               gravity: {:anchor, :center, :center},
               target_rule: %Transform.Geometry.DimensionRule{
                 mode: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: false
               }
             }
           ] = operations

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: true
             )

    assert [
             %Transform.Resize{
               rule: %Transform.Geometry.DimensionRule{
                 mode: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true
               }
             },
             %Transform.Crop{
               crop_from: :gravity,
               gravity: {:anchor, :center, :center},
               target_rule: %Transform.Geometry.DimensionRule{
                 mode: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true
               }
             }
           ] = operations
  end

  test "plans gravity-bearing fill, fill-down, and auto with result crop operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :left, :top}
             )

    assert [%Transform.Resize{}, %Transform.Crop{} = crop] = operations
    assert crop.crop_from == :gravity
    assert crop.gravity == {:anchor, :left, :top}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:fp, 0.25, 0.75}
             )

    assert [%Transform.Resize{}, %Transform.Crop{} = crop] = operations
    assert %Transform.Crop{gravity: {:fp, 0.25, 0.75}} = crop

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :auto,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom}
             )

    assert [%Transform.AdaptiveResize{}, %Transform.Crop{} = crop] = operations
    assert crop.gravity == {:anchor, :right, :bottom}
  end

  test "preserves zero fit and fill dimensions as no geometry when both dimensions are auto" do
    for resizing_type <- [:fit, :fill] do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
               plan_pipeline(
                 resizing_type: resizing_type,
                 width: {:pixels, 0},
                 height: {:pixels, 0}
               )
    end
  end

  test "plans zero dimensions with meaningful min resize rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Resize{} = resize]}]}} =
             plan_pipeline(
               width: {:pixels, 0},
               height: {:pixels, 0},
               min_width: {:pixels, 300}
             )

    assert resize.rule.width == :auto
    assert resize.rule.height == :auto
    assert resize.rule.min_width == {:pixels, 300}
  end

  test "normalizes single zero fit dimensions to auto resize dimensions" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 0}, height: {:pixels, 200})

    assert [
             %Transform.Resize{
               rule: %Transform.Geometry.DimensionRule{
                 mode: :fit,
                 width: :auto,
                 height: {:pixels, 200}
               }
             }
           ] = operations
  end

  test "plans force requests with one zero dimension as source-preserving auto dimensions" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Resize{} = resize]}]}} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200})

    assert resize.rule.mode == :force
    assert resize.rule.width == :auto
    assert resize.rule.height == {:pixels, 200}
    assert %Transform.Resize{rule: %{mode: :force, width: :auto, height: {:pixels, 200}}} = resize

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Resize{} = resize]}]}} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0})

    assert resize.rule.mode == :force
    assert resize.rule.width == {:pixels, 300}
    assert resize.rule.height == :auto
  end

  test "plans fit, fill-down, force, and auto as product-neutral resize operations" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.Resize{} = resize]}]}} =
             plan_pipeline(resizing_type: :fit, width: {:pixels, 100}, height: {:pixels, 0})

    assert resize.rule.mode == :fit

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%ImagePlug.Transform.Resize{} = down, %Transform.Crop{}]}
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100}
             )

    assert down.rule.mode == :fill_down

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%ImagePlug.Transform.AdaptiveResize{}, %Transform.Crop{}]}
              ]
            }} =
             plan_pipeline(resizing_type: :auto, width: {:pixels, 100}, height: {:pixels, 100})
  end

  test "plans extend and extend aspect ratio as neutral canvas operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 100}, height: {:pixels, 100}, extend: true)

    assert Enum.any?(operations, &match?(%ImagePlug.Transform.ExtendCanvas{}, &1))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(extend_aspect_ratio: {16, 9})

    assert Enum.any?(operations, &match?(%ImagePlug.Transform.ExtendCanvas{}, &1))
  end

  test "plans extend gravity and offsets as neutral canvas operation fields" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: true,
               extend_gravity: {:anchor, :left, :top},
               extend_x_offset: 5.0,
               extend_y_offset: -3.0
             )

    assert %Transform.ExtendCanvas{
             gravity: {:anchor, :left, :top},
             x_offset: 5.0,
             y_offset: -3.0
           } = List.last(operations)
  end

  test "explicit false extend prevents parsed extend tails from planning canvas operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: false,
               extend_requested: true,
               extend_gravity: {:anchor, :center, :center},
               extend_x_offset: 5.0,
               extend_y_offset: -3.0
             )

    refute Enum.any?(operations, &match?(%Transform.ExtendCanvas{}, &1))
  end

  test "plans top-level gravity offsets into result crop operations" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Transform.Resize{}, %Transform.Crop{} = crop]}]
            }} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 12.0},
               gravity_y_offset: {:scale, -0.25}
             )

    assert crop.gravity == {:anchor, :right, :bottom}
    assert crop.x_offset == {:pixels, -12.0}
    assert crop.y_offset == {:scale, 0.25}
    assert %Transform.Crop{x_offset: {:pixels, -12.0}, y_offset: {:scale, 0.25}} = crop
  end

  test "scales absolute top-level gravity offsets by dpr" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Transform.Resize{}, %Transform.Crop{} = crop]}]
            }} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               dpr: 2.0,
               gravity: {:anchor, :right, :center},
               gravity_x_offset: {:pixels, 12.0},
               gravity_y_offset: {:scale, -0.25}
             )

    assert crop.x_offset == {:pixels, -12.0}
    assert crop.y_offset == {:scale, -0.25}
  end

  test "parsed crop gravity is independent from top-level gravity" do
    assert {:ok, pipeline} = parsed_pipeline("/_/g:so/c:0.5:0.25:nowe/plain/images/cat.jpg")

    assert pipeline.gravity == {:anchor, :center, :bottom}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
  end

  test "crop without explicit gravity inherits top-level gravity" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Crop{} = crop]}]}} =
             plan_pipeline(
               gravity: {:anchor, :left, :top},
               crop: %ImagePlug.Parser.Native.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: nil
               }
             )

    assert crop.gravity == {:anchor, :left, :top}
  end

  test "plans crop focal-point gravity and relative offsets" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Crop{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePlug.Parser.Native.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:fp, 0.25, 0.75},
                 x_offset: {:scale, 0.25},
                 y_offset: {:pixels, -12.0}
               }
             )

    assert crop.gravity == {:fp, 0.25, 0.75}
    assert crop.x_offset == {:scale, 0.25}
    assert crop.y_offset == {:pixels, -12.0}
  end

  test "parsed rotate normalizes integer multiples of 90" do
    for {value, expected} <- [
          {-450, 270},
          {-90, 270},
          {0, 0},
          {90, 90},
          {360, 0},
          {450, 90}
        ] do
      assert {:ok, pipeline} = parsed_pipeline("/_/rot:#{value}/plain/images/cat.jpg")
      assert pipeline.orientation.rotate == expected
    end
  end

  test "parsed flip booleans normalize to explicit orientation intent" do
    assert {:ok, pipeline} = parsed_pipeline("/_/flip:true:false/plain/images/cat.jpg")
    assert pipeline.orientation.flip == :horizontal

    assert {:ok, pipeline} = parsed_pipeline("/_/fl:false:true/plain/images/cat.jpg")
    assert pipeline.orientation.flip == :vertical

    assert {:ok, pipeline} = parsed_pipeline("/_/fl:true:true/plain/images/cat.jpg")
    assert pipeline.orientation.flip == :both

    assert {:ok, pipeline} = parsed_pipeline("/_/fl:false:false/plain/images/cat.jpg")
    assert pipeline.orientation.flip == nil
  end

  test "planner emits fixed orientation crop resize order independent of URL order" do
    one =
      plan_pipeline(
        crop: %ImagePlug.Parser.Native.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 100}
        },
        rotate: 90,
        width: {:pixels, 200}
      )

    two =
      plan_pipeline(
        width: {:pixels, 200},
        rotate: 90,
        crop: %ImagePlug.Parser.Native.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 100}
        }
      )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: one_ops}]}} = one
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: two_ops}]}} = two

    assert Enum.map(one_ops, &ImagePlug.Transform.transform_name/1) ==
             Enum.map(two_ops, &ImagePlug.Transform.transform_name/1)

    assert Enum.map(one_ops, &ImagePlug.Transform.transform_name/1) == [:rotate, :crop, :resize]

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               auto_orient: true,
               rotate: 90,
               flip: :horizontal,
               crop: %ImagePlug.Parser.Native.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100}
               },
               width: {:pixels, 200}
             )

    assert Enum.map(operations, &ImagePlug.Transform.transform_name/1) == [
             :auto_orient,
             :rotate,
             :flip,
             :crop,
             :resize
           ]
  end

  test "planner emits fixed fill result crop before canvas extension" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom},
               extend: true
             )

    assert Enum.map(operations, &ImagePlug.Transform.transform_name/1) == [
             :resize,
             :crop,
             :extend_canvas
           ]
  end

  test "parsed zoom supports one shared factor or independent axes" do
    assert {:ok, pipeline} = parsed_pipeline("/_/zoom:2/plain/images/cat.jpg")
    assert pipeline.zoom_x == 2.0
    assert pipeline.zoom_y == 2.0

    assert {:ok, pipeline} = parsed_pipeline("/_/z:2:3/plain/images/cat.jpg")
    assert pipeline.zoom_x == 2.0
    assert pipeline.zoom_y == 3.0
  end

  test "dropped imgproxy options remain parser errors" do
    for segment <-
          ~w(raw max_bytes mb max_src_resolution msr max_src_file_size msfs crop_aspect_ratio crop_ar car) do
      assert {:error, _reason} =
               Native.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
    end
  end

  test "dropped imgproxy options with values remain parser errors" do
    for segment <- ~w(raw:false max_bytes:100 mb:100 crop_ar:1:1) do
      assert {:error, _reason} =
               Native.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
    end
  end

  test "rejects invalid arity for new pipeline options" do
    invalid_segments = [
      "zoom",
      "zoom:",
      "zoom:1:2:3",
      "z",
      "z:",
      "z:1:2:3",
      "dpr",
      "dpr:",
      "dpr:1:2",
      "min-width",
      "min-width:1:2",
      "mw",
      "mw:1:2",
      "min_width",
      "min_width:1:2",
      "min-height",
      "min-height:1:2",
      "mh",
      "mh:1:2",
      "min_height",
      "min_height:1:2",
      "enlarge",
      "enlarge:true:false",
      "el",
      "el:true:false",
      "extend",
      "extend:",
      "extend:true:ce:0",
      "extend:true:ce:0:0:extra",
      "ex",
      "ex:",
      "ex:true:ce:0",
      "ex:true:ce:0:0:extra",
      "gravity",
      "gravity:ce:0",
      "gravity:ce:0:0:extra",
      "g",
      "g:ce:0",
      "g:ce:0:0:extra",
      "auto_rotate:",
      "auto_rotate:true:false",
      "ar:",
      "ar:true:false",
      "rotate",
      "rotate:",
      "rotate:90:180",
      "rot",
      "rot:",
      "rot:90:180",
      "flip:true:false:true",
      "fl:true:false:true",
      "extend_aspect_ratio",
      "extend_aspect_ratio:16",
      "extend_aspect_ratio:16:9:1",
      "extend_ar",
      "extend_ar:16",
      "extend_ar:16:9:1",
      "exar",
      "exar:16",
      "exar:16:9:1",
      "crop",
      "crop:100",
      "crop:100:200:ce:0",
      "crop:100:200:ce:0:0:extra",
      "c",
      "c:100",
      "c:100:200:ce:0",
      "c:100:200:ce:0:0:extra"
    ]

    for segment <- invalid_segments do
      assert Native.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "plans neutral resize rule inputs before no-op operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Resize{} = resize]}]}} =
             plan_pipeline(
               min_width: {:pixels, 100},
               min_height: {:pixels, 80},
               zoom_x: 2.0,
               zoom_y: 2.0,
               dpr: 2.0
             )

    assert resize.rule.min_width == {:pixels, 100}
    assert resize.rule.min_height == {:pixels, 80}
    assert resize.rule.zoom_x == 2.0
    assert resize.rule.zoom_y == 2.0
    assert resize.rule.dpr == 2.0
  end

  test "plans parsed crop and orientation semantics before no-op operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.Crop{}]}]}} =
             plan_pipeline(crop: struct(ImagePlug.Parser.Native.CropRequest))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Transform.AutoOrient{}]}]}} =
             plan_pipeline(orientation: struct(ImagePlug.Plan.Orientation, auto_orient: true))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(orientation_requested: true)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               crop: struct(ImagePlug.Parser.Native.CropRequest),
               orientation: struct(ImagePlug.Plan.Orientation, auto_orient: true)
             )

    assert Enum.map(operations, &ImagePlug.Transform.transform_name/1) == [:auto_orient, :crop]
  end

  test "rejects invalid direct pipeline request values" do
    assert plan_pipeline(resizing_type: :bogus) ==
             {:error, {:invalid_resizing_type, :bogus}}

    assert plan_pipeline(enlarge: :bogus) == {:error, {:invalid_enlarge, :bogus}}

    assert plan_pipeline(
             resizing_type: :fill,
             width: {:pixels, 300},
             height: {:pixels, 200},
             gravity: :bogus
           ) == {:error, {:invalid_gravity, :bogus}}

    assert plan_pipeline(width: {:pixels, -1}) ==
             {:error, {:invalid_dimension, :width, {:pixels, -1}}}

    assert plan_pipeline(height: {:percent, 50}) ==
             {:error, {:invalid_dimension, :height, {:percent, 50}}}
  end

  test "converts multiple native pipeline requests into separate product-neutral pipelines" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [
        %PipelineRequest{width: {:pixels, 500}},
        %PipelineRequest{height: {:pixels, 200}}
      ],
      output: %ImagePlug.Parser.Native.OutputRequest{}
    }

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = PlanBuilder.to_plan(request, [])

    assert [%Transform.Resize{} = first_params] = first_operations
    assert first_params.rule.width == {:pixels, 500}
    assert first_params.rule.height == :auto

    assert [%Transform.Resize{} = second_params] = second_operations
    assert second_params.rule.width == :auto
    assert second_params.rule.height == {:pixels, 200}
  end

  test "represents output intent outside native pipeline operations" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [
        %PipelineRequest{
          resizing_type: :force,
          width: {:pixels, 300},
          height: {:pixels, 200}
        }
      ],
      output: %ImagePlug.Parser.Native.OutputRequest{format: :webp}
    }

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Plan.Pipeline{operations: operations}],
              output: %ImagePlug.Plan.Output{mode: :automatic}
            }} =
             PlanBuilder.to_plan(
               %ParsedRequest{request | output: %ImagePlug.Parser.Native.OutputRequest{}},
               []
             )

    assert [%Transform.Resize{} = automatic_params] = operations
    assert automatic_params.rule.width == {:pixels, 300}
    assert automatic_params.rule.height == {:pixels, 200}

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Plan.Pipeline{operations: operations}],
              output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}}
            }} =
             PlanBuilder.to_plan(request, [])

    assert [%Transform.Resize{} = explicit_params] = operations
    assert explicit_params.rule.width == {:pixels, 300}
    assert explicit_params.rule.height == {:pixels, 200}
  end

  property "output format does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePlug.Plan{} = automatic_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{
                   parsed_request
                   | output: %ImagePlug.Parser.Native.OutputRequest{}
                 },
                 []
               )

      assert automatic_plan.output == %ImagePlug.Plan.Output{mode: :automatic}
      assert [%ImagePlug.Plan.Pipeline{} | _] = automatic_plan.pipelines

      for format <- [:webp, :avif, :jpeg, :png] do
        assert {:ok, %ImagePlug.Plan{} = explicit_plan} =
                 PlanBuilder.to_plan(
                   %ParsedRequest{
                     parsed_request
                     | output: %ImagePlug.Parser.Native.OutputRequest{format: format}
                   },
                   []
                 )

        assert explicit_plan.output == %ImagePlug.Plan.Output{mode: {:explicit, format}}
        assert explicit_plan.pipelines == automatic_plan.pipelines
      end
    end
  end

  property "output quality does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePlug.Plan{} = default_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{
                   parsed_request
                   | output: %ImagePlug.Parser.Native.OutputRequest{}
                 },
                 []
               )

      quality_request = %ImagePlug.Parser.Native.OutputRequest{
        quality: {:quality, 80},
        format_qualities: %{webp: {:quality, 70}}
      }

      assert {:ok,
              %ImagePlug.Plan{
                output: %ImagePlug.Plan.Output{
                  mode: :automatic,
                  quality: {:quality, 80},
                  format_qualities: %{webp: {:quality, 70}}
                }
              } = quality_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{parsed_request | output: quality_request},
                 []
               )

      assert quality_plan.pipelines == default_plan.pipelines
    end
  end

  test "rejects empty executable pipeline plans" do
    assert {:error, :empty_pipeline_plan} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", "cat.jpg"],
               pipelines: [],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             })
  end

  test "rejects unsupported source kinds instead of coercing them to plain" do
    assert {:error, {:unsupported_source_kind, :remote}} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :remote,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             })
  end

  test "rejects malformed plain source paths instead of raising during response filename planning" do
    for source_path <- [:bad, ["images", 1], ["images" | :bad]] do
      source = %Plain{path: source_path}

      assert PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: source_path,
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             }) == {:error, {:unsupported_source, source}}
    end
  end

  test "rejects malformed pipeline request entries" do
    assert {:error, {:invalid_pipeline_request, :bogus}} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}, :bogus],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             })
  end

  test "projects native request facets into product-neutral plan facets" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: %ImagePlug.Parser.Native.OutputRequest{format: :webp},
      policy: %ImagePlug.Parser.Native.RequestPolicy{},
      cache: %ImagePlug.Parser.Native.CacheRequest{cachebuster: "v1"},
      response: %ImagePlug.Parser.Native.ResponseRequest{
        filename: "cat",
        disposition: :attachment
      }
    }

    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}},
              policy: %ImagePlug.Plan.Policy{expires: 0},
              cache: %ImagePlug.Plan.Cache{cachebuster: "v1"},
              response: %Response{
                filename: %Filename{stem: "cat"},
                disposition: :attachment
              }
            }} = PlanBuilder.to_plan(request, now: ~U[2026-05-05 12:00:00Z])
  end

  test "derives response filename stem from source basename when omitted" do
    assert {:ok,
            %Plan{
              response: %Response{
                filename: %Filename{stem: "cat"}
              }
            }} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             })

    assert {:ok,
            %Plan{
              response: %Response{
                filename: %Filename{stem: "image"}
              }
            }} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", ""],
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Native.OutputRequest{}
             })
  end

  defp parsed_request do
    map({valid_pipeline_request(), output_format()}, fn {pipeline_request, output_format} ->
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: ["images", "cat.jpg"],
        pipelines: [pipeline_request],
        output: %ImagePlug.Parser.Native.OutputRequest{format: output_format}
      }
    end)
  end

  defp valid_pipeline_request do
    map(valid_geometry(), &struct!(PipelineRequest, &1))
  end

  defp valid_geometry do
    one_of([
      constant([]),
      map(fit_dimension(), &[width: &1]),
      map(fit_dimension(), &[height: &1]),
      map({fit_dimension(), fit_dimension()}, fn {width, height} ->
        [width: width, height: height]
      end),
      map({constant(:fill), fit_dimension(), fit_dimension()}, fn {resizing_type, width, height} ->
        [resizing_type: resizing_type, width: width, height: height]
      end),
      constant(resizing_type: :force),
      map({constant(:force), pixel_dimension(), one_of([pixel_dimension(), constant(nil)])}, fn
        {resizing_type, width, height} ->
          [resizing_type: resizing_type, width: width, height: height]
      end)
    ])
  end

  defp fit_dimension do
    map(integer(0..10_000), &{:pixels, &1})
  end

  defp pixel_dimension do
    map(integer(1..10_000), &{:pixels, &1})
  end

  defp output_format do
    one_of([constant(nil), member_of([:webp, :avif, :jpeg, :png])])
  end

  defp parsed_pipeline(path) do
    with {:ok, parsed} <- Native.parse_request(conn(:get, path), []) do
      case parsed.pipelines do
        [pipeline] -> {:ok, pipeline}
        pipelines -> {:error, {:unexpected_pipelines, pipelines}}
      end
    end
  end

  defp plan_pipeline(attrs) do
    attrs = normalize_orientation_attrs(attrs)

    PlanBuilder.to_plan(
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: ["images", "cat.jpg"],
        pipelines: [struct!(PipelineRequest, attrs)],
        output: %ImagePlug.Parser.Native.OutputRequest{}
      },
      []
    )
  end

  defp normalize_orientation_attrs(attrs) do
    {auto_orient, attrs} = Keyword.pop(attrs, :auto_orient)
    {rotate, attrs} = Keyword.pop(attrs, :rotate)
    {flip, attrs} = Keyword.pop(attrs, :flip)

    orientation_attrs =
      []
      |> maybe_put(:auto_orient, auto_orient)
      |> maybe_put(:rotate, rotate)
      |> maybe_put(:flip, flip)

    if orientation_attrs == [] do
      attrs
    else
      {orientation, attrs} = Keyword.pop(attrs, :orientation, %ImagePlug.Plan.Orientation{})
      Keyword.put(attrs, :orientation, struct!(orientation, orientation_attrs))
    end
  end

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Keyword.put(attrs, key, value)
end
