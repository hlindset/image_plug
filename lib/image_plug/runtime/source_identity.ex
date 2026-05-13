defmodule ImagePlug.Runtime.SourceIdentity do
  @moduledoc false

  alias ImagePlug.Plan
  alias ImagePlug.Runtime.Origin

  @spec resolve(Plan.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(%Plan{source: {:plain, source_path}}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    Origin.build_url(root_url, source_path)
  end

  def resolve(%Plan{source: source}, _opts) do
    {:error, {:unsupported_source, source}}
  end
end
