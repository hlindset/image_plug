defmodule ImagePlug.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Processor
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
end
