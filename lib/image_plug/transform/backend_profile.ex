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

  @spec material_from_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  def material_from_options(opts) when is_list(opts) do
    opts
    |> Keyword.get(:backend_profile, default())
    |> validate_material()
  end

  @spec material(keyword()) :: keyword()
  def material(profile) when is_list(profile), do: profile

  defp validate_material(profile) when is_list(profile) and profile == [] do
    {:ok, material(profile)}
  end

  defp validate_material([{key, _value} | _rest] = profile) when is_atom(key) do
    validate_keyword_material(profile, profile)
  end

  defp validate_material(profile), do: {:error, {:invalid_backend_profile, profile}}

  defp validate_keyword_material([], profile), do: {:ok, material(profile)}

  defp validate_keyword_material([{key, _value} | rest], profile) when is_atom(key) do
    validate_keyword_material(rest, profile)
  end

  defp validate_keyword_material(_invalid, profile),
    do: {:error, {:invalid_backend_profile, profile}}
end
