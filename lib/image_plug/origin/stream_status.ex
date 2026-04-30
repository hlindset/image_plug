defmodule ImagePlug.Origin.StreamStatus do
  use GenServer

  @moduledoc """
  Idempotent status holder for guarded origin streams.

  Origin stream consumption may happen outside the request process. This holder lets
  the stream worker record `:done` or the first stream error once, while request
  handling can read that result repeatedly before cache writes or response delivery.

  The holder is request-scoped and monitors the process that called
  `ImagePlug.Origin.fetch/2`, so it exits even when that process exits normally.
  `ImagePlug.Origin.close/1` cancels the stream worker but intentionally leaves this
  holder alive so callers can still read the last recorded status while the
  response remains in scope.
  """

  @type status() :: :pending | :done | {:error, term()}

  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, self())
  end

  @spec get(pid()) :: status()
  def get(pid) when is_pid(pid) do
    GenServer.call(pid, :get)
  end

  @spec put(pid(), status()) :: status()
  def put(pid, status) when is_pid(pid) do
    GenServer.call(pid, {:put, status})
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(owner) when is_pid(owner) do
    {:ok, %{owner_ref: Process.monitor(owner), status: :pending}}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:put, status}, _from, %{status: :pending} = state) do
    {:reply, status, %{state | status: status}}
  end

  def handle_call({:put, _status}, _from, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state) do
    {:stop, :normal, state}
  end
end
