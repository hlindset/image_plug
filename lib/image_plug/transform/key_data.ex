defmodule ImagePlug.Transform.KeyData do
  @moduledoc """
  Canonical keyword data helpers for transform cache keys.

  Tagged geometry values are already-normalized semantic values. DPR floats are
  first rounded and formatted at fixed decimal precision before reduction, so
  cache material never depends on raw IEEE float representation.
  """

  @dpr_float_decimal_places 7

  alias ImagePlug.Plan.Operation.Resize

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

  @spec data(geometry_value() | Resize.t()) :: keyword()
  def data(%Resize{} = operation) do
    [
      op: :resize,
      mode: operation.mode,
      width: data(operation.width),
      height: data(operation.height),
      dpr: data(operation.dpr),
      enlargement: operation.enlargement,
      guide: guide_data(operation.guide),
      min_width: optional_data(operation.min_width),
      min_height: optional_data(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y
    ]
    |> resize_rule_data(operation)
  end

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

  defp optional_data(nil), do: nil
  defp optional_data(value), do: data(value)

  defp guide_data(:center), do: :center

  defp guide_data({:anchor, x, y}), do: [type: :anchor, x: x, y: y]

  defp guide_data({:focal, x, y}), do: [type: :focal, x: data(x), y: data(y)]

  defp resize_rule_data(data, %Resize{mode: :auto}),
    do: data ++ [rule: :imgproxy_orientation_match_v1]

  defp resize_rule_data(data, %Resize{}), do: data

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
