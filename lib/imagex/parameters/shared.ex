defmodule Imagex.Parameters.Shared do
  import NimbleParsec

  percent_unit_char = ascii_char([?p])
  decimal_separator_char = ascii_char([?.])

  defcombinator(
    :float,
    integer(min: 1)
    |> optional(
      ignore(decimal_separator_char)
      |> ascii_string([?0..?9], min: 1)
    )
    |> post_traverse(:parse_float),
    export_combinator: true
  )

  defp parse_float(rest, [decimal_part, int_part], context, _line, _offset) do
    case Float.parse("#{int_part}.#{decimal_part}") do
      {float, _} -> {rest, [float], context}
      _ -> {:error, :invalid_float}
    end
  end

  defp parse_float(rest, [int], context, _line, _offset) do
    {rest, [int / 1], context}
  end

  defcombinator(
    :integer,
    integer(min: 1)
    |> lookahead_not(
      choice([
        decimal_separator_char,
        percent_unit_char
      ])
    ),
    export_combinator: true
  )

  defcombinator(
    :int_size,
    parsec(:integer)
    |> unwrap_and_tag(:int),
    export_combinator: true
  )

  defcombinator(
    :pct_size,
    parsec(:float)
    |> ignore(percent_unit_char)
    |> unwrap_and_tag(:pct),
    export_combinator: true
  )

  defcombinator(
    :int_or_pct_size,
    choice([
      parsec(:int_size),
      parsec(:pct_size)
    ]),
    export_combinator: true
  )

  defcombinator(
    :dimension,
    unwrap_and_tag(parsec(:int_or_pct_size), :x)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(parsec(:int_or_pct_size), :y),
    export_combinator: true
  )
end
