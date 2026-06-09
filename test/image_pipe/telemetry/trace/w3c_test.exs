defmodule ImagePipe.Telemetry.Trace.W3CTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Telemetry.Trace.{Context, Id, W3C}

  test "encode produces a valid W3C traceparent" do
    tp = W3C.encode("0af7651916cd43dd8448eb211c80319c", "b7ad6b7169203331", 1)
    assert tp == "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
  end

  test "round-trips a freshly generated context" do
    tid = Id.trace_id()
    sid = Id.span_id()
    assert {:ok, %Context{trace_id: ^tid, span_id: ^sid, trace_flags: 1}} =
             tid |> W3C.encode(sid, 1) |> W3C.decode()
  end

  test "decode rejects malformed input" do
    assert W3C.decode("garbage") == :error
    assert W3C.decode("00-short-b7ad6b7169203331-01") == :error
    assert W3C.decode("00-" <> String.duplicate("0", 32) <> "-b7ad6b7169203331-01") == :error
    assert W3C.decode("00-0af7651916cd43dd8448eb211c80319c-" <> String.duplicate("0", 16) <> "-01") == :error
    assert W3C.decode("") == :error
  end
end
