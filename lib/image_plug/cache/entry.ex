defmodule ImagePlug.Cache.Entry do
  @moduledoc """
  Adapter-independent cached response entry.
  """

  @allowed_headers ~w(vary cache-control)
  @enforce_keys [:body, :content_type, :headers, :created_at]
  @header_name_pattern ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/
  @header_value_pattern ~r/^[^\x00-\x1F\x7F]*$/

  defstruct @enforce_keys

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          body: binary(),
          content_type: String.t(),
          headers: [header()],
          created_at: DateTime.t()
        }

  @spec cacheable_headers(term()) :: {:ok, [header()]} | {:error, term()}
  def cacheable_headers(headers) when is_list(headers) do
    case Enum.reduce_while(headers, {:ok, []}, &normalize_header(&1, &2, headers)) do
      {:ok, normalized_headers} -> {:ok, Enum.reverse(normalized_headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def cacheable_headers(headers), do: {:error, {:invalid_headers, headers}}

  defp normalize_header({name, value}, {:ok, normalized_headers}, headers)
       when is_binary(name) and is_binary(value) do
    if valid_header_name?(name) and valid_header_value?(value) do
      {:cont, {:ok, maybe_add_allowed_header(normalized_headers, String.downcase(name), value)}}
    else
      {:halt, {:error, {:invalid_headers, headers}}}
    end
  end

  defp normalize_header(_header, _acc, headers) do
    {:halt, {:error, {:invalid_headers, headers}}}
  end

  defp maybe_add_allowed_header(normalized_headers, name, value) do
    if name in @allowed_headers,
      do: [{name, value} | normalized_headers],
      else: normalized_headers
  end

  defp valid_header_name?(name), do: Regex.match?(@header_name_pattern, name)
  defp valid_header_value?(value), do: Regex.match?(@header_value_pattern, value)
end
