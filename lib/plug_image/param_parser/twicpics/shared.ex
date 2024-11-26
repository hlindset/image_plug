defmodule ImagePlug.ParamParser.Twicpics.Shared do
  @moduledoc """
  Shared `NimbleParsec` combinators.
  """

  import NimbleParsec

  @percent_unit_char ascii_char([?p])
  @decimal_separator_char ascii_char([?.])

  @doc """
  `:float` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_float, parsec(:float)
      end

      MyParser.parse_float("10.1")
      #=> {:ok, [10.1], "", %{}, {1, 0}, 4}

      MyParser.parse_float("10")
      #=> {:ok, [10.0], "", %{}, {1, 0}, 2}
  """
  defcombinator(
    :float,
    integer(min: 1)
    |> optional(
      ignore(@decimal_separator_char)
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

  @doc """
  `:integer` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_integer, parsec(:pixel)
      end

      MyParser.parse_integer("1000")
      #=> {:ok, [1000], "", %{}, {1, 0}, 4}
  """
  defcombinator(
    :integer,
    integer(min: 1)
    |> lookahead_not(
      choice([
        @decimal_separator_char,
        @percent_unit_char
      ])
    ),
    export_combinator: true
  )

  @doc """
  `:int_size` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_int_size, parsec(:int_size)
      end

      MyParser.parse_int_size("1000")
      #=> {:ok, [int: 1000], "", %{}, {1, 0}, 4}
  """
  defcombinator(
    :int_size,
    parsec(:integer)
    |> unwrap_and_tag(:int),
    export_combinator: true
  )

  @doc """
  `:pct_size` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_pct_size, parsec(:pct_size)
      end

      MyParser.parse_pct_size("1000p")
      #=> {:ok, [pct: 1000.0], "", %{}, {1, 0}, 5}
  """
  defcombinator(
    :pct_size,
    parsec(:float)
    |> ignore(@percent_unit_char)
    |> unwrap_and_tag(:pct),
    export_combinator: true
  )

  @doc """
  `:int_or_pct_size` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_int_or_pct_size, parsec(:int_or_pct_size)
      end

      MyParser.parse_int_or_pct_size("1000p")
      #=> {:ok, [pct: 1000.0], "", %{}, {1, 0}, 5}

      MyParser.parse_int_or_pct_size("1000")
      #=> {:ok, [int: 1000], "", %{}, {1, 0}, 4}
  """
  defcombinator(
    :int_or_pct_size,
    choice([
      parsec(:int_size),
      parsec(:pct_size)
    ]),
    export_combinator: true
  )

  @doc """
  `:dimension` combinator.

  ## Examples

      defmodule MyParser do
        import NimbleParsec
        import ImagePlug.ParamParser.Twicpics.Shared

        defparsec :parse_dimension, parsec(:dimension)
      end

      MyParser.parse_dimension("200px30")
      #=> {:ok, [x: {:pct, 200.0}, y: {:int, 30}], "", %{}, {1, 0}, 7}

      MyParser.parse_dimension("200x30p")
      #=> {:ok, [x: {:int, 200}, y: {:pct, 30.0}], "", %{}, {1, 0}, 7}

      MyParser.parse_dimension("200x300")
      #=> {:ok, [x: {:int, 200}, y: {:int, 300}], "", %{}, {1, 0}, 7}
  """
  defcombinator(
    :dimension,
    unwrap_and_tag(parsec(:int_or_pct_size), :x)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(parsec(:int_or_pct_size), :y),
    export_combinator: true
  )
end
