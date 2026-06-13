defmodule ImagePipe.Parser.IIIF.Resolver do
  @moduledoc """
  Host extension point mapping an opaque IIIF identifier to a product-neutral
  `ImagePipe.Plan.Source`. Configured via `iiif: [resolver: {Module, opts}]`.
  """

  @callback resolve(identifier :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
end
