defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry

  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "logs a cache lookup hit at the configured level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "escalates error outcomes to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :write, :stop],
          %{duration: 1000},
          %{result: :cache_error, cache: :write_error, error: :boom}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "cache write"
  end

  test "renders exception events as exceptions at warning level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :source, :fetch, :exception],
          %{duration: 1000},
          %{kind: :error, reason: :boom, stacktrace: []}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "exception"
  end

  test "escalates a configured-detector fallback (:unavailable) to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :stop],
          %{duration: 1000},
          %{classes: ["face"], regions: 0, result: :unavailable}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform detect: unavailable"
  end

  test "logs the face-assist blend one-shot at base level, showing the saliency skew" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :blend],
          %{},
          %{attention: {0.5, 0.5}, face: {0.2, 0.8}, blended: {0.29, 0.71}, weight: 0.7}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform detect blend: attention (0.5,0.5) -> (0.29,0.71)"
    assert log =~ "weight 0.7"
  end

  test "logs the no-detector skipped one-shot at warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :skipped],
          %{},
          %{classes: ["face"], result: :no_detector}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "transform detect: skipped (no detector configured)"
  end

  test "logs a normal no-face detect fallback at the base level, not warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :detect, :stop],
          %{duration: 1000},
          %{classes: ["face"], regions: 0, result: :no_regions}
        )
      end)

    refute log =~ "[warning]"
    assert log =~ "transform detect: no_regions"
  end

  test "renders a transform operation with name and index" do
    Telemetry.attach_default_logger(level: :debug)

    # capture at :debug explicitly so the test does not depend on the ambient
    # Logger level.
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 500},
          %{operation: :resize, index: 0, params: %{}, result: :ok}
        )
      end)

    assert log =~ "transform: resize (#1)"
  end

  test "renders the transform execute aggregate with outcome and operation count" do
    Telemetry.attach_default_logger(level: :debug)

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :execute, :stop],
          %{duration: 500},
          %{result: :ok, operations: [:resize, :flip], operation_count: 2}
        )
      end)

    assert log =~ "transform execute: ok (2 ops)"
  end

  test "rejects an invalid log level" do
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(level: :nope) end
  end

  test ":events filter excludes other groups" do
    Telemetry.attach_default_logger(level: :info, events: [:cache])

    log =
      capture_log(fn ->
        # transform group not attached -> nothing logged
        :telemetry.execute([:image_pipe, :transform, :execute, :stop], %{duration: 1}, %{
          result: :ok
        })
      end)

    refute log =~ "transform"
  end

  test ":debug true logs the raw payload including high-cardinality fields" do
    Telemetry.attach_default_logger(level: :debug, debug: true)

    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 1},
          %{operation: :resize, index: 0, params: %{magic: 12_345}, result: :ok}
        )
      end)

    assert log =~ "raw:"
    assert log =~ "12345"
  end

  test ":prefix attaches under a custom event prefix" do
    Telemetry.attach_default_logger(level: :info, events: [:cache], prefix: [:my_app, :images])

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:my_app, :images, :cache, :lookup, :stop],
          %{duration: 1},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "rejects unknown options, bad event groups, a non-list prefix, and a non-boolean debug" do
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(bogus: true) end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(events: [:nope]) end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(prefix: "nope") end
    assert_raise ArgumentError, fn -> Telemetry.attach_default_logger(debug: :yes) end
  end
end
