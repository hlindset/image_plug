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
      %{"twic" => "v1/" <> chain} -> parse_chain(chain)
      _ -> {:ok, []}
    end
  end

  # a `key=value` string followed by either a slash and a
  # new key=value string or the end of the string using lookahead
  @params_regex ~r/\/?([a-z]+)=(.+?(?=\/[a-z]+=|$))/

  def parse_chain(chain_str) do
    parsed_chain =
      Regex.scan(@params_regex, chain_str, capture: :all_but_first)
      |> Enum.reduce_while([], fn
        [transform_name, params_str], acc when is_map_key(@transforms, transform_name) ->
          {:cont, [{:ok, {Map.get(@transforms, transform_name), params_str}} | acc]}

        [transform_name, _params_str], acc ->
          {:cont, [{:error, {:invalid_transform, transform_name}} | acc]}

        _, acc ->
          # TODO: handle more errors
          {:cont, acc}
      end)
      |> Enum.reverse()
      |> Enum.map(fn
        {:ok, {module, params_str}} ->
          case @parsers[module].parse(params_str) do
            {:ok, parsed_params} -> {:ok, {module, parsed_params}}
            {:error, _} = error -> error
          end

        {:error, _} = error ->
          error
      end)

    errors =
      parsed_chain
      |> Enum.filter(fn {t, _} -> t == :error end)
      |> Enum.map(fn {:error, err} -> err end)

    transforms =
      parsed_chain
      |> Enum.filter(fn {t, _} -> t == :ok end)
      |> Enum.map(fn {:ok, transform} -> transform end)

    case errors do
      [] -> {:ok, transforms}
      _ -> {:error, errors}
    end
  end
end
