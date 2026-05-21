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
        send(caller, {ref, self(), run_worker(caller, fun)})
      end)

    receive do
      {^ref, ^pid, {:ok, result}} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {^ref, ^pid, {:raise, kind, reason, stacktrace}} ->
        Process.demonitor(monitor_ref, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp run_worker(caller, fun) do
    caller_watch = start_caller_watch(caller)
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      result =
        fun.()
        |> receive_linked_exit()

      {:ok, result}
    rescue
      exception in [Source.StreamError] ->
        {:ok, {:error, {:source, exception.reason}}}

      exception ->
        {:raise, :error, exception, __STACKTRACE__}
    catch
      :exit, reason ->
        handle_exit(reason, __STACKTRACE__)

      kind, reason ->
        {:raise, kind, reason, __STACKTRACE__}
    after
      Process.flag(:trap_exit, trap_exit?)
      stop_caller_watch(caller_watch)
    end
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

  defp handle_exit({%Source.StreamError{reason: reason}, _stacktrace}, _exit_stacktrace),
    do: {:ok, {:error, {:source, reason}}}

  defp handle_exit(%Source.StreamError{reason: reason}, _exit_stacktrace),
    do: {:ok, {:error, {:source, reason}}}

  defp handle_exit(reason, exit_stacktrace), do: {:raise, :exit, reason, exit_stacktrace}

  defp start_caller_watch(caller) do
    worker = self()
    ready_ref = make_ref()

    watcher =
      spawn(fn ->
        ref = Process.monitor(caller)
        send(worker, {ready_ref, :caller_watch_ready})

        receive do
          :stop ->
            Process.demonitor(ref, [:flush])

          {:DOWN, ^ref, :process, ^caller, _reason} ->
            Process.exit(worker, :kill)
        end
      end)

    receive do
      {^ready_ref, :caller_watch_ready} -> watcher
    end
  end

  defp stop_caller_watch(caller_watch) do
    send(caller_watch, :stop)
    :ok
  end
end
