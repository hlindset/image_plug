defmodule ImagePipe.Telemetry.Trace.W3C do
  @moduledoc false
  alias ImagePipe.Telemetry.Trace.Context

  @all_zero_trace String.duplicate("0", 32)
  @all_zero_span String.duplicate("0", 16)

  @spec encode(String.t(), String.t(), non_neg_integer()) :: String.t()
  def encode(trace_id, span_id, flags \\ 1) do
    "00-" <> trace_id <> "-" <> span_id <> "-" <> flags_hex(flags)
  end

  @spec decode(String.t()) :: {:ok, Context.t()} | :error
  def decode("00-" <> rest) do
    with [t, s, f] <- String.split(rest, "-"),
         true <- valid_trace?(t),
         true <- valid_span?(s),
         {:ok, flags} <- parse_flags(f) do
      {:ok,
       %Context{trace_id: String.downcase(t), span_id: String.downcase(s), trace_flags: flags}}
    else
      _ -> :error
    end
  end

  def decode(_), do: :error

  defp valid_trace?(t),
    do: byte_size(t) == 32 and hex?(t) and String.downcase(t) != @all_zero_trace

  defp valid_span?(s), do: byte_size(s) == 16 and hex?(s) and String.downcase(s) != @all_zero_span

  defp parse_flags(f) when byte_size(f) == 2 do
    case Integer.parse(f, 16) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_flags(_), do: :error

  defp flags_hex(flags) do
    flags |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(2, "0")
  end

  defp hex?(s), do: String.match?(s, ~r/\A[0-9a-fA-F]+\z/)
end
