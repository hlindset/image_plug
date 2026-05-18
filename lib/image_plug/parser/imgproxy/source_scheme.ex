defmodule ImagePlug.Parser.Imgproxy.SourceScheme do
  @moduledoc """
  Parser extension for custom imgproxy source schemes.
  """

  @callback translate(source :: String.t(), opts :: keyword()) ::
              {:ok, ImagePlug.Plan.Source.t()} | {:error, term()}
end
