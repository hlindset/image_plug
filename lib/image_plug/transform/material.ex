defprotocol ImagePlug.Transform.Material do
  @moduledoc """
  Canonical material for transform operation structs.

  Every operation struct that can appear in `ImagePlug.Plan` pipelines must implement
  this protocol. Missing implementations are programmer errors and may raise
  `Protocol.UndefinedError` during cache key construction.
  """

  @spec material(t()) :: keyword()
  def material(operation)
end
