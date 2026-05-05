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
             }
           ] = operations
  end

  test "rejects gravity-bearing fill, fill-down, and auto requests until neutral gravity crop support exists" do
    assert plan_pipeline(
             resizing_type: :fill,
             width: {:pixels, 100},
             height: {:pixels, 100},
             gravity: {:anchor, :left, :top}
           ) == {:error, {:unsupported_gravity_for_resize, :fill}}

    assert plan_pipeline(
             resizing_type: :fill_down,
             width: {:pixels, 100},
             height: {:pixels, 100},
             gravity: {:fp, 0.25, 0.75}
           ) == {:error, {:unsupported_gravity_for_resize, :fill_down}}

    assert plan_pipeline(
             resizing_type: :auto,
             width: {:pixels, 100},
             height: {:pixels, 100},
             gravity: {:anchor, :right, :bottom}
           ) == {:error, {:unsupported_gravity_for_resize, :auto}}
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

  test "rejects force requests with zero dimensions" do
    assert plan_pipeline(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200}) ==
             {:error, {:unsupported_zero_dimension, :force}}

    assert plan_pipeline(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0}) ==
             {:error, {:unsupported_zero_dimension, :force}}
  end

  test "plans fit, fill-down, force, and auto as product-neutral resize operations" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.Resize{} = resize]}]}} =
             plan_pipeline(resizing_type: :fit, width: {:pixels, 100}, height: {:pixels, 0})

    assert resize.rule.mode == :fit

    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.Resize{} = down]}]}} =
             plan_pipeline(
               resizing_type: :fill_down,
               width: {:pixels, 100},
               height: {:pixels, 100}
             )

    assert down.rule.mode == :fill_down

    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%ImagePlug.Transform.AdaptiveResize{}]}]}} =
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

  test "rejects unsupported gravity offset semantics" do
    assert plan_pipeline(gravity_x_offset: 1.0) ==
             {:error, {:unsupported_gravity_offset, {1.0, 0.0}}}

    assert plan_pipeline(gravity_y_offset: -2.0) ==
             {:error, {:unsupported_gravity_offset, {0.0, -2.0}}}
  end

  test "parsed crop gravity is independent from top-level gravity" do
    assert {:ok, pipeline} = parsed_pipeline("/_/g:so/c:0.5:0.25:nowe/plain/images/cat.jpg")

    assert pipeline.gravity == {:anchor, :center, :bottom}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
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

  test "rejects unsupported parsed pipeline semantics before planning no-op operations" do
    assert plan_pipeline(crop: struct(ImagePlug.Parser.Native.CropRequest)) ==
             {:error, {:unsupported_pipeline_semantic, :crop}}

    assert plan_pipeline(orientation: struct(ImagePlug.Plan.Orientation, auto_orient: true)) ==
             {:error, {:unsupported_pipeline_semantic, :orientation}}

    assert plan_pipeline(orientation_requested: true) ==
             {:error, {:unsupported_pipeline_semantic, :orientation}}
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
end
