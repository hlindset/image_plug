defmodule ImagePlug.Plan do
  @moduledoc """
  Product-neutral execution request produced by parameter parsers.
  """

  @enforce_keys [:source, :pipelines, :output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: ImagePlug.Source.Plain.t(),
          pipelines: [ImagePlug.Pipeline.t()],
          output: ImagePlug.OutputPlan.t()
        }
end
