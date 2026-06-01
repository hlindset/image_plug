defmodule ImagePipe.Transform.Focal do
  @moduledoc false
  # Pure weighted centroid of detected regions for object gravity. Each region
  # pulls the focal point toward its box center, weighted by `classWeight(label) ·
  # area_term(area)`. Task 2 swaps `area_term` from `area` to `√area`; the class
  # weight is the Slice 2 addition. Kept pure (no image/State) so the formula is
  # unit-testable with exact coordinates.

  @type region :: %{
          optional(:label) => String.t() | nil,
          optional(any()) => any(),
          box: {number(), number(), number(), number()}
        }
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}

  @spec weighted_centroid([region()], number(), number(), weights()) ::
          {:ok, {:fp, float(), float()}} | :none
  def weighted_centroid(regions, image_width, image_height, weights) do
    in_image =
      Enum.filter(regions, fn %{box: {x, y, w, h}} ->
        w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= image_width and y + h <= image_height
      end)

    case in_image do
      [] ->
        :none

      boxes ->
        total = Enum.reduce(boxes, 0.0, fn region, acc -> acc + region_pull(region, weights) end)

        {sx, sy} =
          Enum.reduce(boxes, {0.0, 0.0}, fn %{box: {x, y, w, h}} = region, {ax, ay} ->
            pull = region_pull(region, weights)
            {ax + pull * (x + w / 2), ay + pull * (y + h / 2)}
          end)

        {:ok, {:fp, clamp_unit(sx / total / image_width), clamp_unit(sy / total / image_height)}}
    end
  end

  defp region_pull(%{box: {_x, _y, w, h}} = region, weights) do
    class_weight(Map.get(region, :label), weights) * area_term(w, h)
  end

  # Task 2 changes this to `:math.sqrt(w * h)`.
  defp area_term(w, h), do: w * h

  defp class_weight(label, weights) do
    Map.get(weights, label, Map.get(weights, :default, 1.0))
  end

  defp clamp_unit(value) when value < 0.0, do: 0.0
  defp clamp_unit(value) when value > 1.0, do: 1.0
  defp clamp_unit(value), do: value
end
