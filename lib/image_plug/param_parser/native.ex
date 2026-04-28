defmodule ImagePlug.ParamParser.Native do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ProcessingRequest

  @format_names ~w(auto webp avif jpeg png)

  @fits %{
    "cover" => :cover,
    "contain" => :contain,
    "fill" => :fill,
    "inside" => :inside
  }

  @formats %{
    "auto" => :auto,
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "png" => :png
  }

  @focus_anchors %{
    "center" => {:anchor, :center, :center},
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center}
  }

  @impl ImagePlug.ParamParser
  def parse(%Plug.Conn{path_info: [signature | path_info]}) do
    with :ok <- validate_signature(signature),
         {:ok, option_segments, source_path} <- split_source(path_info),
         {:ok, options} <- parse_options(option_segments) do
      {:ok,
       struct!(
         ProcessingRequest,
         Keyword.merge(
           [
             signature: signature,
             source_kind: :plain,
             source_path: source_path
           ],
           options
         )
       )}
    end
  end

  def parse(%Plug.Conn{path_info: []}) do
    {:error, :missing_source_kind}
  end

  @impl ImagePlug.ParamParser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp validate_signature(signature) when signature in ["_", "unsafe"], do: :ok
  defp validate_signature(signature), do: {:error, {:unsupported_signature, signature}}

  defp split_source(path_info) do
    case Enum.split_while(path_info, &(&1 != "plain")) do
      {_options, []} ->
        {:error, :missing_source_kind}

      {_options, ["plain"]} ->
        {:error, {:missing_source_identifier, "plain"}}

      {options, ["plain" | source_path]} ->
        {:ok, options, source_path}
    end
  end

  defp parse_options(option_segments) do
    Enum.reduce_while(option_segments, {:ok, MapSet.new(), []}, fn segment,
                                                                   {:ok, seen, options} ->
      case option_field(segment) do
        {:ok, field} ->
          if MapSet.member?(seen, field) do
            {:halt, {:error, {:duplicate_option, field}}}
          else
            case parse_option(segment) do
              {:ok, ^field, value} ->
                {:cont, {:ok, MapSet.put(seen, field), [{field, value} | options]}}

              {:error, _reason} = error ->
                {:halt, error}
            end
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen, options} -> {:ok, Enum.reverse(options)}
      {:error, _reason} = error -> error
    end
  end

  defp option_field(segment) do
    case segment |> String.split(":", parts: 2) |> hd() do
      "w" -> {:ok, :width}
      "h" -> {:ok, :height}
      "fit" -> {:ok, :fit}
      "focus" -> {:ok, :focus}
      "format" -> {:ok, :format}
      key -> {:error, {:unknown_option, key}}
    end
  end

  defp parse_option(segment) do
    case String.split(segment, ":") do
      ["w", value] ->
        with {:ok, pixels} <- parse_positive_pixels(value) do
          {:ok, :width, pixels}
        end

      ["h", value] ->
        with {:ok, pixels} <- parse_positive_pixels(value) do
          {:ok, :height, pixels}
        end

      ["fit", value] ->
        parse_mapped_option(:fit, value, @fits, {:invalid_fit, value})

      ["focus", value] ->
        parse_focus(value)

      ["focus", x, y] ->
        parse_focus_coordinate(x, y)

      ["format", value] ->
        parse_mapped_option(:format, value, @formats, {:invalid_format, value, @format_names})

      [key | _rest] ->
        {:error, {:unknown_option, key}}
    end
  end

  defp parse_mapped_option(field, value, values, error) do
    case Map.fetch(values, value) do
      {:ok, parsed_value} -> {:ok, field, parsed_value}
      :error -> {:error, error}
    end
  end

  defp parse_focus(value) do
    case Map.fetch(@focus_anchors, value) do
      {:ok, focus} -> {:ok, :focus, focus}
      :error -> {:error, {:invalid_focus, value}}
    end
  end

  defp parse_focus_coordinate(x, y) do
    with {:ok, parsed_x} <- parse_length(x),
         {:ok, parsed_y} <- parse_length(y) do
      {:ok, :focus, {:coordinate, parsed_x, parsed_y}}
    end
  end

  defp parse_positive_pixels(value) do
    with {:ok, integer} <- parse_positive_integer(value) do
      {:ok, {:pixels, integer}}
    end
  end

  defp parse_length(value) do
    case String.split_at(value, -1) do
      {number, "p"} ->
        with {:ok, integer} <- parse_non_negative_integer(number) do
          {:ok, {:percent, integer}}
        end

      _ ->
        with {:ok, integer} <- parse_non_negative_integer(value) do
          {:ok, {:pixels, integer}}
        end
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end
end
