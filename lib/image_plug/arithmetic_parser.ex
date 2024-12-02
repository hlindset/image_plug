defmodule ImagePlug.ArithmeticParser do
  @type token :: {:int, integer} | {:float, float} | {:op, binary} | :left_paren | :right_paren
  @type expr :: {:int, integer} | {:float, float} | {:op, binary, expr(), expr()}

  @spec parse(String.t()) :: {:ok, expr} | {:error, atom()}
  def parse(input) do
    case tokenize(input) do
      {:ok, tokens} ->
        case parse_expression(tokens, 0) do
          {:ok, expr, []} -> {:ok, expr}
          {:ok, _, _} -> {:error, :unexpected_token_after_expr}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @spec evaluate(String.t()) :: {:ok, number} | {:error, atom()}
  def parse_and_evaluate(input) do
    case parse(input) do
      {:ok, expr} -> evaluate(expr)
      {:error, _} = error -> error
    end
  end

  defp tokenize(input) do
    input
    |> String.replace(~r/\s+/, "")
    |> String.graphemes()
    |> do_tokenize([])
  end

  defp do_tokenize([], acc), do: {:ok, Enum.reverse(acc)}

  defp do_tokenize([h | t], acc) when h in ~w(+ - * /) do
    do_tokenize(t, [{:op, h} | acc])
  end

  defp do_tokenize(["(" | t], acc), do: do_tokenize(t, [:left_paren | acc])
  defp do_tokenize([")" | t], acc), do: do_tokenize(t, [:right_paren | acc])

  defp do_tokenize([h | t], acc) when h in ~w(0 1 2 3 4 5 6 7 8 9 .) do
    {number, rest} = consume_number([h | t])

    token =
      if String.contains?(number, "."),
        do: {:float, String.to_float(number)},
        else: {:int, String.to_integer(number)}

    do_tokenize(rest, [token | acc])
  end

  defp do_tokenize(_, _), do: {:error, :invalid_character}

  defp consume_number(chars) do
    {number, rest} = Enum.split_while(chars, &(&1 in ~w(0 1 2 3 4 5 6 7 8 9 .)))
    {Enum.join(number), rest}
  end

  defp parse_expression(tokens, min_prec) do
    case parse_primary(tokens) do
      {:ok, lhs, rest} -> parse_binary_op(lhs, rest, min_prec)
      {:error, _} = error -> error
    end
  end

  defp parse_primary([{:int, n} | rest]), do: {:ok, {:int, n}, rest}
  defp parse_primary([{:float, n} | rest]), do: {:ok, {:float, n}, rest}

  defp parse_primary([:left_paren | rest]) do
    case parse_expression(rest, 0) do
      {:ok, expr, [:right_paren | rest2]} -> {:ok, expr, rest2}
      {:ok, _, _} -> {:error, :mismatched_paren}
      {:error, _} = error -> error
    end
  end

  defp parse_primary(_), do: {:error, :expected_primary_expression}

  defp parse_binary_op(lhs, tokens, min_prec) do
    case tokens do
      [{:op, op} | rest] ->
        prec = precedence(op)

        if prec < min_prec do
          {:ok, lhs, tokens}
        else
          case parse_expression(rest, prec + 1) do
            {:ok, rhs, rest2} ->
              new_lhs = {:op, op, lhs, rhs}
              parse_binary_op(new_lhs, rest2, min_prec)

            {:error, _} = error ->
              error
          end
        end

      _ ->
        {:ok, lhs, tokens}
    end
  end

  defp precedence("+"), do: 1
  defp precedence("-"), do: 1
  defp precedence("*"), do: 2
  defp precedence("/"), do: 2

  @spec evaluate(expr()) :: {:ok, number} | {:error, String.t()}
  defp evaluate({:int, n}), do: {:ok, n}
  defp evaluate({:float, n}), do: {:ok, n}

  defp evaluate({:op, "+", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval + rval}
    end
  end

  defp evaluate({:op, "-", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval - rval}
    end
  end

  defp evaluate({:op, "*", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval * rval}
    end
  end

  defp evaluate({:op, "/", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      if rval == 0 do
        {:error, :division_by_zero}
      else
        {:ok, lval / rval}
      end
    end
  end
end
