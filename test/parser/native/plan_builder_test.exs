defmodule ImagePlug.Parser.Native.PlanBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.Parser.Native.ParsedRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.PlanBuilder
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
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

    assert [%Transform.Contain{} = params] = operations
    assert params.width == {:pixels, 300}
  end

  test "plans fit requests as non-letterboxed contain operations with enlarge constraints" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: false)

    assert [
             %Transform.Contain{
               type: :dimensions,
               width: {:pixels, 300},
               height: {:pixels, 200},
               constraint: :max,
               letterbox: false
             }
           ] = operations

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 300}, height: {:pixels, 200}, enlarge: true)

    assert [
             %Transform.Contain{
               type: :dimensions,
               width: {:pixels, 300},
               height: {:pixels, 200},
               constraint: :regular,
               letterbox: false
             }
           ] = operations
  end

  test "plans fill requests as cover operations with enlarge constraints" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               enlarge: false
             )

    assert [
             %Transform.Cover{
               type: :dimensions,
               width: {:pixels, 300},
               height: {:pixels, 200},
               constraint: :max
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
             %Transform.Cover{
               type: :dimensions,
               width: {:pixels, 300},
               height: {:pixels, 200},
               constraint: :none
             }
           ] = operations
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

  test "normalizes single zero fit dimensions to auto contain dimensions" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(width: {:pixels, 0}, height: {:pixels, 200})

    assert [
             %Transform.Contain{
               width: :auto,
               height: {:pixels, 200},
               constraint: :max,
               letterbox: false
             }
           ] = operations
  end

  test "rejects force requests with zero dimensions" do
    assert plan_pipeline(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200}) ==
             {:error, {:unsupported_zero_dimension, :force}}

    assert plan_pipeline(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0}) ==
             {:error, {:unsupported_zero_dimension, :force}}
  end

  test "rejects unsupported extend and gravity offset semantics" do
    assert plan_pipeline(extend: true) == {:error, {:unsupported_extend, true}}

    assert plan_pipeline(extend_gravity: {:anchor, :left, :top}) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :left, :top}}}

    assert plan_pipeline(extend_x_offset: 5.0) ==
             {:error, {:unsupported_extend_offset, 5.0}}

    assert plan_pipeline(extend_y_offset: -3.0) ==
             {:error, {:unsupported_extend_offset, -3.0}}

    assert plan_pipeline(gravity_x_offset: 1.0) ==
             {:error, {:unsupported_gravity_offset, {1.0, 0.0}}}

    assert plan_pipeline(gravity_y_offset: -2.0) ==
             {:error, {:unsupported_gravity_offset, {0.0, -2.0}}}
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

    assert [%Transform.Contain{} = first_params] = first_operations
    assert first_params.width == {:pixels, 500}
    assert first_params.height == :auto

    assert [%Transform.Contain{} = second_params] = second_operations
    assert second_params.width == :auto
    assert second_params.height == {:pixels, 200}
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

    assert [%Transform.Scale{} = automatic_params] = operations
    assert automatic_params.width == {:pixels, 300}
    assert automatic_params.height == {:pixels, 200}

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Plan.Pipeline{operations: operations}],
              output: %ImagePlug.Plan.Output{mode: {:explicit, :webp}}
            }} =
             PlanBuilder.to_plan(request, [])

    assert [%Transform.Scale{} = explicit_params] = operations
    assert explicit_params.width == {:pixels, 300}
    assert explicit_params.height == {:pixels, 200}
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
              response: %ImagePlug.Plan.Response{filename: "cat", disposition: :attachment}
            }} = PlanBuilder.to_plan(request, now: ~U[2026-05-05 12:00:00Z])
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
