defmodule ImagePlug.Transform.ResolvedPlan do
  @moduledoc """
  Executable transform work resolved from semantic Plan intent.
  """

  defstruct pipelines: [],
            diagnostics: [],
            derivations: [],
            selections: [],
            resolver_material: [],
            backend_profile_material: []

  @type t :: %__MODULE__{
          pipelines: [[ImagePlug.Transform.operation()]],
          diagnostics: list(),
          derivations: [ImagePlug.Transform.Derivation.t()],
          selections: list(),
          resolver_material: keyword(),
          backend_profile_material: keyword()
        }
end
