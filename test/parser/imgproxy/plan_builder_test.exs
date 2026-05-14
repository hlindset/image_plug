defmodule ImagePlug.Parser.Imgproxy.PlanBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Parser.Imgproxy.ParsedRequest
  alias ImagePlug.Parser.Imgproxy.PipelineRequest
  alias ImagePlug.Parser.Imgproxy.PlanBuilder
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  test "converts one imgproxy pipeline request into a product-neutral plan" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
    }

    assert {:ok,
            %Plan{
              source: {:plain, ["images", "cat.jpg"]},
              pipelines: [
                %Pipeline{operations: operations}
              ],
              output: %Output{mode: :automatic}
            }} = PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :fit} = params] = operations
    assert params.width == pixels(300)
    assert params.height == auto()
    assert params.dpr == ratio(1, 1)
    assert params.enlargement == :deny
  end

  test "plans fit requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: false)

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :deny

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: true)

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :allow
  end

  test "plans fill requests as neutral resize operations with enlarge rules" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: false
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :deny
    assert anchor(resize.guide) == {:center, :center}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: true
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.width == pixels(300)
    assert resize.height == pixels(200)
    assert resize.enlargement == :allow
    assert anchor(resize.guide) == {:center, :center}
  end

  test "plans gravity-bearing fill, fill-down, and auto with result crop operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :left, :top}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert anchor(resize.guide) == {:left, :top}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:fp, 0.25, 0.75}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert focal_point(resize.guide) == {1, 4, 3, 4}
    assert resize.enlargement == :deny

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :auto,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom}
             )

    assert [%Operation.Resize{mode: :auto} = resize] = operations
    assert anchor(resize.guide) == {:right, :bottom}
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
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             plan_pipeline(
               width: {:pixels, 0},
               height: {:pixels, 0},
               min_width: {:pixels, 300}
             )

    assert resize.width == auto()
    assert resize.height == auto()
    assert resize.min_width == pixels(300)
  end

  test "normalizes single zero fit dimensions to auto resize dimensions" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 0}, height: {:pixels, 200})

    assert [%Operation.Resize{mode: :fit} = resize] = operations
    assert resize.width == auto()
    assert resize.height == pixels(200)
  end

  test "plans force requests with one zero dimension as source-preserving auto dimensions" do
    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :stretch} = resize]}]
            }} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200})

    assert resize.width == auto()
    assert resize.height == pixels(200)

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :stretch} = resize]}]
            }} =
             plan_pipeline(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0})

    assert resize.width == pixels(300)
    assert resize.height == auto()
  end

  test "plans fit, fill-down, force, and auto as product-neutral resize operations" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}
              ]
            }} =
             plan_pipeline(resizing_type: :fit, width: {:pixels, 100}, height: {:pixels, 0})

    assert resize.width == pixels(100)
    assert resize.height == auto()

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{mode: :cover} = down
                  ]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100}
             )

    assert down.enlargement == :deny

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{mode: :auto}
                  ]
                }
              ]
            }} =
             plan_pipeline(resizing_type: :auto, width: {:pixels, 100}, height: {:pixels, 100})
  end

  test "plans extend and extend aspect ratio as neutral canvas operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 100}, height: {:pixels, 100}, extend: true)

    assert Enum.any?(operations, &match?(%Operation.Canvas{}, &1))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]} = plan} =
             plan_pipeline(extend_aspect_ratio: {16, 9})

    assert Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
    assert {:ok, _pipelines} = ImagePlug.Transform.validate_prefetch_safe_plan(plan)
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

    assert %Operation.Canvas{
             placement: placement,
             x_offset: 5.0,
             y_offset: -3.0
           } = List.last(operations)

    assert placement == :top_left
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

    refute Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "plans top-level gravity offsets into result crop resize fields" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 12.0},
               gravity_y_offset: {:scale, -0.25}
             )

    assert anchor(crop.guide) == {:right, :bottom}
    assert crop.x_offset == {:pixels, -12.0}
    assert crop.y_offset == {:scale, 0.25}
  end

  test "plans dpr with semantic resize guide and adjusted offsets" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
                }
              ]
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

    assert crop.dpr == ratio(2, 1)
    assert anchor(crop.guide) == {:right, :center}
    assert crop.x_offset == {:pixels, -12.0}
    assert crop.y_offset == {:scale, -0.25}
  end

  test "plans top-level gravity offsets into auto result crop resize fields" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :auto} = crop]
                }
              ]
            }} =
             plan_pipeline(
               resizing_type: :auto,
               width: {:pixels, 100},
               height: {:pixels, 50},
               gravity: {:anchor, :right, :bottom},
               gravity_x_offset: {:pixels, 8.0},
               gravity_y_offset: {:scale, -0.5}
             )

    assert anchor(crop.guide) == {:right, :bottom}
    assert crop.x_offset == {:pixels, -8.0}
    assert crop.y_offset == {:scale, 0.5}
  end

  test "parsed crop gravity is independent from top-level gravity" do
    assert {:ok, pipeline} = parsed_pipeline("/_/g:so/c:0.5:0.25:nowe/plain/images/cat.jpg")

    assert pipeline.gravity == {:anchor, :center, :bottom}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
  end

  test "crop without explicit gravity inherits top-level gravity" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               gravity: {:anchor, :left, :top},
               crop: %ImagePlug.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: nil
               }
             )

    assert crop.guide == :top_left
  end

  test "plans crop focal-point gravity and relative offsets" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePlug.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:fp, 0.25, 0.75},
                 x_offset: {:scale, 0.25},
                 y_offset: {:pixels, -12.0}
               }
             )

    assert focal_point(crop.guide) == {1, 4, 3, 4}
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
        crop: %ImagePlug.Parser.Imgproxy.CropRequest{
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
        crop: %ImagePlug.Parser.Imgproxy.CropRequest{
          width: {:pixels, 100},
          height: {:pixels, 100}
        }
      )

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: one_ops}]}} = one
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: two_ops}]}} = two

    assert operation_names(one_ops) == operation_names(two_ops)

    assert operation_names(one_ops) == [:rotate, :crop_guided, {:resize, :fit}]

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               auto_orient: true,
               rotate: 90,
               flip: :horizontal,
               crop: %ImagePlug.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100}
               },
               width: {:pixels, 200}
             )

    assert operation_names(operations) == [
             :auto_orient,
             :rotate,
             :flip,
             :crop_guided,
             {:resize, :fit}
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

    assert operation_names(operations) == [{:resize, :cover}, :canvas]
  end

  test "plans padding after canvas and before background composition" do
    assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               width: {:pixels, 100},
               height: {:pixels, 100},
               extend: true,
               padding_top: 1,
               padding_right: 2,
               padding_bottom: 3,
               padding_left: 4,
               background_color: red
             )

    assert [
             %Operation.Resize{},
             %Operation.Canvas{fill: :transparent},
             %Operation.Padding{
               top: {:px, 1},
               right: {:px, 2},
               bottom: {:px, 3},
               left: {:px, 4},
               fill: :transparent,
               pixel_ratio: {:effective, {:ratio, 1, 1}, :canvas_preserving}
             },
             %Operation.Background{color: ^red}
           ] = operations
  end

  test "padding no-op forms emit no padding operation" do
    for attrs <- [
          [padding_top: 0, padding_right: 0, padding_bottom: 0, padding_left: 0]
        ] do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} = plan_pipeline(attrs)
      refute Enum.any?(operations, &match?(%Operation.Padding{}, &1))
    end
  end

  test "padding carries requested DPR as fallback for effective pixel ratio" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: [%Operation.Resize{}, %Operation.Padding{} = padding]}
              ]
            }} =
             plan_pipeline(width: {:pixels, 100}, dpr: 1.5, padding_top: 2)

    assert padding.pixel_ratio == {:effective, {:ratio, 3, 2}, :resize}
  end

  test "padding planned with extend uses canvas-preserving effective pixel ratio" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{},
                    %Operation.Canvas{},
                    %Operation.Padding{} = padding
                  ]
                }
              ]
            }} =
             plan_pipeline(
               width: {:pixels, 200},
               height: {:pixels, 100},
               dpr: 0.5,
               extend: true,
               padding_top: 10
             )

    assert padding.pixel_ratio == {:effective, {:ratio, 1, 2}, :canvas_preserving}
  end

  test "background unset or cleared emits no background operation" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(background_color: nil)

    refute Enum.any?(operations, &match?(%Operation.Background{}, &1))
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
               Imgproxy.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
    end
  end

  test "dropped imgproxy options with values remain parser errors" do
    for segment <- ~w(raw:false max_bytes:100 mb:100 crop_ar:1:1) do
      assert {:error, _reason} =
               Imgproxy.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
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
      assert Imgproxy.parse_request(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "plans neutral resize rule inputs before no-op operations" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             plan_pipeline(
               min_width: {:pixels, 100},
               min_height: {:pixels, 80},
               zoom_x: 2.0,
               zoom_y: 2.0,
               dpr: 2.0
             )

    assert resize.min_width == pixels(100)
    assert resize.min_height == pixels(80)
    assert resize.zoom_x == 2.0
    assert resize.zoom_y == 2.0
    assert resize.dpr == ratio(2, 1)
  end

  test "plans parsed crop and orientation semantics before no-op operations" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{}]}]}} =
             plan_pipeline(crop: struct(ImagePlug.Parser.Imgproxy.CropRequest))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%AutoOrient{}]}]}} =
             plan_pipeline(orientation: struct(ImagePlug.Plan.Orientation, auto_orient: true))

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             plan_pipeline(orientation_requested: true)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               crop: struct(ImagePlug.Parser.Imgproxy.CropRequest),
               orientation: struct(ImagePlug.Plan.Orientation, auto_orient: true)
             )

    assert operation_names(operations) == [:auto_orient, :crop_guided]
  end

  test "converts multiple imgproxy pipeline requests into separate product-neutral pipelines" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [
        %PipelineRequest{width: {:pixels, 500}},
        %PipelineRequest{height: {:pixels, 200}}
      ],
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
    }

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :fit} = first_params] = first_operations
    assert first_params.width == pixels(500)
    assert first_params.height == auto()

    assert [%Operation.Resize{mode: :fit} = second_params] = second_operations
    assert second_params.width == auto()
    assert second_params.height == pixels(200)
  end

  test "returns unsupported gravity planning errors" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{gravity: :sm}],
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
    }

    assert PlanBuilder.to_plan(request, []) == {:error, {:unsupported_gravity, :sm}}
  end

  test "represents output intent outside imgproxy pipeline operations" do
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
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{format: :webp}
    }

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Plan.Pipeline{operations: operations}],
              output: %ImagePlug.Plan.Output{mode: :automatic}
            }} =
             PlanBuilder.to_plan(
               %ParsedRequest{request | output: %ImagePlug.Parser.Imgproxy.OutputRequest{}},
               []
             )

    assert [%Operation.Resize{mode: :stretch} = automatic_params] = operations
    assert automatic_params.width == pixels(300)
    assert automatic_params.height == pixels(200)

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Plan.Pipeline{operations: operations}],
              output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}}
            }} =
             PlanBuilder.to_plan(request, [])

    assert [%Operation.Resize{mode: :stretch} = explicit_params] = operations
    assert explicit_params.width == pixels(300)
    assert explicit_params.height == pixels(200)
  end

  property "output format does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePlug.Plan{} = automatic_plan} =
               PlanBuilder.to_plan(
                 %ParsedRequest{
                   parsed_request
                   | output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
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
                     | output: %ImagePlug.Parser.Imgproxy.OutputRequest{format: format}
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
                   | output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
                 },
                 []
               )

      quality_request = %ImagePlug.Parser.Imgproxy.OutputRequest{
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

  test "projects imgproxy request facets into product-neutral plan facets" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{format: :webp},
      policy: %ImagePlug.Parser.Imgproxy.RequestPolicy{},
      cache: %ImagePlug.Parser.Imgproxy.CacheRequest{cachebuster: "v1"},
      response: %ImagePlug.Parser.Imgproxy.ResponseRequest{
        filename: "cat",
        disposition: :attachment
      }
    }

    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}},
              expires: 0,
              cachebuster: "v1",
              response: %Response{
                filename: "cat",
                disposition: :attachment
              }
            }} = PlanBuilder.to_plan(request, clock: fn -> ~U[2026-05-05 12:00:00Z] end)
  end

  test "derives response filename stem from source basename when omitted" do
    assert {:ok,
            %Plan{
              response: %Response{
                filename: "cat"
              }
            }} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
             })

    assert {:ok,
            %Plan{
              response: %Response{
                filename: "image"
              }
            }} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", ""],
               pipelines: [%PipelineRequest{}],
               output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
             })
  end

  test "rejects invalid explicit response filenames" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{}],
      output: %ImagePlug.Parser.Imgproxy.OutputRequest{},
      response: %ImagePlug.Parser.Imgproxy.ResponseRequest{
        filename: "../cat",
        disposition: :attachment
      }
    }

    assert PlanBuilder.to_plan(request, []) == {:error, {:invalid_filename, "../cat"}}
  end

  defp pixels(value), do: {:px, value}
  defp auto, do: :auto
  defp ratio(numerator, denominator), do: {:ratio, numerator, denominator}

  defp anchor(:center), do: {:center, :center}
  defp anchor({:anchor, x, y}), do: {x, y}

  defp focal_point(
         {:focal, {:ratio, x_numerator, x_denominator}, {:ratio, y_numerator, y_denominator}}
       ) do
    {x_numerator, x_denominator, y_numerator, y_denominator}
  end

  defp operation_names(operations), do: Enum.map(operations, &operation_name/1)

  defp operation_name(%AutoOrient{}), do: :auto_orient
  defp operation_name(%Rotate{}), do: :rotate
  defp operation_name(%Flip{}), do: :flip
  defp operation_name(%Operation.CropGuided{}), do: :crop_guided
  defp operation_name(%Operation.Resize{mode: mode}), do: {:resize, mode}
  defp operation_name(%Operation.Canvas{}), do: :canvas
  defp operation_name(%Operation.Padding{}), do: :padding
  defp operation_name(%Operation.Background{}), do: :background

  defp parsed_request do
    map({valid_pipeline_request(), output_format()}, fn {pipeline_request, output_format} ->
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: ["images", "cat.jpg"],
        pipelines: [pipeline_request],
        output: %ImagePlug.Parser.Imgproxy.OutputRequest{format: output_format}
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
    with {:ok, parsed} <- Imgproxy.parse_request(conn(:get, path), []) do
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
        output: %ImagePlug.Parser.Imgproxy.OutputRequest{}
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
