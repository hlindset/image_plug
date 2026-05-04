defmodule ImagePlug.ParamParser.Native.PlanBuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.OutputPlan
  alias ImagePlug.ParamParser.Native.ParsedRequest
  alias ImagePlug.ParamParser.Native.PipelineRequest
  alias ImagePlug.ParamParser.Native.PlanBuilder
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  test "converts one native pipeline request into a product-neutral plan" do
    request = %ParsedRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      pipelines: [%PipelineRequest{width: {:pixels, 300}}],
      output_format: nil
    }

    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [
                %Pipeline{operations: operations}
              ],
              output: %OutputPlan{mode: :automatic}
            }} = PlanBuilder.to_plan(request)

    assert [{Transform.Contain, params}] = operations
    assert params.width == {:pixels, 300}
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
      output_format: :webp
    }

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Pipeline{operations: operations}],
              output: %ImagePlug.OutputPlan{mode: :automatic}
            }} =
             PlanBuilder.to_plan(%ParsedRequest{request | output_format: nil})

    assert [{Transform.Scale, automatic_params}] = operations
    assert automatic_params.width == {:pixels, 300}
    assert automatic_params.height == {:pixels, 200}

    assert {:ok,
            %ImagePlug.Plan{
              pipelines: [%ImagePlug.Pipeline{operations: operations}],
              output: %ImagePlug.OutputPlan{mode: {:explicit, :webp}}
            }} =
             PlanBuilder.to_plan(request)

    assert [{Transform.Scale, explicit_params}] = operations
    assert explicit_params.width == {:pixels, 300}
    assert explicit_params.height == {:pixels, 200}
  end

  property "output format does not change planned pipeline operations" do
    check all %ParsedRequest{} = parsed_request <- parsed_request(),
              max_runs: 100 do
      assert {:ok, %ImagePlug.Plan{} = automatic_plan} =
               PlanBuilder.to_plan(%ParsedRequest{parsed_request | output_format: nil})

      assert automatic_plan.output == %ImagePlug.OutputPlan{mode: :automatic}
      assert [%ImagePlug.Pipeline{} | _] = automatic_plan.pipelines

      for format <- [:webp, :avif, :jpeg, :png] do
        assert {:ok, %ImagePlug.Plan{} = explicit_plan} =
                 PlanBuilder.to_plan(%ParsedRequest{parsed_request | output_format: format})

        assert explicit_plan.output == %ImagePlug.OutputPlan{mode: {:explicit, format}}
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
               output_format: nil
             })
  end

  test "rejects unsupported source kinds instead of coercing them to plain" do
    assert {:error, {:unsupported_source_kind, :remote}} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :remote,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}],
               output_format: nil
             })
  end

  test "rejects malformed pipeline request entries" do
    assert {:error, {:invalid_pipeline_request, :bogus}} =
             PlanBuilder.to_plan(%ParsedRequest{
               signature: "_",
               source_kind: :plain,
               source_path: ["images", "cat.jpg"],
               pipelines: [%PipelineRequest{}, :bogus],
               output_format: nil
             })
  end

  defp parsed_request do
    map({valid_pipeline_request(), output_format()}, fn {pipeline_request, output_format} ->
      %ParsedRequest{
        signature: "_",
        source_kind: :plain,
        source_path: ["images", "cat.jpg"],
        pipelines: [pipeline_request],
        output_format: output_format
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
end
