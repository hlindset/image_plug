defmodule ImagePlug.Request.SourceSessionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

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

  defmodule EmptyStreamImage do
    def stream!(_image, suffix: ".jpg"), do: []
  end

  defmodule RaisingBeforeFirstChunkImage do
    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :raise end,
        fn :raise -> raise "boom before first chunk" end,
        fn _state -> :ok end
      )
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:raising_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule SourceErrorAfterFirstChunkImage do
    @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :raise}

          :raise ->
            raise ImagePlug.Source.StreamError, reason: :stream_exception
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:source_error_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule LinkedExitAfterFirstChunkImage do
    @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn ->
          helper =
            spawn_link(fn ->
              receive do
                :boom -> exit(:boom)
              end
            end)

          if target = Process.whereis(@event_target) do
            send(target, {:linked_exit_helper, helper})
          end

          :first
        end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:linked_exit_stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule StreamFetchAdapter do
    @behaviour ImagePlug.Source

    alias ImagePlug.Source.Response
    alias ImagePlug.Source.Resolved

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :not_used}}

    @impl ImagePlug.Source
    def fetch(%Resolved{fetch: {:stream, stream}}, _opts, _runtime_opts) do
      {:ok, %Response{stream: stream}}
    end
  end

  test "request struct carries source session inputs without Plug.Conn" do
    request = request()

    assert %Request{} = request
    assert %Plan{} = request.plan
    assert %ResolvedSource{} = request.resolved_source
    assert %Policy{} = request.output_policy
    assert is_list(request.opts)
    refute Map.has_key?(Map.from_struct(request), :conn)
  end

  test "prepared struct carries the first non-empty encoded chunk" do
    prepared = %Prepared{
      first_chunk: "first chunk",
      content_type: "image/jpeg",
      headers: [],
      resolved_output: resolved_output()
    }

    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.headers == []
  end

  test "prepare returns the first encoded chunk before next is called" do
    {:ok, session} = SourceSession.start(request())

    assert {:ok, %Prepared{} = prepared} = SourceSession.prepare(session)
    assert prepared.first_chunk == "first chunk"
    assert prepared.content_type == "image/jpeg"
    assert prepared.headers == []
    assert prepared.resolved_output.format == :jpeg
    assert :ok = SourceSession.cancel(session)
  end

  test "next returns one encoded chunk per call and then done" do
    {:ok, session} = SourceSession.start(request())

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:chunk, "second chunk"} = SourceSession.next(session)
    assert :done = SourceSession.next(session)
  end

  test "prepare and next exercise the real Image stream path" do
    {:ok, session} = SourceSession.start(request(opts: real_image_opts()))

    assert {:ok, %Prepared{first_chunk: first_chunk, content_type: "image/jpeg"}} =
             SourceSession.prepare(session)

    assert is_binary(first_chunk)
    assert byte_size(first_chunk) > 0

    case SourceSession.next(session) do
      {:chunk, chunk} ->
        assert is_binary(chunk)
        assert byte_size(chunk) > 0
        assert :ok = SourceSession.cancel(session)

      :done ->
        :ok
    end
  end

  test "cancel halts the suspended continuation and stops the session normally" do
    register_stream_events!()
    {:ok, session} = SourceSession.start(request(opts: opts(image_module: CleanupStreamImage)))
    ref = Process.monitor(session)

    assert {:ok, %Prepared{}} = SourceSession.prepare(session)
    assert :ok = SourceSession.cancel(session)
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "next before prepare returns a tagged protocol error" do
    {:ok, session} = SourceSession.start(request())

    assert {:error, {:protocol, :not_prepared}} = SourceSession.next(session)
    assert :ok = SourceSession.cancel(session)
  end

  test "call wrappers return tagged errors for missing sessions" do
    dead_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(dead_pid)
    send(dead_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead_pid, :normal}

    assert {:error, {:session, :noproc}} = SourceSession.prepare(dead_pid)
  end

  test "call wrappers return tagged timeout errors" do
    {:ok, session} = SourceSession.start(blocking_request(), owner: self())
    ref = Process.monitor(session)
    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:prepare_result, SourceSession.prepare(session, 100)})
      end)

    caller_ref = Process.monitor(caller)

    try do
      assert_receive {:fetch_started, ^session}, 1_000
      assert_receive {:prepare_result, {:error, {:session, :timeout}}}, 1_000
    after
      send(session, :release_fetch)
    end

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  test "owner death cancels the session once the active callback yields" do
    register_stream_events!()

    owner =
      spawn(fn ->
        receive do
          :stop_owner -> :ok
        end
      end)

    {:ok, session} =
      SourceSession.start(
        request(opts: opts(image_module: CleanupStreamImage)),
        owner: owner,
        parent: self()
      )

    session_ref = Process.monitor(session)
    owner_ref = Process.monitor(owner)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    send(owner, :stop_owner)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
  end

  test "source stream failures before the first chunk return source errors" do
    bad_stream = Stream.map([:raise], fn _ -> raise "raw stream failure" end)

    request =
      request(
        resolved_source: %{resolved_source({:stream, bad_stream}) | fetch: {:stream, bad_stream}},
        opts: [sources: %{path: {StreamFetchAdapter, []}}, image_module: MultiChunkImage]
      )

    {:ok, session} = SourceSession.start(request)
    ref = Process.monitor(session)

    capture_log(fn ->
      assert {:error, {:source, :stream_exception}} = SourceSession.prepare(session)
    end)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "empty encoder streams stay pre-response encode errors" do
    {:ok, session} = SourceSession.start(request(opts: opts(image_module: EmptyStreamImage)))
    ref = Process.monitor(session)

    assert {:error,
            {:encode, %RuntimeError{message: "image encoder produced an empty stream"}, []}} =
             SourceSession.prepare(session)

    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "encoder failures before the first chunk stay pre-response encode errors" do
    {:ok, session} =
      SourceSession.start(request(opts: opts(image_module: RaisingBeforeFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:error, {:encode, %RuntimeError{message: "boom before first chunk"}, stacktrace}} =
             SourceSession.prepare(session)

    assert is_list(stacktrace)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "encoder failures after the first chunk become next errors" do
    register_stream_events!()

    {:ok, session} =
      SourceSession.start(request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             SourceSession.next(session)

    assert is_list(stacktrace)
    assert_receive {:raising_stream_finalized, :raise}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "source stream errors during encoder reduction keep source phase" do
    register_stream_events!()

    {:ok, session} =
      SourceSession.start(request(opts: opts(image_module: SourceErrorAfterFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert {:error, {:source, :stream_exception}} = SourceSession.next(session)
    assert_receive {:source_error_stream_finalized, :raise}
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end

  test "abnormal linked exits halt the suspended stream before stopping the session" do
    register_stream_events!()

    {:ok, session} =
      SourceSession.start(request(opts: opts(image_module: LinkedExitAfterFirstChunkImage)))

    ref = Process.monitor(session)

    assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
    assert_receive {:linked_exit_helper, helper}

    capture_log(fn ->
      send(helper, :boom)

      assert_receive {:linked_exit_stream_finalized, :second}
      assert_receive {:DOWN, ^ref, :process, ^session, {:linked_exit, ^helper, :boom}}
    end)
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

  defp resolved_output do
    %Resolved{format: :jpeg, quality: :default, response_headers: []}
  end

  defp opts(extra_opts \\ []) do
    Keyword.merge(
      [sources: %{path: {ValidAdapter, []}}, image_module: MultiChunkImage],
      extra_opts
    )
  end

  defp real_image_opts do
    opts() |> Keyword.delete(:image_module)
  end

  defp blocking_request do
    request(
      resolved_source: %{resolved_source({:block, self()}) | fetch: {:block, self()}},
      opts: [sources: %{path: {BlockingFetchAdapter, []}}, image_module: MultiChunkImage]
    )
  end

  defp register_stream_events! do
    Process.register(self(), __MODULE__.StreamEvents)
  end
end
