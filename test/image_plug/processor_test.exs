defmodule ImagePlug.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Processor
  alias ImagePlug.Origin.StreamStatus
  alias ImagePlug.Transform.Output
  alias ImagePlug.TransformState

  defmodule OriginImage do
    def call(conn, _opts) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule DecodeErrorImageOpen do
    def open(_stream, _opts), do: {:error, :forced_decode_error}
  end

  defmodule SequentialFailingTransform do
    defstruct []

    def metadata(%__MODULE__{}), do: %{access: :sequential}

    def execute(state, %__MODULE__{}) do
      TransformState.add_error(state, {__MODULE__, :failed})
    end
  end

  defp request do
    %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat-300.jpg"]
    }
  end

  defp opts do
    [origin_req_options: [plug: OriginImage]]
  end

  test "process_origin fetches, decodes, validates, executes, and materializes a chain" do
    chain = [{Output, %Output.OutputParams{format: :jpeg}}]

    assert {:ok, %TransformState{} = state} =
             Processor.process_origin(
               request(),
               chain,
               "http://origin.test/images/cat-300.jpg",
               opts()
             )

    assert state.output == :jpeg
    assert state.errors == []
  end

  test "fetch_decode_validate_origin_with_source_format returns decoded origin context" do
    assert {:ok, %Processor.DecodedOrigin{} = decoded} =
             Processor.fetch_decode_validate_origin_with_source_format(
               request(),
               "http://origin.test/images/cat-300.jpg",
               [],
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
               request(),
               "http://origin.test/images/cat-300.jpg",
               [],
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
               [{SequentialFailingTransform, %SequentialFailingTransform{}}],
               opts()
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    StreamStatus.stop(stream_status)
  end
end
