defprotocol ImagePlug.Cache.Material do
  @moduledoc """
  Canonical cache material for transform parameter structs.

  Every params struct that can appear in `ImagePlug.Plan` pipelines must implement
  this protocol. Missing implementations are programmer errors and may raise
  `Protocol.UndefinedError` during cache key construction.
  """

  @spec material(t()) :: keyword()
  def material(params)
end
