defmodule ImagePlug.Request.SourceSessionSupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Request.SourceSessionSupervisor
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSessionSupervisorTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule BlockingFetchAdapter do
    @behaviour ImagePlug.Source

    alias ImagePlug.Source.Resolved

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

    @impl ImagePlug.Source
    def fetch(%Resolved{fetch: {:block, test_pid}}, _opts, _runtime_opts) do
      send(test_pid, {:fetch_started, self()})

      receive do
        :release_fetch -> {:error, {:source, :released}}
      end
    end
  end

  test "start_session starts a temporary supervised source session" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request())

    assert_child_counts(supervisor, active: 1, workers: 1)
    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert_child_counts(supervisor, active: 0, workers: 0)
  end

  test "start_session defaults owner to the calling process" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    request = request(opts: opts(image_module: CleanupStreamImage))
    parent = self()

    owner =
      start_task!(fn ->
        {:ok, session} = SourceSessionSupervisor.start_session(supervisor, request)
        send(parent, {:session_started, self(), session})

        receive do
          :stop_owner -> :ok
        end
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:session_started, ^owner, session}, 1_000
    session_ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    assert_child_counts(supervisor, active: 0, workers: 0)
  end

  test "explicit owner death cleans up a supervised prepared session" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    owner = idle_owner!()

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage)),
               owner: owner
             )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
    assert_child_counts(supervisor, active: 0, workers: 0)
  end

  test "supervisor shutdown is parent shutdown, not request owner death" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage)),
               owner: self()
             )

    session_ref = Process.monitor(session)
    supervisor_ref = Process.monitor(supervisor)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    capture_log(fn ->
      Supervisor.stop(supervisor, :shutdown)
    end)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :shutdown}
  end

  test "supervised cancel finalizes the stream and removes the temporary child" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage))
             )

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert :ok = SourceSession.cancel(session)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert_child_counts(supervisor, active: 0, workers: 0)
  end

  test "stop_session gracefully finalizes a prepared stream" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage))
             )

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert :ok = SourceSessionSupervisor.stop_session(supervisor, session)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :shutdown}
    assert_child_counts(supervisor, active: 0, workers: 0)
  end

  test "stop_session is idempotent for non-child pids" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    other_pid =
      start_task!(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(other_pid)

    assert :ok = SourceSessionSupervisor.stop_session(supervisor, other_pid)

    send(other_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^other_pid, :normal}
  end

  test "temporary sessions are not restarted after a crash before prepare" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request(), owner: self())

    ref = Process.monitor(session)

    capture_log(fn ->
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    end)

    assert_child_counts(supervisor, active: 0, workers: 0)
    assert {:error, {:session, :noproc}} = SourceSession.prepare(session)
  end

  test "temporary sessions are not restarted after a crash after the first chunk" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(supervisor, request(), owner: self())

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    capture_log(fn ->
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, :killed}
    end)

    assert_child_counts(supervisor, active: 0, workers: 0)
    assert {:error, {:session, :noproc}} = SourceSession.next(session)
  end

  test "request owner timeout while prepare is blocked leaves cleanup to the supervisor facade" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    parent = self()

    owner =
      start_task!(fn ->
        {:ok, session} =
          SourceSessionSupervisor.start_session(supervisor, blocking_request(parent))

        send(parent, {:session_started, self(), session})
        send(parent, {:prepare_result, SourceSession.prepare(session, 100)})
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:session_started, ^owner, session}, 1_000
    session_ref = Process.monitor(session)
    assert_receive {:fetch_started, ^session}, 1_000
    assert_receive {:prepare_result, {:error, {:session, :timeout}}}, 1_000
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_child_counts(supervisor, active: 1)

    assert :ok = SourceSessionSupervisor.stop_session(supervisor, session)
    assert_receive {:DOWN, ^session_ref, :process, ^session, reason}
    assert reason in [:shutdown, :killed]
    assert_child_counts(supervisor, active: 0)
  end

  test "caller parent option cannot override the supervisor parent" do
    register_stream_events!()
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               request(opts: opts(image_module: CleanupStreamImage)),
               owner: self(),
               parent: self()
             )

    session_ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    capture_log(fn ->
      Supervisor.stop(supervisor, :shutdown)
    end)

    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}
  end

  test "parent shutdown during active prepare exits as controlled shutdown" do
    supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
    parent = self()

    assert {:ok, session} =
             SourceSessionSupervisor.start_session(
               supervisor,
               blocking_request(parent),
               owner: self()
             )

    session_ref = Process.monitor(session)

    _caller =
      start_task!(fn ->
        send(parent, {:prepare_result, SourceSession.prepare(session, 5_000)})
      end)

    assert_receive {:fetch_started, ^session}, 1_000

    send(session, {:EXIT, supervisor, :shutdown})
    send(session, :release_fetch)

    assert_receive {:prepare_result, {:error, {:session, {:exit, :shutdown}}}}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, ^session, :shutdown}
    assert_child_counts(supervisor, active: 0)
  end

  test "application starts the named source session supervisor" do
    assert {SourceSessionSupervisor, pid, :supervisor, [SourceSessionSupervisor]} =
             ImagePlug.Supervisor
             |> Supervisor.which_children()
             |> List.keyfind(SourceSessionSupervisor, 0)

    assert pid == Process.whereis(SourceSessionSupervisor)
  end

  defp request(overrides \\ []) do
    %Request{
      plan: Keyword.get(overrides, :plan, plan()),
      resolved_source: Keyword.get(overrides, :resolved_source, resolved_source()),
      output_policy: Keyword.get(overrides, :output_policy, output_policy()),
      opts: Keyword.get(overrides, :opts, opts())
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source(fetch \\ :fixture) do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      cache: :normal,
      fetch: fetch
    }
  end

  defp output_policy do
    %Policy{
      mode: {:explicit, :jpeg},
      modern_candidates: [],
      headers: [],
      quality: :default,
      format_qualities: %{}
    }
  end

  defp opts(extra_opts \\ []) do
    Keyword.merge(
      [sources: %{path: {ValidAdapter, []}}, image_module: MultiChunkImage],
      extra_opts
    )
  end

  defp blocking_request(test_pid) do
    request(
      resolved_source: %{resolved_source({:block, test_pid}) | fetch: {:block, test_pid}},
      opts: [sources: %{path: {BlockingFetchAdapter, []}}, image_module: MultiChunkImage]
    )
  end

  defp idle_owner! do
    start_task!(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)
  end

  defp start_task!(fun) when is_function(fun, 0) do
    start_supervised!({Task, fun}, id: make_ref())
  end

  defp assert_child_counts(supervisor, expected) do
    assert_child_counts(supervisor, expected, 20)
  end

  defp assert_child_counts(supervisor, expected, attempts) when attempts > 0 do
    :sys.get_state(supervisor)
    counts = DynamicSupervisor.count_children(supervisor)

    if counts_match?(counts, expected) do
      assert_counts(counts, expected)
    else
      assert_child_counts(supervisor, expected, attempts - 1)
    end
  end

  defp assert_child_counts(supervisor, expected, 0) do
    assert_counts(DynamicSupervisor.count_children(supervisor), expected)
  end

  defp counts_match?(counts, expected) do
    Enum.all?(expected, fn {key, value} -> Map.fetch!(counts, key) == value end)
  end

  defp assert_counts(counts, expected) do
    Enum.each(expected, fn {key, value} ->
      assert Map.fetch!(counts, key) == value
    end)
  end

  defp register_stream_events! do
    Process.register(self(), __MODULE__.StreamEvents)
  end
end
