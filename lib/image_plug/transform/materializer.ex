defmodule ImagePlug.Transform.Materializer do
  @moduledoc """
  Internal boundary for forcing lazy image graphs into memory.

  Sequential input decode can defer origin reads until transform execution. ImagePlug
  uses this module before cache writes or response headers so request handling can
  materialize pixels, then check whether the origin stream finished or failed.

  Multi-pipeline plans also materialize between pipelines. That boundary preserves
  the plan's explicit intermediate image semantics and allows decode planning to use
  only the first pipeline when choosing origin access: later operations classified
  as random-access run against a memory-backed intermediate image instead of
  changing how the origin is opened.
  """

  alias ImagePlug.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    with {:ok, image} <- materialize(state.image) do
      {:ok, State.set_image(state, image)}
    end
  end

  @spec materialize(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def materialize(%VipsImage{} = image) do
    VipsImage.copy_memory(image)
  end
end
