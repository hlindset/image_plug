defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  Optional one-shot worker that pre-loads a detector's models at boot.

  Host-wired: add it to the HOST's supervision tree (ImagePipe does not start
  it), e.g.:

      {ImagePipe.Transform.Detector.Warmup, detector: :default}

  The `:detector` option mirrors the plug's `:detector` option: `:default` (the
  default when omitted) resolves to the bundled adapter, `nil` disables detection
  (the worker becomes a clean no-op), and a module selects a custom detector.

  `restart: :transient` — it warms once and terminates `:normal`, so the
  supervisor does not restart it. It does NOT trap exits: a shutdown mid-download
  is acceptable (nothing is staged to clean up). A failed warmup logs and retries
  in-process a bounded number of times with exponential backoff (so a transient
  blip — e.g. a model download hiccup — gets a real chance to recover and the
  retry warnings aren't a same-instant burst), then terminates `:normal` — it
  never raises (a raised exit under `:transient` would restart-storm). A detector
  whose `available?/1` is `false` is structurally unavailable, so warmup is
  skipped entirely (no point retrying a failure that cannot recover).

  The worker runs the blocking model load inside `handle_continue/2`, so
  `start_link/1` returns immediately and the host's boot is never blocked.
  """
  use GenServer, restart: :transient

  require Logger

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector

  # Exponential backoff between failed-warmup retries: 100ms, 200ms, 400ms, …
  # capped at 1s. Bounded and non-blocking relative to host boot (the work runs
  # in handle_continue/2).
  @backoff_base_ms 100
  @backoff_cap_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      detector: Keyword.get(opts, :detector, :default),
      classes: Keyword.get(opts, :classes, :all),
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

  defp warm(state, module, retries) do
    opts = Keyword.put(state.opts, :classes, state.classes)

    if module.available?(opts) do
      attempt(state, module, opts, retries)
    else
      Logger.warning("ImagePipe detector warmup skipped: #{inspect(module)} is unavailable")
      :ok
    end
  end

  defp attempt(_state, _module, _opts, retries) when retries < 0, do: :ok

  defp attempt(state, module, opts, retries) do
    case Detector.warmup(module, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImagePipe detector warmup failed (#{inspect(reason)}); #{retries} retries left"
        )

        if retries > 0, do: Process.sleep(backoff_ms(state.retries - retries))
        attempt(state, module, opts, retries - 1)
    end
  end

  defp backoff_ms(prior_failures) do
    min(@backoff_cap_ms, @backoff_base_ms * Integer.pow(2, prior_failures))
  end
end
