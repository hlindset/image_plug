defmodule ImagePlug.Transform.Validation do
  @moduledoc false

  alias ImagePlug.Transform.Geometry.DimensionRule

  def one_of(label, field, value, allowed) do
    if value in allowed, do: :ok, else: invalid(label, field, value)
  end

  def boolean(_label, _field, value) when is_boolean(value), do: :ok
  def boolean(label, field, value), do: invalid(label, field, value)

  def positive_dimension_or_auto(_label, _field, :auto), do: :ok

  def positive_dimension_or_auto(label, field, value),
    do: positive_dimension(label, field, value)

  def positive_dimension(_label, _field, value) when is_number(value) and value > 0, do: :ok

  def positive_dimension(_label, _field, {unit, value})
      when unit in [:pixels, :percent, :scale] and is_number(value) and value > 0,
      do: :ok

  def positive_dimension(_label, _field, {:scale, numerator, denominator})
      when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0,
      do: :ok

  def positive_dimension(label, field, value), do: invalid(label, field, value)

  def positive_dimension_pair(label, width, height) do
    with :ok <- positive_dimension_or_auto(label, :width, width),
         :ok <- positive_dimension_or_auto(label, :height, height) do
      if width == :auto and height == :auto do
        {:error,
         ArgumentError.exception(
           "invalid #{label} dimensions: width and height cannot both be :auto"
         )}
      else
        :ok
      end
    end
  end

  def non_negative_dimension_or_auto(_label, _field, :auto), do: :ok

  def non_negative_dimension_or_auto(_label, _field, {:pixels, value})
      when is_number(value) and value >= 0,
      do: :ok

  def non_negative_dimension_or_auto(_label, _field, value)
      when is_number(value) and value >= 0,
      do: :ok

  def non_negative_dimension_or_auto(label, field, value), do: invalid(label, field, value)

  def non_negative_position(_label, _field, value) when is_number(value) and value >= 0,
    do: :ok

  def non_negative_position(_label, _field, {unit, value})
      when unit in [:pixels, :percent, :scale] and is_number(value) and value >= 0,
      do: :ok

  def non_negative_position(_label, _field, {:scale, numerator, denominator})
      when is_number(numerator) and is_number(denominator) and numerator >= 0 and denominator > 0,
      do: :ok

  def non_negative_position(label, field, value), do: invalid(label, field, value)

  def ratio(_label, _field, {width, height})
      when is_number(width) and is_number(height) and width > 0 and height > 0,
      do: :ok

  def ratio(label, field, ratio), do: invalid(label, field, ratio)

  def anchor(_label, _field, {:anchor, x, y})
      when x in [:left, :center, :right] and y in [:top, :center, :bottom],
      do: :ok

  def anchor(label, field, value), do: invalid(label, field, value)

  def gravity(_label, _field, nil), do: :ok

  def gravity(_label, _field, {:fp, x, y})
      when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0,
      do: :ok

  def gravity(label, field, {:anchor, _x, _y} = value), do: anchor(label, field, value)

  def gravity(label, field, value), do: invalid(label, field, value)

  def offset(_label, _field, value) when is_number(value), do: :ok

  def offset(_label, _field, {unit, value})
      when unit in [:pixels, :percent, :scale] and is_number(value),
      do: :ok

  def offset(_label, _field, {:scale, numerator, denominator})
      when is_number(numerator) and is_number(denominator) and denominator != 0,
      do: :ok

  def offset(label, field, value), do: invalid(label, field, value)

  def number(_label, _field, value) when is_number(value), do: :ok
  def number(label, field, value), do: invalid(label, field, value)

  def orientation(_label, _field, nil), do: :ok

  def orientation(_label, _field, %{auto_orient: auto_orient, rotate: rotate, flip: flip})
      when is_boolean(auto_orient) and rotate in [0, 90, 180, 270] and
             flip in [nil, :none, :horizontal, :vertical, :both],
      do: :ok

  def orientation(label, field, value), do: invalid(label, field, value)

  def dimension_rule(label, field, %DimensionRule{} = rule, modes) do
    case DimensionRule.validate(rule, modes: modes) do
      :ok ->
        :ok

      {:error, {invalid_field, value}} ->
        {:error,
         ArgumentError.exception("invalid #{label} #{field} #{invalid_field}: #{inspect(value)}")}
    end
  end

  def dimension_rule(label, field, value, _modes), do: invalid(label, field, value)

  def invalid(label, field, value) do
    {:error, ArgumentError.exception("invalid #{label} #{field}: #{inspect(value)}")}
  end
end
