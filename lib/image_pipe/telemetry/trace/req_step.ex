defmodule ImagePipe.Telemetry.Trace.ReqStep do
  @moduledoc """
  Req steps that trace an outbound HTTP call as a logical client span, inject a W3C
  `traceparent` header, and stamp `finch_private` so `ImagePipe.Telemetry.Trace.FinchCapture`
  can attach physical wire spans under the same parent. Apply where the source builds
  its Req client (`req |> ReqStep.attach() |> Req.request(...)`).

  ## Active-exporter coupling (not the stack)

  The request step reads `ImagePipe.Telemetry.Trace.Stack.context/0` for its parent, but the
  response/error steps emit through the *active exporter* (`ImagePipe.Telemetry.Trace.exporter/0`)
  directly, NOT through the per-process span stack. Req's response/error steps may run in a
  different process (or with a different active span) than the request step, so the parent
  identity is carried in the request's private state rather than read back off the stack.

  ## No-op when no tracer is attached

  When `ImagePipe.Telemetry.Trace.exporter/0` is `nil` (no tracer attached), the steps emit
  nothing. The header injection and `finch_private` stamp are cheap and harmless, so attaching
  `ReqStep` is safe to do unconditionally at the build site — a source fetch behaves identically
  whether or not a tracer is attached.

  ## `into: :self` timing caveat

  The source streams the body with `into: :self`, so Req's response step (and thus this span's
  stop) fires at **status + headers received**, not when the body finishes downloading. The
  logical client span's duration therefore covers connect + TTFB, not the full transfer. The
  captured status is correct.
  """
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.{Context, Id, Span, Stack, W3C}

  # Finch-private key: shared contract with FinchCapture, which reads this atom from
  # request.private to parent wire spans under the logical client span we stamp here.
  @priv :image_pipe_trace

  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = req) do
    req
    |> Req.Request.append_request_steps(image_pipe_trace_start: &start/1)
    |> Req.Request.prepend_response_steps(image_pipe_trace_stop: &stop/1)
    |> Req.Request.append_error_steps(image_pipe_trace_error: &error/1)
  end

  defp start(%Req.Request{} = req) do
    span_id = Id.span_id()
    parent = Stack.context()

    {trace_id, flags} =
      case parent do
        %Context{trace_id: trace_id, trace_flags: flags} -> {trace_id, flags}
        # No parent: mint a fresh trace, default sampled (flags=1).
        nil -> {Id.trace_id(), 1}
      end

    req
    |> Req.Request.put_header("traceparent", W3C.encode(trace_id, span_id, flags))
    |> Req.Request.put_private(@priv, {trace_id, span_id, System.system_time(), parent})
    |> Req.merge(finch_private: %{@priv => {trace_id, span_id}})
  end

  defp stop({%Req.Request{} = req, %Req.Response{status: status} = resp}) do
    emit(req, %{"http.status_code": status}, :ok)
    {req, resp}
  end

  defp error({%Req.Request{} = req, exception}) do
    emit(req, %{"http.error": inspect(exception)}, :error)
    {req, exception}
  end

  defp emit(%Req.Request{} = req, attributes, status) do
    case {Trace.exporter(), Req.Request.get_private(req, @priv)} do
      {nil, _private} ->
        :ok

      {_exporter, nil} ->
        :ok

      {exporter, {trace_id, span_id, start_time, parent}} ->
        exporter.export(%Span{
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: parent && parent.span_id,
          name: "image_pipe.http.client",
          kind: :client,
          start_time: start_time,
          end_time: System.system_time(),
          status: status,
          attributes: attributes,
          pid: self(),
          node: node()
        })

        :ok
    end
  rescue
    # A tracer must never crash the request path; drop the span on any exporter error.
    _ -> :ok
  end
end
