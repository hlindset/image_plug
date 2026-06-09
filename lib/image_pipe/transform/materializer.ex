defmodule ImagePipe.Transform.Materializer do
  @moduledoc """
  Materialization boundary for transform execution.

  `materialize/1` delegates to `ImagePipe.Transform.OrientationFlush.flush/1`,
  which applies any pending orientation (EXIF auto-rotate plus user rotate/flip)
  before copying the current image to a RAM-resident buffer and marking the state
  `materialized?: true`. Materialization may therefore change the displayed frame
  (when orientation was deferred) in addition to copying pixels to memory.

  Per-op materialization (`ImagePipe.Transform.Chain`) calls this before the
  first operation that requires random access, so a sequential decode can stream
  through earlier ops and only copy when an op genuinely needs arbitrary pixel
  access. `Request.Processor.materialize_for_delivery/2` also calls the arity-2
  callback form once before delivery for any chain that never materialized
  mid-pipeline.

  `materialize/1` emits a `[:transform, :materialize]` telemetry span around the
  flush, giving honest per-barrier timing regardless of which call site triggered
  the materialization.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.{OrientationFlush, State}

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  # Arity-1 (chain mid-pipeline) and arity-2 (delivery backstop) both route through
  # here, so a single [:transform, :materialize] span covers both entry points.
  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{telemetry_opts: telemetry_opts} = state) do
    Telemetry.span(telemetry_opts, [:transform, :materialize], %{}, fn ->
      case do_materialize(state) do
        {:ok, new_state} -> {{:ok, new_state}, %{result: :ok}}
        {:error, reason} -> {{:error, reason}, %{result: :materialize_error}}
      end
    end)
  end

  # Delivery backstop delegates to the wrapped arity-1; it ignores opts (telemetry
  # metadata rides on the State). Do not add a second span here.
  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end

  # The flush returns a BARE {:ok, state} | {:error, reason}. The
  # {:materialize_error, reason} TUPLE wrapping is owned by callers (Chain,
  # PlanExecutor); the :materialize_error SPAN metadata label is set in the wrapper
  # above only to drive Logger level escalation. Never re-wrap the error tuple here.
  defp do_materialize(%State{} = state), do: OrientationFlush.flush(state)
end
