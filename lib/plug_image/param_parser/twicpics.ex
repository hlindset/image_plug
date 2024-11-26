defmodule PlugImage.ParamParser.Twicpics do
  @behaviour PlugImage.ParamParser

  alias PlugImage.ParamParser.Twicpics

  @transforms %{
    "crop" => PlugImage.Transform.Crop,
    "resize" => PlugImage.Transform.Scale,
    "focus" => PlugImage.Transform.Focus,
    "output" => PlugImage.Transform.Output
  }

  @parsers %{
    PlugImage.Transform.Crop => Twicpics.CropParser,
    PlugImage.Transform.Scale => Twicpics.ScaleParser,
    PlugImage.Transform.Focus => Twicpics.FocusParser,
    PlugImage.Transform.Output => Twicpics.OutputParser
  }

  @impl PlugImage.ParamParser
  def parse(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case conn.params do
      %{"twic" => "v1/" <> chain} -> parse_chain(chain)
      _ -> {:ok, []}
    end
  end

  def parse_chain(chain_str) do
    parsed_chain =
      chain_str
      |> String.split("/")
      |> Enum.map(&String.split(&1, "="))
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
