defmodule ImagePlug.Transform.ResolvedPlan do
  @moduledoc """
  Executable transform work resolved from semantic Plan intent.
  """

  defstruct pipelines: [],
            diagnostics: [],
            selections: [],
            resolver_material: []

  @type t :: %__MODULE__{
          pipelines: [[ImagePlug.Transform.operation()]],
          diagnostics: list(),
          selections: list(),
          resolver_material: keyword()
        }
end
