defmodule Arithmetic do
  @type token :: {:int, integer} | {:float, float} | {:op, binary} | :left_paren | :right_paren
  @type expr :: {:int, integer} | {:float, float} | {:op, binary, expr(), expr()}

  @spec evaluate(String.t()) :: {:ok, } | {:error, atom()}
  def parse_and_evaluate(input) do
    case parse(input) do
      {:ok, expr} -> evaluate(expr)
      {:error, _} = error -> error
    end
  end

  @spec parse(String.t()) :: {:ok, expr()} | {:error, atom()}
  def parse(tokens) do
    case parse_expression(tokens, 0) do
      {:ok, expr, []} ->
        {:ok, expr}
      {:ok, expr, [token | _]} ->
        {start_pos, _end_pos} = NumberParser.pos_for_token(token)
        {:error, {:unexpected_token, pos: start_pos}}
      {:error, _} = error -> error
    end
  end

  def parse_expression(tokens, min_prec) do
    case parse_primary(tokens) do
      {:ok, lhs, rest} -> parse_binary_op(lhs, rest, min_prec)
      {:error, _} = error -> error
    end
  end

  defp parse_primary([{:int, n, pos_b, pos_e} | rest]), do: {:ok, {:int, n, pos_b, pos_e}, rest}
  defp parse_primary([{:float, n, pos_b, pos_e} | rest]), do: {:ok, {:float, n, pos_b, pos_e}, rest}

  defp parse_primary([{:left_paren, pos} | rest]) do
    case parse_expression(rest, 0) do
      {:ok, expr, [{:right_paren, _pos} | rest2]} -> {:ok, expr, rest2}
      {:ok, _, _} -> {:error, {:mismatched_paren, pos: pos}}
      {:error, _} = error -> error
    end
  end

  defp parse_primary([token | _]) do
    {start_pos, _end_pos} = NumberParser.pos_for_token(token)
    {:error, {:unexpected_token, pos: start_pos}}
  end

  defp parse_binary_op(lhs, tokens, min_prec) do
    case tokens do
      [{:op, op, _} | rest] ->
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
  def evaluate({:int, n, _pos_b, _pos_e}), do: {:ok, n}
  def evaluate({:float, n, _pos_b, _pos_e}), do: {:ok, n}

  def evaluate({:op, "+", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval + rval}
    end
  end

  def evaluate({:op, "-", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval - rval}
    end
  end

  def evaluate({:op, "*", lhs, rhs}) do
    with {:ok, lval} <- evaluate(lhs),
         {:ok, rval} <- evaluate(rhs) do
      {:ok, lval * rval}
    end
  end

  def evaluate({:op, "/", lhs, rhs}) do
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
