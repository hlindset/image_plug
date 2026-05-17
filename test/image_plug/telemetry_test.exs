defmodule ImagePlug.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline

  defmodule OriginImage do
    def call(conn, _opts) do
      body = File.read!("priv/static/images/beach.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule InvalidOriginImage do
    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not actually a png")
    end
  end

  defmodule UnsupportedSourceParser do
    @behaviour ImagePlug.Parser

    @impl ImagePlug.Parser
    def parse(_conn, _opts), do: {:ok, ImagePlug.TelemetryTest.plan(source: :signed)}

    @impl ImagePlug.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule EmptyPipelineParser do
    @behaviour ImagePlug.Parser

    @impl ImagePlug.Parser
    def parse(_conn, _opts), do: {:ok, ImagePlug.TelemetryTest.plan(pipelines: [])}

    @impl ImagePlug.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule RaisingParser do
    @behaviour ImagePlug.Parser

    @impl ImagePlug.Parser
    def parse(_conn, _opts), do: raise("forced parser failure")

    @impl ImagePlug.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule CacheReadFailure do
    def get(_key, _opts), do: {:error, :read_failed}
    def put(_key, _entry, _opts), do: raise("cache read failure test should not write")
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

  setup do
    attach_telemetry(default_events() ++ custom_events())
  end

  test "emits request and representative stage spans for successful requests" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePlug.call(base_opts())

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:image_plug, :request, :start], fn measurements, metadata ->
      assert is_integer(measurements.system_time)
      assert metadata.parser == ImagePlug.Parser.Imgproxy
      assert metadata.request_method == "GET"
    end)

    assert_event(events, [:image_plug, :request, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
      assert metadata.status == 200
      assert metadata.parser == ImagePlug.Parser.Imgproxy
      assert metadata.request_method == "GET"
    end)

    for stage <- [
          [:parse],
          [:origin, :identity],
          [:cache, :lookup],
          [:output, :negotiate],
          [:origin, :fetch_decode],
          [:transform, :execute],
          [:encode],
          [:send]
        ] do
      assert_event(events, [:image_plug | stage] ++ [:start], fn measurements, _metadata ->
        assert is_integer(measurements.system_time)
      end)

      assert_event(events, [:image_plug | stage] ++ [:stop], fn measurements, metadata ->
        assert is_integer(measurements.duration)
        assert metadata.result == :ok
      end)
    end

    refute Enum.any?(events, fn {_event, _measurements, metadata} ->
             Map.has_key?(metadata, :request_path) or Map.has_key?(metadata, :path)
           end)
  end

  test "uses configurable telemetry prefix" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/beach.jpg")
      |> ImagePlug.call(Keyword.put(base_opts(), :telemetry_prefix, [:custom, :image]))

    assert conn.status == 200
    events = telemetry_events()

    assert_event(events, [:custom, :image, :request, :start], fn _measurements, metadata ->
      assert metadata.parser == ImagePlug.Parser.Imgproxy
    end)

    assert_event(events, [:custom, :image, :request, :stop], fn _measurements, metadata ->
      assert metadata.result == :ok
      assert metadata.status == 200
    end)

    assert_event(events, [:custom, :image, :parse, :start], fn measurements, _metadata ->
      assert is_integer(measurements.system_time)
    end)

    assert_event(events, [:custom, :image, :parse, :stop], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.result == :ok
    end)

    refute_event(events, [:image_plug, :request, :start])
    refute_event(events, [:image_plug, :request, :stop])
    refute_event(events, [:image_plug, :parse, :start])
    refute_event(events, [:image_plug, :parse, :stop])
  end

  test "encode stop metadata reports processing error after chunked stream failure" do
    {conn, log} =
      with_log(fn ->
        :get
        |> conn("/_/f:jpeg/plain/images/beach.jpg")
        |> ImagePlug.call(base_opts(image_module: RaisingAfterFirstChunkImage))
      end)

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "first chunk"
    assert log =~ "boom after first chunk"

    events = telemetry_events()

    assert_event(events, [:image_plug, :encode, :stop], fn _measurements, metadata ->
      assert metadata.result == :processing_error
      assert metadata.status == 200
      assert metadata.output_format == :jpeg
    end)
  end

  test "emits request stop metadata for failures that return responses" do
    cases = [
      parser: {
        conn(:get, "/_/w:300"),
        base_opts(),
        :parser_error,
        400
      },
      plan: {
        conn(:get, "/any"),
        opts(parser: EmptyPipelineParser),
        :plan_error,
        422
      },
      origin: {
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
        opts(root_url: "not a url"),
        :origin_error,
        502
      },
      cache: {
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
        opts(cache: {CacheReadFailure, fail_on_cache_error: true}),
        :cache_error,
        500
      },
      processing: {
        conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
        opts(origin_req_options: [plug: InvalidOriginImage]),
        :processing_error,
        415
      }
    ]

    for {name, {conn, opts, result, status}} <- cases do
      sent = ImagePlug.call(conn, opts)
      assert sent.status == status

      events = telemetry_events()

      assert_event(events, [:image_plug, :request, :stop], fn _measurements, metadata ->
        assert metadata.result == result
        assert metadata.status == status
      end)

      refute_event(events, [:image_plug, :request, :exception],
        message: "expected #{name} returned response not to emit request exception"
      )
    end
  end

  test "emits exception events only for real raised exceptions" do
    assert_raise RuntimeError, "forced parser failure", fn ->
      ImagePlug.call(conn(:get, "/any"), opts(parser: RaisingParser))
    end

    events = telemetry_events()

    assert_event(events, [:image_plug, :parse, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parser failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)

    assert_event(events, [:image_plug, :request, :exception], fn measurements, metadata ->
      assert is_integer(measurements.duration)
      assert metadata.kind == :error
      assert %RuntimeError{message: "forced parser failure"} = metadata.reason
      assert is_list(metadata.stacktrace)
    end)
  end

  test "validates telemetry prefix option at init" do
    assert ImagePlug.init(opts(telemetry_prefix: [:custom, :image]))[:telemetry_prefix] ==
             [:custom, :image]

    for prefix <- ["image_plug", [:image_plug, "request"], [], [:image_plug, 1]] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePlug options: invalid value for :telemetry_prefix option/,
                   fn -> ImagePlug.init(opts(telemetry_prefix: prefix)) end
    end
  end

  defp base_opts(overrides \\ []) do
    opts(
      Keyword.merge(
        [
          origin_req_options: [plug: OriginImage]
        ],
        overrides
      )
    )
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp opts(overrides) do
    Keyword.merge(
      [
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "http://origin.test"
      ],
      overrides
    )
  end

  def plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: {:plain, ["images", "beach.jpg"]},
          pipelines: [%Pipeline{operations: [resize_fit_operation()]}],
          output: %Output{mode: {:explicit, :jpeg}}
        ],
        overrides
      )
    )
  end

  defp resize_fit_operation do
    assert {:ok, operation} = Operation.resize(:fit, {:px, 100}, {:px, 100}, enlargement: :deny)
    operation
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp default_events do
    for stage <- stages(),
        suffix <- [:start, :stop, :exception],
        do: [:image_plug | stage] ++ [suffix]
  end

  defp custom_events do
    for stage <- stages(),
        suffix <- [:start, :stop, :exception],
        do: [:custom, :image | stage] ++ [suffix]
  end

  defp stages do
    [
      [:request],
      [:parse],
      [:origin, :identity],
      [:cache, :lookup],
      [:output, :negotiate],
      [:origin, :fetch_decode],
      [:transform, :execute],
      [:encode],
      [:cache, :write],
      [:send]
    ]
  end

  defp telemetry_events(events \\ []) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        telemetry_events([{event, measurements, metadata} | events])
    after
      0 ->
        Enum.reverse(events)
    end
  end

  defp assert_event(events, event, assertion) when is_function(assertion, 2) do
    case Enum.find(events, fn {candidate, _measurements, _metadata} -> candidate == event end) do
      {^event, measurements, metadata} ->
        assertion.(measurements, metadata)

      nil ->
        flunk("expected telemetry event #{inspect(event)}, got #{inspect(event_names(events))}")
    end
  end

  defp refute_event(events, event, opts \\ []) do
    message = Keyword.get(opts, :message, "unexpected telemetry event #{inspect(event)}")

    refute Enum.any?(events, fn {candidate, _measurements, _metadata} -> candidate == event end),
           message
  end

  defp event_names(events),
    do: Enum.map(events, fn {event, _measurements, _metadata} -> event end)
end
