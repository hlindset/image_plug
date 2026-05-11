defmodule ImagePlug.Transform.BackendProfile do
  @moduledoc """
  First-slice backend/profile material for transform cache keys.
  """

  @enforce_keys [
    :backend,
    :material_version,
    :geometry_rules_version,
    :orientation_policy_version,
    :dpr_policy_version,
    :smart_strategy_support
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          backend: atom(),
          material_version: pos_integer(),
          geometry_rules_version: pos_integer(),
          orientation_policy_version: pos_integer(),
          dpr_policy_version: pos_integer(),
          smart_strategy_support: atom()
        }

  @spec default() :: t()
  def default do
    %__MODULE__{
      backend: :vips,
      material_version: 1,
      geometry_rules_version: 1,
      orientation_policy_version: 1,
      dpr_policy_version: 1,
      smart_strategy_support: :none
    }
  end

  @spec material_from_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  def material_from_options(opts) when is_list(opts) do
    opts
    |> Keyword.get(:backend_profile, default())
    |> validate_material()
  end

  @spec material(t()) :: keyword()
  def material(%__MODULE__{} = profile) do
    [
      backend: profile.backend,
      material_version: profile.material_version,
      geometry_rules_version: profile.geometry_rules_version,
      orientation_policy_version: profile.orientation_policy_version,
      dpr_policy_version: profile.dpr_policy_version,
      smart_strategy_support: profile.smart_strategy_support
    ]
  end

  defp validate_material(%__MODULE__{} = profile), do: {:ok, material(profile)}

  defp validate_material(profile), do: {:error, {:invalid_backend_profile, profile}}
end
