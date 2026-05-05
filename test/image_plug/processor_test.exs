defmodule ImagePlug.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Origin.StreamStatus
  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Processor
  alias ImagePlug.ProcessorTest.DecodeErrorImageOpen
  alias ImagePlug.ProcessorTest.FirstTransform
  alias ImagePlug.ProcessorTest.InvalidReturnMaterializer
  alias ImagePlug.ProcessorTest.InvalidStateMaterializer
  alias ImagePlug.ProcessorTest.Materializer
  alias ImagePlug.ProcessorTest.OriginImage
  alias ImagePlug.ProcessorTest.OriginShouldNotFetch
  alias ImagePlug.ProcessorTest.SecondTransform
  alias ImagePlug.ProcessorTest.SequentialFailingTransform
  alias ImagePlug.Source.Plain
  alias ImagePlug.TransformState

  defp opts do
    [origin_req_options: [plug: OriginImage]]
  end

  defp plan do
    %Plan{
      source: %Plain{path: ["this", "path", "does-not-drive-fetch.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }
  end

  defp invalid_pipeline_plan do
    %Plan{plan() | pipelines: [:not_a_pipeline]}
  end

  test "process_origin fetches plain plan sources from the resolved origin identity" do
    assert {:ok, %TransformState{} = state} =
             Processor.process_origin(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert state.image
    assert state.errors == []
  end

  test "fetch_decode_validate_origin_with_source_format accepts plain plan sources" do
    assert {:ok, %Processor.DecodedOrigin{} = decoded} =
             Processor.fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :random, fail_on: :error]
    assert %ImagePlug.Origin.Response{} = decoded.origin_response

    Processor.close_pending_origin(decoded.origin_response)
  end

  test "process_origin fetches, decodes, validates, executes, and materializes a chain" do
    assert {:ok, %TransformState{} = state} =
             Processor.process_origin(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert state.image
    assert state.errors == []
  end

  test "process_origin materializes between pipelines before executing the next pipeline" do
    test_pid = self()
    ref = make_ref()

    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{operations: [{FirstTransform, %FirstTransform{}}]},
        %Pipeline{operations: [{SecondTransform, %SecondTransform{test_pid: test_pid, ref: ref}}]}
      ],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }

    opts =
      opts()
      |> Keyword.put(:image_materializer, Materializer)
      |> Keyword.put(:test_pid, test_pid)
      |> Keyword.put(:test_ref, ref)

    assert {:ok, %TransformState{} = state} =
             Processor.process_origin(
               plan,
               "http://origin.test/images/cat-300.jpg",
               opts
             )

    assert state.image
    assert state.debug
    assert state.errors == []
    assert_receive first_message
    assert first_message == {:pipeline_event, ref, :materialized_between_pipelines}
    assert_receive second_message
    assert second_message == {:pipeline_event, ref, :second_transform_ran}
  end

  test "process_origin returns a controlled config error for invalid materializer results" do
    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{operations: []},
        %Pipeline{operations: []}
      ],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }

    assert {:error,
            {:config,
             {:invalid_image_materializer_result, InvalidReturnMaterializer,
              {:ok, :not_a_transform_state}}}} =
             Processor.process_origin(
               plan,
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_materializer, InvalidReturnMaterializer)
             )
  end

  test "process_origin returns a controlled config error for materialized states without images" do
    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{operations: []},
        %Pipeline{operations: []}
      ],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }

    assert {:error,
            {:config,
             {:invalid_image_materializer_result, InvalidStateMaterializer,
              {:ok, %TransformState{image: nil}}}}} =
             Processor.process_origin(
               plan,
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_materializer, InvalidStateMaterializer)
             )
  end

  test "process_origin returns a controlled config error for non-module materializers" do
    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{operations: []},
        %Pipeline{operations: []}
      ],
      output: %OutputPlan{mode: {:explicit, :jpeg}}
    }

    assert {:error, {:config, {:invalid_image_materializer, "not a module"}}} =
             Processor.process_origin(
               plan,
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_materializer, "not a module")
             )
  end

  test "process_origin rejects invalid pipeline plans before fetching origin" do
    assert {:error, {:invalid_pipeline_plan, [:not_a_pipeline]}} =
             Processor.process_origin(
               invalid_pipeline_plan(),
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :origin_req_options, plug: OriginShouldNotFetch)
             )
  end

  test "fetch_origin_with_source_format rejects invalid pipeline plans before fetching origin" do
    assert {:error, {:invalid_pipeline_plan, [:not_a_pipeline]}} =
             Processor.fetch_origin_with_source_format(
               invalid_pipeline_plan(),
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :origin_req_options, plug: OriginShouldNotFetch)
             )
  end

  test "processor keeps pipeline validation at public boundaries" do
    processor_source =
      __DIR__
      |> Path.join("../../lib/image_plug/processor.ex")
      |> Path.expand()
      |> File.read!()

    assert processor_source =~ "Plan.validated_pipelines(plan)"
    assert processor_source |> String.split("Plan.validated_pipelines(plan)") |> length() == 2
  end

  test "fetch_decode_validate_origin_with_source_format returns decoded origin context" do
    assert {:ok, %Processor.DecodedOrigin{} = decoded} =
             Processor.fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :random, fail_on: :error]
    assert %ImagePlug.Origin.Response{} = decoded.origin_response

    Processor.close_pending_origin(decoded.origin_response)
  end

  test "fetch_decode_validate_origin_with_source_format returns singly tagged decode errors" do
    assert {:error, {:decode, :forced_decode_error}} =
             Processor.fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_open_module, DecodeErrorImageOpen)
             )
  end

  test "process_decoded_origin closes pending origins on transform errors" do
    {:ok, image} = Image.new(1, 1)
    {:ok, stream_status} = StreamStatus.start_link()
    test_pid = self()

    worker =
      spawn_link(fn ->
        send(test_pid, :worker_ready)

        receive do
          {:cancel, _ref} -> :ok
        end
      end)

    assert_receive :worker_ready

    origin_response = %ImagePlug.Origin.Response{
      content_type: "image/jpeg",
      headers: [],
      ref: make_ref(),
      stream: [],
      stream_status: stream_status,
      url: "http://origin.test/images/cat-300.jpg",
      worker: worker
    }

    decoded = %Processor.DecodedOrigin{
      decode_options: [access: :sequential, fail_on: :error],
      image: image,
      origin_response: origin_response,
      source_format: :jpeg
    }

    worker_ref = Process.monitor(worker)

    assert {:error, {:transform_error, %TransformState{}}} =
             Processor.process_decoded_origin(
               decoded,
               %Plan{
                 plan()
                 | pipelines: [
                     %Pipeline{
                       operations: [{SequentialFailingTransform, %SequentialFailingTransform{}}]
                     }
                   ]
               },
               opts()
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    StreamStatus.stop(stream_status)
  end
end
