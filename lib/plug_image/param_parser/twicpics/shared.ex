defmodule ImagePlug.ParamParser.Twicpics.Shared do
  def with_parsed_units(units, fun) do
    case parse_all_units(units) do
      {:error, _} = error -> error
      {:ok, units} -> fun.(units)
    end
  end

  def parse_all_units(units) do
    reduced =
      Enum.reduce_while(units, [], fn unit, acc ->
        case parse_unit(unit) do
          {:ok, parsed} -> {:cont, [parsed | acc]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case reduced do
      parsed when is_list(parsed) ->
        {:ok, Enum.reverse(parsed)}

      {:error, _} = error ->
        error
    end
  end

  def parse_unit(input) do
    cond do
      Regex.match?(~r/^\((.+)\/(.+)\)s$/, input) ->
        [_, num1, num2] = Regex.run(~r/^\((.+)\/(.+)\)s$/, input)

        with {:ok, parsed_num1} <- parse_number(num1),
             {:ok, parsed_num2} <- parse_number(num2) do
          {:ok, {:scale, parsed_num1, parsed_num2}}
        else
          {:error, _} = error -> error
        end

      Regex.match?(~r/^(.+)p$/, input) ->
        [_, num] = Regex.run(~r/^(.+)p$/, input)

        case parse_number(num) do
          {:ok, parsed} -> {:ok, {:pct, parsed}}
          {:error, _} = error -> error
        end

      true ->
        parse_number(input)
    end
  end

  defp parse_number(input) do
    cond do
      Regex.match?(~r/^\d+(\.\d+)?$/, input) ->
        if String.contains?(input, ".") do
          {:ok, {:float, String.to_float(input)}}
        else
          {:ok, {:int, String.to_integer(input)}}
        end

      Regex.match?(~r/^\((.+)\)$/, input) ->
        [_, expr] = Regex.run(~r/^\((.+)\)$/, input)
        {:ok, {:expr, expr}}

      true ->
        {:error, {:invalid_number, input}}
    end
  end
end
