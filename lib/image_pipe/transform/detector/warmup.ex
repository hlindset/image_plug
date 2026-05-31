defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  Optional one-shot worker that pre-loads a detector's models at boot.

  Host-wired: add it to the HOST's supervision tree (ImagePipe does not start
  it), e.g.:

      {ImagePipe.Transform.Detector.Warmup,
       detector: ImagePipe.Transform.Detector.ImageVision, classes: ["face"], mode: :async}

  `restart: :transient` — it warms once and terminates `:normal`, so the
  supervisor does not restart it. It does NOT trap exits: a shutdown mid-download
  is acceptable (nothing is staged to clean up). A failed warmup logs and retries
  in-process a bounded number of times, then terminates `:normal` — it never
  raises (a raised exit under `:transient` would restart-storm).

  The worker runs the blocking model load inside `handle_continue/2`, so
  `start_link/1` returns immediately and the host's boot is never blocked. The
  `mode: :async` option is accepted for forward-compatibility; the worker is
  non-blocking for the host regardless.
  """
  use GenServer, restart: :transient

  require Logger

  alias ImagePipe.Transform.Detector

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      detector: Keyword.fetch!(opts, :detector),
      classes: Keyword.get(opts, :classes, ["face"]),
      opts: Keyword.get(opts, :opts, []),
      retries: Keyword.get(opts, :retries, 2)
    }

    {:ok, state, {:continue, :warm_then_stop}}
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    warm(state, state.retries)
    {:stop, :normal, state}
  end

  defp warm(_state, retries) when retries < 0, do: :ok

  defp warm(state, retries) do
    case Detector.warmup(state.detector, Keyword.put(state.opts, :classes, state.classes)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImagePipe detector warmup failed (#{inspect(reason)}); #{retries} retries left"
        )

        warm(state, retries - 1)
    end
  end
end
