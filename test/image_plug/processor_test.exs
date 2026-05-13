defmodule ImagePlug.Runtime.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Runtime.DecodedOrigin
  alias ImagePlug.Runtime.Origin
  alias ImagePlug.Runtime.Processor
  alias ImagePlug.Runtime.ProcessorTest.DecodeErrorImageOpen
  alias ImagePlug.Runtime.ProcessorTest.DecodeValidImageOpen
  alias ImagePlug.Runtime.ProcessorTest.Materializer
  alias ImagePlug.Runtime.ProcessorTest.OriginImage
  alias ImagePlug.Transform.State

  defp opts do
    [origin_req_options: [plug: OriginImage]]
  end

  defp plan do
    %Plan{
      source: {:plain, ["this", "path", "does-not-drive-fetch.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resize_fit(width, height) do
    Operation.resize(:fit, resize_dimension(width), resize_dimension(height), enlargement: :deny)
  end

  defp resize_cover(width, height) do
    Operation.resize(:cover, resize_dimension(width), resize_dimension(height),
      enlargement: :deny
    )
  end

  defp resize_dimension(:auto), do: :auto
  defp resize_dimension(pixels), do: {:px, pixels}

  defp process_origin(%Plan{} = plan, origin_identity, opts) do
    Processor.process_origin(plan, origin_identity, opts)
  end

  defp fetch_decode_validate_origin_with_source_format(%Plan{} = plan, origin_identity, opts) do
    Processor.fetch_decode_validate_origin_with_source_format(plan, origin_identity, opts)
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
      source: {:plain, ["images", "cat-300.jpg"]},
      pipelines: [%Pipeline{operations: []}, %Pipeline{operations: []}],
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
    assert state.errors == []
    assert_receive first_message
    assert first_message == {:pipeline_event, ref, :materialized_between_pipelines}
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
  end

  test "fetch_decode_validate_origin_with_source_format plans decode options from the first pipeline only" do
    {:ok, first_operation} = resize_fit(120, :auto)
    {:ok, second_operation} = resize_cover(80, 80)

    plan = %Plan{
      source: {:plain, ["images", "cat-300.jpg"]},
      pipelines: [
        %Pipeline{operations: [first_operation]},
        %Pipeline{operations: [second_operation]}
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
  end

  test "fetch_decode_validate_origin_with_source_format returns singly tagged decode errors" do
    assert {:error, {:decode, :forced_decode_error}} =
             fetch_decode_validate_origin_with_source_format(
               plan(),
               "http://origin.test/images/cat-300.jpg",
               Keyword.put(opts(), :image_open_module, DecodeErrorImageOpen)
             )
  end

  test "decode_validate_origin_response returns input limit errors" do
    {:ok, operation} = resize_fit(120, :auto)

    plan = %Plan{
      plan()
      | pipelines: [
          %Pipeline{operations: [operation]}
        ]
    }

    assert {:ok, origin_response} =
             Origin.fetch(
               "http://origin.test/images/cat-300.jpg",
               Keyword.fetch!(opts(), :origin_req_options)
             )

    assert {:error, {:input_limit, {:too_many_input_pixels, 400, 399}}} =
             Processor.decode_validate_origin_response(
               origin_response,
               plan,
               opts()
               |> Keyword.put(:image_open_module, DecodeValidImageOpen)
               |> Keyword.put(:max_input_pixels, 399)
             )
  end
end
