defmodule ImagePlug.Request.SourceSession.ProducerTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession.Producer
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  @event_target __MODULE__.StreamEvents

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSession.ProducerTest.StreamEvents

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

  defmodule RaisingAfterFirstChunkImage do
    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _state -> :ok end
      )
    end
  end

  defmodule BlockingImage do
    @event_target ImagePlug.Request.SourceSession.ProducerTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :second}

          :second ->
            if target = Process.whereis(@event_target) do
              send(target, {:producer_blocked, self()})
            end

            receive do
              :continue -> {["second chunk"], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:blocking_stream_finalized, state})
          end
        end
      )
    end
  end

  setup do
    Process.flag(:trap_exit, true)

    if Process.whereis(@event_target) do
      Process.unregister(@event_target)
    end

    Process.register(self(), @event_target)

    on_exit(fn ->
      if Process.whereis(@event_target) do
        Process.unregister(@event_target)
      end
    end)

    :ok
  end

  test "producer returns first chunk, later chunks, and done on demand" do
    producer = start_producer(request(opts: opts(image_module: MultiChunkImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], resolved_output}} =
             Producer.next(producer)

    assert resolved_output.format == :jpeg
    assert {:ok, {:chunk, "second chunk"}} = Producer.next(producer)
    assert {:ok, :done} = Producer.next(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer halt runs the suspended stream cleanup callback when idle" do
    producer = start_producer(request(opts: opts(image_module: CleanupStreamImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    assert :ok = Producer.halt(producer)
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer returns post-first-chunk encoder errors" do
    producer = start_producer(request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             Producer.next(producer)

    assert is_list(stacktrace)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer can be stopped while a demand is blocked" do
    producer = start_producer(request(opts: opts(image_module: BlockingImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    parent = self()

    caller =
      start_test_process(fn ->
        send(parent, {:next_result, Producer.next(producer, 5_000)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:producer_blocked, ^producer}
    Process.exit(producer, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^producer, :shutdown}
    assert_receive {:next_result, {:error, {:producer, {:exit, :shutdown}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  defp start_producer(%Request{} = request) do
    caller_chain = [self()]

    start_supervised!(%{
      id: {Producer, make_ref()},
      start: {Producer, :start_link, [request, [caller_chain: caller_chain]]},
      restart: :temporary,
      shutdown: 2_000,
      type: :worker
    })
  end

  defp start_test_process(fun) when is_function(fun, 0) do
    supervisor =
      start_supervised!(%{
        id: {Task.Supervisor, make_ref()},
        start: {Task.Supervisor, :start_link, [[name: nil]]},
        restart: :temporary,
        type: :supervisor
      })

    {:ok, pid} = Task.Supervisor.start_child(supervisor, fun)
    pid
  end

  defp request(opts: runtime_opts) do
    %Request{
      plan: plan(),
      resolved_source: resolved_source(),
      output_policy:
        Policy.from_output_plan(
          Plug.Test.conn(:get, "/"),
          %Output{mode: {:explicit, :jpeg}},
          runtime_opts
        ),
      opts: runtime_opts,
      cache_key: nil
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source(fetch \\ {:ok, image_body()}) do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      fetch: fetch,
      cache: :normal
    }
  end

  defp opts(extra) do
    Keyword.merge(
      [
        sources: %{path: {ValidAdapter, []}},
        image_module: MultiChunkImage,
        output_formats: [jpeg: []],
        output_negotiation: []
      ],
      extra
    )
  end

  defp image_body do
    File.read!("priv/static/images/beach.jpg")
  end
end
