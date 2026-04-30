defmodule ImagePlug.Origin.StreamStatus do
  @moduledoc """
  Idempotent status holder for guarded origin streams.

  Origin stream consumption may happen outside the request process. This holder lets
  the stream worker record `:done` or the first stream error once, while request
  handling can read that result repeatedly before cache writes or response delivery.
  """

  @type status() :: :pending | :done | {:error, term()}

  @spec start_link() :: Agent.on_start()
  def start_link do
    Agent.start_link(fn -> :pending end)
  end

  @spec get(pid()) :: status()
  def get(pid) when is_pid(pid) do
    Agent.get(pid, & &1)
  end

  @spec put(pid(), status()) :: status()
  def put(pid, status) when is_pid(pid) do
    Agent.get_and_update(pid, fn
      :pending -> {status, status}
      settled -> {settled, settled}
    end)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Agent.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end
end
