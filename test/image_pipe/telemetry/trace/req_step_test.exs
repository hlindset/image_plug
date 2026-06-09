defmodule ImagePipe.Telemetry.Trace.ReqStepTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{ReqStep, Span, TestExporter}

  setup do
    TestExporter.set_receiver(self())
    :ok = TestExporter.attach(self())

    on_exit(fn ->
      Telemetry.detach_tracer()
      TestExporter.clear_receiver()
    end)

    :ok
  end

  test "injects traceparent and emits a logical client span with status" do
    # Open a parent span so the client span has a trace to attach to.
    Telemetry.span([], [:request], %{}, fn ->
      req =
        Req.new(
          adapter: fn req ->
            assert [tp] = Req.Request.get_header(req, "traceparent")
            assert tp =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/
            {req, Req.Response.new(status: 200, body: "ok")}
          end
        )
        |> ReqStep.attach()

      {:ok, _} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.attributes[:"http.status_code"] == 200
  end

  test "emits a client span with status :error on transport error" do
    Telemetry.span([], [:request], %{}, fn ->
      req =
        Req.new(
          adapter: fn req ->
            {req, %Mint.TransportError{reason: :timeout}}
          end
        )
        |> ReqStep.attach()

      {:error, _exception} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    assert_receive {:span, %Span{name: "image_pipe.http.client", kind: :client} = s}
    assert s.status == :error
    assert Map.has_key?(s.attributes, :"http.error")
  end

  test "is a harmless no-op when no tracer is attached" do
    Telemetry.detach_tracer()

    Telemetry.span([], [:request], %{}, fn ->
      req =
        Req.new(
          adapter: fn req ->
            # traceparent is still injected (cheap, header only); span just is not emitted.
            assert [_tp] = Req.Request.get_header(req, "traceparent")
            {req, Req.Response.new(status: 200, body: "ok")}
          end
        )
        |> ReqStep.attach()

      {:ok, %Req.Response{status: 200}} = Req.request(req)
      {:ok, %{result: :ok}}
    end)

    refute_receive {:span, %Span{name: "image_pipe.http.client"}}
  end
end
