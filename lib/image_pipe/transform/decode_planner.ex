defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access for semantic Plan operations.

  Decode planning reduces a source-fetch-free Plan operation chain to either
  sequential or random image access. It is intentionally conservative for valid
  semantic operations: empty chains and neutral access both fall back to random
  access.
  """

  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.Sharpen

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options([ImagePipe.Plan.Pipeline.operation()]) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  defp access([]), do: :random

  defp access(chain) when is_list(chain) do
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
  defp access_requirement(%Padding{}), do: :random
  defp access_requirement(%Background{}), do: :random
  defp access_requirement(%AutoOrient{}), do: :sequential
  defp access_requirement(%Rotate{}), do: :random
  defp access_requirement(%Flip{}), do: :random
  defp access_requirement(%Blur{}), do: :random
  defp access_requirement(%Sharpen{}), do: :random
  defp access_requirement(%Pixelate{}), do: :random
  defp access_requirement(%Monochrome{}), do: :random
  defp access_requirement(%Duotone{}), do: :random
  defp access_requirement(%Brightness{}), do: :random
  defp access_requirement(%Contrast{}), do: :random
  defp access_requirement(%Saturation{}), do: :random

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

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
