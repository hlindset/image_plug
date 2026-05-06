defprotocol ImagePlug.Transform.Material do
  @moduledoc """
  Canonical material protocol for transform cache keys.

  Every operation struct that can appear in execution pipelines must implement
  this protocol with product-neutral keyword material describing its canonical
  operation semantics. Cache key construction depends on this material, and a
  missing implementation is a programmer error.
  """

  @spec material(t()) :: keyword()
  def material(operation)
end
