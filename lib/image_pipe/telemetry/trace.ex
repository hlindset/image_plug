defmodule ImagePipe.Telemetry.Trace do
  @moduledoc "Public facade for the opt-in span tracer."

  @exporter_key {__MODULE__, :exporter}

  @doc false
  def set_exporter(mod), do: :persistent_term.put(@exporter_key, mod)

  @doc "The active exporter module, or nil when no tracer is attached."
  def exporter, do: :persistent_term.get(@exporter_key, nil)
end
