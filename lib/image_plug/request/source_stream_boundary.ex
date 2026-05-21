defmodule ImagePlug.Request.SourceStreamBoundary do
  @moduledoc false

  alias ImagePlug.Source

  @spec run((-> term())) :: term()
  def run(fun) when is_function(fun, 0) do
    caller = self()
    callers = [caller | Process.get(:"$callers", [])]
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        send(caller, {ref, self(), run_worker(fun)})
      end)

    receive do
      {^ref, ^pid, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp run_worker(fun) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
      |> receive_linked_exit()
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  rescue
    exception in [Source.StreamError] ->
      {:error, {:source, exception.reason}}
  catch
    :exit, reason ->
      handle_exit(reason)
  end

  defp receive_linked_exit(result) do
    receive do
      {:EXIT, _pid, {%Source.StreamError{reason: reason}, _stacktrace}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, %Source.StreamError{reason: reason}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, :normal} ->
        receive_linked_exit(result)

      {:EXIT, _pid, reason} ->
        exit(reason)
    after
      0 -> result
    end
  end

  defp handle_exit({%Source.StreamError{reason: reason}, _stacktrace}),
    do: {:error, {:source, reason}}

  defp handle_exit(%Source.StreamError{reason: reason}), do: {:error, {:source, reason}}

  defp handle_exit(reason), do: exit(reason)
end
