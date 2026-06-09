defmodule ImagePipe.Telemetry.Trace.EncodeSpanTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}

  # [:encode] is emitted by ImagePipe.Response.Sender.send_prepared_stream/5 around
  # the prepared-stream materialize+send. It is a real Telemetry.span stage and must
  # be captured by the tracer, nested under the request trace.

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp collect_spans(timeout \\ 200) do
    receive do
      {:span, %Span{} = s} -> [s | collect_spans(timeout)]
    after
      timeout -> []
    end
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  defp parent_of(spans, %Span{parent_span_id: pid}),
    do: Enum.find(spans, &(&1.span_id == pid))

  defp beach_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ]
    ]
  end

  test "the encode span is captured and nested under the request trace" do
    conn = call("/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg", beach_opts())
    assert conn.status == 200

    spans = collect_spans()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    assert root, "expected a request root span"

    assert [encode] = Enum.filter(spans, &(&1.name == "image_pipe.encode"))

    assert encode.trace_id == root.trace_id
    refute encode.parent_span_id == nil, "encode span must not be an orphan"

    # Sender.send_prepared_stream/5 emits [:encode] synchronously in the Plug request
    # process, inside Sender.send_result, which runs inside the [:send] span
    # (Plug.send_response/4). So encode nests under [:send], which nests under [:request].
    parent = parent_of(spans, encode)
    assert parent, "encode span must have a captured parent"
    assert parent.name == "image_pipe.send"
    assert parent.pid == encode.pid, "encode and its [:send] parent run in the same process"

    grandparent = parent_of(spans, parent)
    assert grandparent && grandparent.name == "image_pipe.request"
  end
end
