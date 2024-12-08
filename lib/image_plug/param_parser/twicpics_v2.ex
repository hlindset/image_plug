defmodule ImagePlug.ParamParser.TwicpicsV2 do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ParamParser.TwicpicsV2

  @transforms %{
    "crop" => {ImagePlug.Transform.Crop, TwicpicsV2.Transform.CropParser},
    "resize" => {ImagePlug.Transform.Scale, TwicpicsV2.Transform.ScaleParser},
    "focus" => {ImagePlug.Transform.Focus, TwicpicsV2.Transform.FocusParser},
    "contain" => {ImagePlug.Transform.Contain, TwicpicsV2.Transform.ContainParser},
    "output" => {ImagePlug.Transform.Output, TwicpicsV2.Transform.OutputParser}
  }

  @transform_keys Map.keys(@transforms)
  @query_param "twic"
  @query_param_prefix "v1/"

  @impl ImagePlug.ParamParser
  def parse(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.params do
      %{@query_param => input} ->
        # start position count from where the request_path starts.
        # used for parser error messages.
        pos_offset = String.length(conn.request_path <> "?" <> @query_param <> "=")
        parse_string(input, pos_offset)

      _ ->
        {:ok, []}
    end
  end

  def parse_string(input, pos_offset \\ 0) do
    case input do
      @query_param_prefix <> chain ->
        pos_offset = pos_offset + String.length(@query_param_prefix)
        parse_chain(chain, pos_offset)

      _ ->
        {:ok, []}
    end
  end

  def parse_chain(chain_str, pos_offset) do
    case TwicpicsV2.KVParser.parse(chain_str, @transform_keys, pos_offset) do
      {:ok, kv_params} ->
        Enum.reduce_while(kv_params, {:ok, []}, fn
          {transform_name, params_str, pos}, {:ok, transforms_acc} ->
            {transform_mod, parser_mod} = Map.get(@transforms, transform_name)

            case parser_mod.parse(params_str, pos) do
              {:ok, parsed_params} ->
                {:cont, {:ok, [{transform_mod, parsed_params} | transforms_acc]}}

              {:error, _reason} = error ->
                {:halt, error}
            end
        end)

      {:error, _reason} = error ->
        error
    end
    |> case do
      {:ok, transforms} -> {:ok, Enum.reverse(transforms)}
      other -> other
    end
  end
end
