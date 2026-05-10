defmodule ImagePlug.Runtime.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Runtime.DecodedOrigin
  alias ImagePlug.Runtime.Origin
  alias ImagePlug.Runtime.Origin.StreamStatus
  alias ImagePlug.Runtime.Processor
  alias ImagePlug.Runtime.ProcessorTest.DecodeErrorImageOpen
  alias ImagePlug.Runtime.ProcessorTest.DecodeValidImageOpen
  alias ImagePlug.Runtime.ProcessorTest.FirstTransform
  alias ImagePlug.Runtime.ProcessorTest.InvalidReturnMaterializer
  alias ImagePlug.Runtime.ProcessorTest.InvalidStateMaterializer
  alias ImagePlug.Runtime.ProcessorTest.Materializer
  alias ImagePlug.Runtime.ProcessorTest.OriginImage
  alias ImagePlug.Runtime.ProcessorTest.SecondTransform
  alias ImagePlug.Runtime.ProcessorTest.SequentialFailingTransform
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.Operation.Cover
  alias ImagePlug.Transform.Operation.Scale
  alias ImagePlug.Transform.State

  defp opts do
    [origin_req_options: [plug: OriginImage]]
  end

  defp plan do
    %Plan{
      source: %Plain{path: ["this", "path", "does-not-drive-fetch.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp process_origin(%Plan{} = plan, origin_identity, opts) do
    Processor.process_origin(plan, plan.pipelines, origin_identity, opts)
  end

  defp fetch_decode_validate_origin_with_source_format(%Plan{} = plan, origin_identity, opts) do
    Processor.fetch_decode_validate_origin_with_source_format(
      plan,
      plan.pipelines,
      origin_identity,
      opts
    )
  end

  defp process_decoded_origin(%DecodedOrigin{} = decoded, %Plan{} = plan, opts) do
    Processor.process_decoded_origin(decoded, plan, opts)
  end

  test "process_origin fetches plain plan sources from the resolved origin identity" do
    assert {:ok, %State{} = state} =
             process_origin(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert state.image
    assert state.errors == []
  end

  test "fetch_decode_validate_origin_with_source_format accepts plain plan sources" do
    assert {:ok, %DecodedOrigin{} = decoded} =
             fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :random, fail_on: :error]
    assert %ImagePlug.Runtime.Origin.Response{} = decoded.origin_response

    Processor.close_pending_origin(decoded.origin_response)
  end

  test "process_origin fetches, decodes, validates, executes, and materializes a chain" do
    assert {:ok, %State{} = state} =
             process_origin(
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
        %Pipeline{operations: [%FirstTransform{}]},
        %Pipeline{operations: [%SecondTransform{test_pid: test_pid, ref: ref}]}
      ],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    opts =
      opts()
      |> Keyword.put(:image_materializer, Materializer)
      |> Keyword.put(:test_pid, test_pid)
      |> Keyword.put(:test_ref, ref)

    assert {:ok, %State{} = state} =
             process_origin(
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
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:error,
            {:config,
             {:invalid_image_materializer_result, InvalidReturnMaterializer,
              {:ok, :not_a_transform_state}}}} =
             process_origin(
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
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:error,
            {:config,
             {:invalid_image_materializer_result, InvalidStateMaterializer,
              {:ok, %State{image: nil}}}}} =
             process_origin(
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
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:error, {:config, {:invalid_image_materializer, "not a module"}}} =
             process_origin(
               plan,
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_materializer, "not a module")
             )
  end

  test "fetch_decode_validate_origin_with_source_format returns decoded origin context" do
    assert {:ok, %DecodedOrigin{} = decoded} =
             fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :random, fail_on: :error]
    assert %ImagePlug.Runtime.Origin.Response{} = decoded.origin_response

    Processor.close_pending_origin(decoded.origin_response)
  end

  test "fetch_decode_validate_origin_with_source_format plans decode options from the first pipeline only" do
    plan = %Plan{
      source: %Plain{path: ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{
          operations: [
            %Scale{type: :dimensions, width: {:pixels, 120}, height: :auto}
          ]
        },
        %Pipeline{
          operations: [
            %Cover{
              type: :dimensions,
              width: {:pixels, 80},
              height: {:pixels, 80},
              constraint: :none
            }
          ]
        }
      ],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:ok, %DecodedOrigin{} = decoded} =
             fetch_decode_validate_origin_with_source_format(
               plan,
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert decoded.decode_options == [access: :sequential, fail_on: :error]

    Processor.close_pending_origin(decoded.origin_response)
  end

  test "fetch_decode_validate_origin_with_source_format returns singly tagged decode errors" do
    assert {:error, {:decode, :forced_decode_error}} =
             fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_open_module, DecodeErrorImageOpen)
             )
  end

  test "decode_validate_origin_response closes pending origins on validation errors" do
    plan = %Plan{
      plan()
      | pipelines: [
          %Pipeline{
            operations: [
              %Scale{type: :dimensions, width: {:pixels, 120}, height: :auto}
            ]
          }
        ]
    }

    pipelines = plan.pipelines

    assert {:ok, origin_response, :jpeg} =
             Processor.fetch_origin_with_source_format(
               plan,
               pipelines,
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert Origin.stream_status(origin_response) == :pending

    worker_ref = Process.monitor(origin_response.worker)

    assert {:error, {:input_limit, {:too_many_input_pixels, 400, 399}}} =
             Processor.decode_validate_origin_response(
               origin_response,
               :jpeg,
               plan,
               pipelines,
               opts()
               |> Keyword.put(:image_open_module, DecodeValidImageOpen)
               |> Keyword.put(:max_input_pixels, 399)
             )

    assert_receive {:DOWN, ^worker_ref, :process, _worker, _reason}
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

    origin_response = %ImagePlug.Runtime.Origin.Response{
      content_type: "image/jpeg",
      headers: [],
      ref: make_ref(),
      stream: [],
      stream_status: stream_status,
      url: "http://origin.test/images/cat-300.jpg",
      worker: worker
    }

    decoded = %DecodedOrigin{
      decode_options: [access: :sequential, fail_on: :error],
      image: image,
      origin_response: origin_response,
      source_format: :jpeg,
      source_metadata: %SourceMetadata{
        width: Image.width(image),
        height: Image.height(image),
        orientation: :normal,
        format: :jpeg,
        source_type: :raster
      }
    }

    worker_ref = Process.monitor(worker)

    assert {:error, {:transform_error, %State{}}} =
             process_decoded_origin(
               decoded,
               %Plan{
                 plan()
                 | pipelines: [
                     %Pipeline{
                       operations: [%SequentialFailingTransform{}]
                     }
                   ]
               },
               opts()
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    StreamStatus.stop(stream_status)
  end

  test "process_decoded_origin closes pending origins on semantic resolution errors" do
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

    origin_response = %ImagePlug.Runtime.Origin.Response{
      content_type: "image/jpeg",
      headers: [],
      ref: make_ref(),
      stream: [],
      stream_status: stream_status,
      url: "http://origin.test/images/cat-300.jpg",
      worker: worker
    }

    decoded = %DecodedOrigin{
      decode_options: [access: :random, fail_on: :error],
      image: image,
      origin_response: origin_response,
      source_format: :jpeg,
      source_metadata: %SourceMetadata{
        width: Image.width(image),
        height: Image.height(image),
        orientation: :normal,
        format: :jpeg,
        source_type: :raster
      }
    }

    assert {:ok, x} = Dimension.pixels(1)
    assert {:ok, y} = Dimension.pixels(1)
    assert {:ok, width} = Dimension.pixels(1)
    assert {:ok, height} = Dimension.pixels(1)

    assert {:ok, region} =
             Region.new(x: x, y: y, width: width, height: height, space: :post_orient)

    assert {:ok, operation} = Operation.crop_region(region: region)

    worker_ref = Process.monitor(worker)

    assert {:error, {:unsupported_crop_region_space, :post_orient}} =
             process_decoded_origin(
               decoded,
               %Plan{
                 plan()
                 | pipelines: [
                     %Pipeline{
                       operations: [operation]
                     }
                   ]
               },
               opts()
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    StreamStatus.stop(stream_status)
  end
end
