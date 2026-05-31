defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  Optional one-shot worker that pre-loads a detector's models at boot.

  Host-wired: add it to the HOST's supervision tree (ImagePipe does not start
  it), e.g.:

      {ImagePipe.Transform.Detector.Warmup, detector: :default, classes: ["face"]}

  The `:detector` option mirrors the plug's `:detector` option: `:default` (the
  default when omitted) resolves to the bundled adapter, `nil` disables detection
  (the worker becomes a clean no-op), and a module selects a custom detector.

  `restart: :transient` — it warms once and terminates `:normal`, so the
  supervisor does not restart it. It does NOT trap exits: a shutdown mid-download
  is acceptable (nothing is staged to clean up). A failed warmup logs and retries
  in-process a bounded number of times, then terminates `:normal` — it never
  raises (a raised exit under `:transient` would restart-storm).

  The worker runs the blocking model load inside `handle_continue/2`, so
  `start_link/1` returns immediately and the host's boot is never blocked.
  """
  use GenServer, restart: :transient

  require Logger

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      detector: Keyword.get(opts, :detector, :default),
      classes: Keyword.get(opts, :classes, ["face"]),
      opts: Keyword.get(opts, :opts, []),
      retries: Keyword.get(opts, :retries, 2)
    }

    {:ok, state, {:continue, :warm_then_stop}}
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    case Transform.resolve_detector(state.detector) do
      nil -> :ok
      module -> warm(state, module, state.retries)
    end

    {:stop, :normal, state}
  end

  defp warm(_state, _module, retries) when retries < 0, do: :ok

  defp warm(state, module, retries) do
    case Detector.warmup(module, Keyword.put(state.opts, :classes, state.classes)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImagePipe detector warmup failed (#{inspect(reason)}); #{retries} retries left"
        )

        warm(state, module, retries - 1)
    end
  end
end
