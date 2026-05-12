defmodule ImagePlug.Transform.KeyData do
  @moduledoc """
  Canonical keyword data helpers for transform cache keys.

  Tagged geometry values are already-normalized semantic values. DPR floats are
  first rounded and formatted at fixed decimal precision before reduction, so
  cache material never depends on raw IEEE float representation.
  """

  @dpr_float_decimal_places 7

  @type geometry_value ::
          :auto
          | :full_axis
          | {:px, pos_integer()}
          | {:ratio, non_neg_integer(), pos_integer()}

  @type ratio_data :: [
          {:unit, :ratio}
          | {:numerator, non_neg_integer()}
          | {:denominator, pos_integer()}
        ]

  @spec data(geometry_value()) :: keyword()
  def data(:auto), do: [unit: :auto]
  def data(:full_axis), do: [unit: :full_axis]

  def data({:px, value}) when is_integer(value) and value > 0,
    do: [unit: :logical_px, value: value]

  def data({:ratio, numerator, denominator})
      when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
             denominator > 0 do
    ratio_data(numerator, denominator)
  end

  @spec dpr_data(pos_integer() | float() | String.t()) :: ratio_data()
  def dpr_data(value) when is_integer(value) and value > 0 do
    ratio_data(value, 1)
  end

  def dpr_data(value) when is_float(value) and value > 0.0 do
    value
    |> Float.round(@dpr_float_decimal_places)
    |> :erlang.float_to_binary(decimals: @dpr_float_decimal_places)
    |> decimal_string_ratio_data()
  end

  def dpr_data(value) when is_binary(value) do
    decimal_string_ratio_data(value)
  end

  defp decimal_string_ratio_data(value) do
    value
    |> decimal_string_ratio()
    |> dpr_ratio_data()
  end

  defp decimal_string_ratio(value) do
    case String.split(value, ".", parts: 2) do
      [integer] -> {parse_digits!(integer), 1}
      [integer, fraction] -> decimal_ratio(integer, fraction)
    end
  end

  defp decimal_ratio(integer, fraction) when byte_size(fraction) > 0 do
    denominator = integer_power(10, byte_size(fraction))
    numerator = parse_digits!(integer) * denominator + parse_digits!(fraction)

    {numerator, denominator}
  end

  defp parse_digits!(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      {0, ""} -> 0
    end
  end

  defp dpr_ratio_data({numerator, denominator}) when numerator > 0,
    do: ratio_data(numerator, denominator)

  defp ratio_data(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)

    [
      unit: :ratio,
      numerator: div(numerator, gcd),
      denominator: div(denominator, gcd)
    ]
  end

  defp integer_power(base, exponent) do
    Enum.reduce(1..exponent//1, 1, fn _step, product -> product * base end)
  end
end
