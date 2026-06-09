defmodule ImagePipe.Telemetry.Trace.CrossProcessTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{Span, TestExporter}
  alias ImgproxyWireConformanceTest.CacheProbe

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  defp collect(timeout \\ 300) do
    receive do
      {:span, %Span{} = s} -> [s | collect(timeout)]
    after
      timeout -> []
    end
  end

  defp call(path, opts) do
    conn = conn(:get, path)
    ImagePipe.Plug.call(conn, ImagePipe.Plug.init(opts))
  end

  # A cache-miss request that fetches + decodes a real source and writes to cache.
  # CacheProbe(result: :miss) drives open_sink -> write_chunk -> commit_sink, so the
  # [:cache, :write] span fires from the SourceSession process (hop A target).
  defp miss_opts do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test",
           req_options: [plug: ImgproxyWireConformanceTest.OriginImage]}
      ],
      cache: {CacheProbe, result: :miss}
    ]
  end

  defp request_path, do: "/_/rs:fit:120:90/f:jpeg/plain/images/beach.jpg"

  test "producer-process spans share the request trace_id and parent under it (hop B)" do
    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    spans = collect()
    root = Enum.find(spans, &(&1.name == "image_pipe.request"))
    fetch = Enum.find(spans, &(&1.name == "image_pipe.source.fetch_decode"))

    assert root && fetch, "expected request + source.fetch_decode spans"
    assert fetch.trace_id == root.trace_id
    refute fetch.parent_span_id == nil
  end
end
