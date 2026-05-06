defprotocol ImagePlug.Transform.Material do
  @moduledoc """
  Canonical material protocol for transform cache keys.

  Every operation struct that can appear in execution pipelines must implement
  this protocol with product-neutral keyword material describing its canonical
  operation semantics. Cache key construction depends on this material, and a
  missing implementation is a programmer error.

  Material is not execution output and is unrelated to
  `ImagePlug.Transform.Materializer`, which forces lazy image pixels into
  memory. This protocol describes the stable, deterministic representation used
  by `ImagePlug.Cache.Key` when hashing a plan.

  Implementations should include the semantic fields that affect visible output
  and avoid parser-specific syntax. When an execution detail is resolved only at
  runtime from source metadata, use an explicit sentinel such as
  `:runtime_resolved` instead of omitting the field or guessing a value. Changes
  to material shape intentionally change cache keys and should be covered by
  focused cache material tests.
  """

  @spec material(t()) :: keyword()
  def material(operation)
end
