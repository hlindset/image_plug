defmodule ImagePlug.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access from transform operation metadata.

  Decode planning interprets each operation's product-neutral metadata and
  reduces the chain to either sequential or random image access. It is
  intentionally conservative for valid metadata: empty chains and neutral
  access both fall back to random access.
  """

  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.Resize, as: PlanResize
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(ImagePlug.Transform.Chain.t()) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.Transform.Chain.t()) :: :sequential | :random
  def access([]), do: :random

  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(%PlanResize{mode: mode} = operation) when mode in [:fit, :stretch],
    do: resize_access_requirement(operation)

  defp access_requirement(%PlanResize{mode: mode}) when mode in [:cover, :auto], do: :random
  defp access_requirement(%CropGuided{}), do: :random
  defp access_requirement(%CropRegion{}), do: :random
  defp access_requirement(%Canvas{}), do: :random
  defp access_requirement(%AutoOrient{}), do: :sequential
  defp access_requirement(%Rotate{}), do: :random
  defp access_requirement(%Flip{}), do: :random

  defp access_requirement(operation) do
    operation
    |> Transform.metadata()
    |> access_from_metadata()
  end

  defp resize_access_requirement(%PlanResize{
         width: width,
         height: height,
         min_width: nil,
         min_height: nil
       }) do
    case requested_resize_dimension?(width) or requested_resize_dimension?(height) do
      true -> :sequential
      false -> :random
    end
  end

  defp resize_access_requirement(%PlanResize{}), do: :random

  defp requested_resize_dimension?({:px, value}) when is_integer(value) and value > 0, do: true
  defp requested_resize_dimension?(_dimension), do: false

  defp access_from_metadata(%{access: access}) when access in [:sequential, :random, :neutral],
    do: access

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
