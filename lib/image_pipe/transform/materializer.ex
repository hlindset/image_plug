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
  access. `Request.Processor` also calls the arity-2 callback form once before
  delivery for any chain that never materialized mid-pipeline.
  """

  alias ImagePipe.Transform.{OrientationFlush, State}

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state) do
    OrientationFlush.flush(state)
  end

  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end
end
