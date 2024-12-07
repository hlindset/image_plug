defmodule ImagePlug.ParamParser.TwicpicsV2 do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ParamParser.Twicpics.TwicpicsV2

  @transforms %{
    "crop" => ImagePlug.Transform.Crop
  }

  @parsers %{
    ImagePlug.Transform.Crop => TwicpicsV2.Transform.CropParser
  }

  @impl ImagePlug.ParamParser
  def parse(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.params do
      %{"twic" => input} -> parse_string(input)
      _ -> {:ok, []}
    end
  end

  def parse_string(input) do
    case input do
      "v1/" <> chain -> parse_chain(chain)
      _ -> {:ok, []}
    end
  end

  # a `key=value` string followed by either a slash and a
  # new key=value string or the end of the string using lookahead
  @params_regex ~r/\/?([a-z]+)=(.+?(?=\/[a-z]+=|$))/

  def parse_chain(chain_str) do
    Regex.scan(@params_regex, chain_str, capture: :all_but_first)
    |> Enum.reduce_while({:ok, []}, fn
      [transform_name, params_str], {:ok, transforms_acc}
      when is_map_key(@transforms, transform_name) ->
        module = Map.get(@transforms, transform_name)

        case @parsers[module].parse(params_str) do
          {:ok, parsed_params} ->
            {:cont, {:ok, [{module, parsed_params} | transforms_acc]}}

          {:error, {:parameter_parse_error, input}} ->
            {:halt, {:error, {:invalid_params, {module, "invalid input: #{input}"}}}}
        end

      [transform_name, _params_str], acc ->
        {:cont, [{:error, {:invalid_transform, transform_name}} | acc]}
    end)
    |> case do
      {:ok, transforms} -> {:ok, Enum.reverse(transforms)}
      other -> other
    end
  end
end
