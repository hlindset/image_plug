defmodule ImagePlug.Request.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.Processor.Decoded
  alias ImagePlug.Request.ProcessorTest.DecodeErrorImageOpen
  alias ImagePlug.Request.ProcessorTest.Materializer
  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.SourceTest.ValidAdapter
  alias ImagePlug.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defmodule DecodeRaisesSourceStreamError do
    def open(stream, _decode_options) do
      Enum.to_list(stream)
      {:error, :should_not_reach_decode}
    end
  end

  defp opts do
    [sources: %{path: {ValidAdapter, []}}]
  end

  defp resolved_source do
    %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      cache: :normal,
      fetch: :fixture
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["this", "path", "does-not-drive-fetch.jpg"]},
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

  defp svg_supported? do
    case VipsImage.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end

  defp svg_body(width, height) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
      <rect width="#{width}" height="#{height}" fill="red"/>
    </svg>
    """
  end

  test "process_source fetches from the resolved source" do
    assert {:ok, %State{} = state} =
             Processor.process_source(
               plan(),
               resolved_source(),
               opts()
             )

    assert state.image
    assert_received {:source_fetch, :fixture}
  end

  test "fetch_decode_validate_source_with_source_format accepts resolved sources" do
    assert {:ok, %Decoded{} = decoded} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan(),
               resolved_source(),
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :random, fail_on: :error]
  end

  test "process_source materializes between pipelines before executing the next pipeline" do
    test_pid = self()
    ref = make_ref()

    plan = %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}, %Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    opts =
      opts()
      |> Keyword.put(:image_materializer, Materializer)
      |> Keyword.put(:test_pid, test_pid)
      |> Keyword.put(:test_ref, ref)

    assert {:ok, %State{} = state} =
             Processor.process_source(
               plan,
               resolved_source(),
               opts
             )

    assert state.image
    assert_receive {:pipeline_event, ^ref, :materialized_between_pipelines}
  end

  test "fetch_decode_validate_source_with_source_format plans decode options from the first pipeline only" do
    {:ok, first_operation} = resize_fit(120, :auto)
    {:ok, second_operation} = resize_cover(80, 80)

    plan = %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [
        %Pipeline{operations: [first_operation]},
        %Pipeline{operations: [second_operation]}
      ],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:ok, %Decoded{} = decoded} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan,
               resolved_source(),
               opts()
             )

    assert decoded.decode_options == [access: :sequential, fail_on: :error]
  end

  test "fetch_decode_validate_source_with_source_format returns singly tagged decode errors" do
    assert {:error, {:decode, :forced_decode_error}} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan(),
               resolved_source(),
               Keyword.put(opts(), :image_open_module, DecodeErrorImageOpen)
             )
  end

  test "decode_validate_source_response returns input limit errors" do
    {:ok, operation} = resize_fit(120, :auto)

    plan = %Plan{
      plan()
      | pipelines: [
          %Pipeline{operations: [operation]}
        ]
    }

    source_response = %Response{stream: [File.read!("priv/static/images/beach.jpg")]}

    assert {:error, {:input_limit, {:too_many_input_pixels, pixel_count, 1}}} =
             Processor.decode_validate_source_response(
               source_response,
               plan,
               Keyword.put(opts(), :max_input_pixels, 1)
             )

    assert pixel_count > 1
  end

  test "decode_validate_source_response rejects SVG after decode" do
    if svg_supported?() do
      source_response = %Response{stream: [svg_body(20, 20)]}

      assert {:error, {:unsupported_source_format, :svg}} =
               Processor.decode_validate_source_response(
                 source_response,
                 plan(),
                 opts()
               )
    end
  end

  test "unsupported decoded source format is reported before input pixel limits" do
    if svg_supported?() do
      source_response = %Response{stream: [svg_body(10_000, 10_000)]}

      assert {:error, {:unsupported_source_format, :svg}} =
               Processor.decode_validate_source_response(
                 source_response,
                 plan(),
                 Keyword.put(opts(), :max_input_pixels, 1)
               )
    end
  end

  test "deferred source stream errors remain source errors during decode" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, DecodeRaisesSourceStreamError)
             )
  end
end
