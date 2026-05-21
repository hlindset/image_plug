defmodule ImagePlug.Request.SourceStreamBoundaryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.SourceStreamBoundary
  alias ImagePlug.Source
  alias ImagePlug.Source.Response

  defmodule LinkedReaderImageOpen do
    alias ImagePlug.Source

    def open(stream) do
      pid = spawn_link(fn -> Enum.to_list(stream) end)

      receive do
        {:EXIT, ^pid, {%Source.StreamError{reason: :stream_exception}, _stacktrace} = reason} ->
          exit(reason)

        {:EXIT, ^pid, %Source.StreamError{reason: :stream_exception} = reason} ->
          exit(reason)
      after
        1_000 -> raise "linked reader did not exit from source stream error"
      end
    end
  end

  defmodule BlockingWorker do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl GenServer
    def init(test_pid), do: {:ok, test_pid}

    @impl GenServer
    def handle_call(:run_boundary, _from, test_pid) do
      SourceStreamBoundary.run(fn ->
        send(test_pid, {:boundary_worker, self()})

        receive do
          :continue -> {:ok, :done}
        end
      end)

      {:reply, :done, test_pid}
    end
  end

  test "direct source stream errors return source errors" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             SourceStreamBoundary.run(fn ->
               Enum.to_list(response.stream)
               {:ok, :should_not_reach}
             end)
  end

  test "linked source stream exits return source errors without exiting the caller" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             SourceStreamBoundary.run(fn ->
               LinkedReaderImageOpen.open(response.stream)
             end)
  end

  test "caller trap_exit flag is preserved" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:ok, :done} = SourceStreamBoundary.run(fn -> {:ok, :done} end)
      assert Process.flag(:trap_exit, true)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "caller trap_exit false flag is preserved" do
    previous = Process.flag(:trap_exit, false)

    try do
      assert {:ok, :done} = SourceStreamBoundary.run(fn -> {:ok, :done} end)
      refute Process.flag(:trap_exit, false)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "worker exits when caller exits" do
    pid = start_supervised!({BlockingWorker, self()})

    caller =
      spawn(fn ->
        GenServer.call(pid, :run_boundary, :infinity)
      end)

    assert_receive {:boundary_worker, worker}
    worker_ref = Process.monitor(worker)

    try do
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}
    after
      Process.exit(worker, :kill)
      Process.exit(caller, :kill)
    end
  end

  test "non-source linked exits are not converted to source errors" do
    assert catch_exit(
             SourceStreamBoundary.run(fn ->
               pid = spawn_link(fn -> exit(:non_source_failure) end)

               receive do
                 {:EXIT, ^pid, :non_source_failure} -> exit(:non_source_failure)
               after
                 1_000 -> raise "linked process did not exit"
               end
             end)
           ) == :non_source_failure
  end
end
