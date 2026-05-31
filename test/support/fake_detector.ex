defmodule ImagePipe.Test.FakeDetector do
  @moduledoc "Configurable in-memory Detector for deterministic tests."
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def detect(_image, opts) do
    case Keyword.fetch(opts, :result) do
      {:ok, result} -> result
      :error -> {:ok, []}
    end
  end

  @impl true
  def available?(opts), do: Keyword.get(opts, :available?, true)

  @impl true
  def identity(opts), do: {__MODULE__, Keyword.get(opts, :identity, :fake_v1)}
end
