defmodule ImagePlug.Transform.Resolver.Geometry do
  @moduledoc """
  Geometry helpers for source-aware transform resolution.
  """

  @spec orientation(term(), term()) :: :landscape | :portrait | :square | :unknown
  def orientation(width, height) when is_integer(width) and is_integer(height) and width > height,
    do: :landscape

  def orientation(width, height) when is_integer(width) and is_integer(height) and width < height,
    do: :portrait

  def orientation(width, height)
      when is_integer(width) and is_integer(height) and width == height,
      do: :square

  def orientation(_width, _height), do: :unknown

  @spec resize_auto_branch(term(), term(), term(), term()) :: :cover | :fit
  def resize_auto_branch(current_width, current_height, target_width, target_height) do
    current_orientation = orientation(current_width, current_height)
    target_orientation = orientation(target_width, target_height)

    case {known_orientation?(current_orientation), current_orientation == target_orientation} do
      {true, true} -> :cover
      {_known?, _matches?} -> :fit
    end
  end

  defp known_orientation?(:unknown), do: false
  defp known_orientation?(_orientation), do: true
end
