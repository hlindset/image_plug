defmodule ImagePlug.Origin.TerminalStatus do
  @moduledoc false

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
      terminal -> {terminal, terminal}
    end)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Agent.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end
end
