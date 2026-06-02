defmodule ImagePipe.Transform.Materializer do
  @moduledoc """
  Materialization boundary for transform execution.

  `materialize/1` copies the current image to a RAM-resident buffer via
  `Vix.Vips.Image.copy_memory/1` and marks the state `materialized?: true`.

  Per-op materialization (`ImagePipe.Transform.Chain`) calls this before the
  first operation that requires random access, so a sequential decode can stream
  through earlier ops and only copy when an op genuinely needs arbitrary pixel
  access. `Request.Processor` also calls the arity-2 callback form once before
  delivery for any chain that never materialized mid-pipeline.
  """

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state) do
    case VipsImage.copy_memory(state.image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _reason} = error -> error
    end
  end

  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end
end
