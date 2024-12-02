defmodule ImagePlug.ParamParser.Twicpics do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ParamParser.Twicpics

  @transforms %{
    "crop" => ImagePlug.Transform.Crop,
    "resize" => ImagePlug.Transform.Scale,
    "focus" => ImagePlug.Transform.Focus,
    "output" => ImagePlug.Transform.Output
  }

  @parsers %{
    ImagePlug.Transform.Crop => Twicpics.CropParser,
    ImagePlug.Transform.Scale => Twicpics.ScaleParser,
    ImagePlug.Transform.Focus => Twicpics.FocusParser,
    ImagePlug.Transform.Output => Twicpics.OutputParser
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
      |> Enum.reduce_while([], fn
        [transform_name, params_str], acc when is_map_key(@transforms, transform_name) ->
          {:cont, [{:ok, {Map.get(@transforms, transform_name), params_str}} | acc]}

        [transform_name, _params_str], acc ->
          {:cont, [{:error, {:invalid_transform, transform_name}} | acc]}
      end)
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, []}, fn {:ok, {module, params_str}}, {:ok, transforms_acc} ->
      case @parsers[module].parse(params_str) do
        {:ok, parsed_params} ->
          {:cont, {:ok, transforms_acc ++ {module, parsed_params}}}

        {:error, {:parameter_parse_error, input}} ->
          {:halt, {:error, {:invalid_params, {module, "invalid input: #{input}"}}}}
      end
      end)
  end
end
