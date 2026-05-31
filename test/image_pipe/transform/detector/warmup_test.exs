defmodule ImagePipe.Transform.Detector.WarmupTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.Warmup

  defmodule SignalDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def detect(_i, _o), do: {:ok, []}
    @impl true
    def available?(_o), do: true
    @impl true
    def identity(_o), do: {__MODULE__, :v}
    @impl true
    def warmup(opts) do
      pid = Keyword.fetch!(opts, :test_pid)
      send(pid, {:warm_started, self(), Keyword.get(opts, :classes)})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  defmodule UnavailableDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def detect(_i, _o), do: {:error, :unavailable}
    @impl true
    def available?(_o), do: false
    @impl true
    def identity(_o), do: {__MODULE__, :unavailable}
    @impl true
    def warmup(_opts), do: {:error, {:detector, :unavailable}}
  end

  test "async warmup does not block start and terminates :normal" do
    pid =
      start_supervised!(
        {Warmup, detector: SignalDetector, classes: ["face"], opts: [test_pid: self()]}
      )

    ref = Process.monitor(pid)
    # start_supervised! returned before warmup completed (it's still blocked in receive):
    assert_receive {:warm_started, worker_pid, ["face"]}
    send(worker_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "unavailable detector is a clean no-op that still terminates :normal" do
    pid =
      start_supervised!({Warmup, detector: UnavailableDetector, classes: ["face"], opts: []})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "nil detector disables warmup as a clean no-op" do
    pid = start_supervised!({Warmup, detector: nil, classes: ["face"]})

    ref = Process.monitor(pid)
    # The no-op finishes immediately; if it already terminated before we
    # monitored, the monitor reports :noproc. Either way it ended cleanly — a
    # never-raising worker under :transient would have been restarted otherwise.
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
  end

  test "omitted :detector defaults to :default and terminates cleanly" do
    # :default resolves to the bundled adapter via the Transform facade; in the
    # default test lane it is unavailable, so warmup is a clean no-op.
    pid = start_supervised!({Warmup, classes: ["face"]})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
  end
end
