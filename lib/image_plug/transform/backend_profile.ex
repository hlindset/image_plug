defmodule ImagePlug.Transform.BackendProfile do
  @moduledoc """
  First-slice backend/profile material for transform cache keys.
  """

  @default [
    backend: :vips,
    material_version: 1,
    geometry_rules_version: 1,
    orientation_policy_version: 1,
    dpr_policy_version: 1,
    smart_strategy_support: :none
  ]

  @spec default() :: keyword()
  def default, do: @default

  @spec material(keyword()) :: keyword()
  def material(profile) when is_list(profile), do: profile
end
