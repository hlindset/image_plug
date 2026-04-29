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

  @spec new(term()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) do
    with {:ok, body} <- fetch_required(attrs, :body),
         :ok <- validate_body(body),
         {:ok, content_type} <- fetch_required(attrs, :content_type),
         {:ok, content_type} <- normalize_content_type(content_type),
         {:ok, headers} <- fetch_required(attrs, :headers),
         {:ok, headers} <- normalize_headers(headers),
         {:ok, created_at} <- fetch_required(attrs, :created_at),
         :ok <- validate_created_at(created_at) do
      {:ok,
       %__MODULE__{
         body: body,
         content_type: content_type,
         headers: headers,
         created_at: created_at
       }}
    end
  end

  def new(attrs), do: {:error, {:invalid_attrs, attrs}}

  @spec new!(keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "invalid cache entry: #{inspect(reason)}"
    end
  end

  @spec normalize_headers(term()) :: {:ok, [header()]} | {:error, term()}
  def normalize_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, normalized_headers} when is_binary(name) and is_binary(value) ->
        if valid_header_name?(name) and valid_header_value?(value) do
          name = String.downcase(name)

          normalized_headers =
            if name in @allowed_headers do
              [{name, value} | normalized_headers]
            else
              normalized_headers
            end

          {:cont, {:ok, normalized_headers}}
        else
          {:halt, {:error, {:invalid_headers, headers}}}
        end

      _header, _acc ->
        {:halt, {:error, {:invalid_headers, headers}}}
    end)
    |> case do
      {:ok, normalized_headers} -> {:ok, Enum.reverse(normalized_headers)}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_headers(headers), do: {:error, {:invalid_headers, headers}}

  defp fetch_required(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp validate_body(body) when is_binary(body), do: :ok
  defp validate_body(body), do: {:error, {:invalid_body, body}}

  defp normalize_content_type(content_type) when is_binary(content_type) do
    normalized =
      content_type
      |> String.trim()
      |> String.downcase()

    if normalized == "" do
      {:error, {:invalid_content_type, content_type}}
    else
      {:ok, normalized}
    end
  end

  defp normalize_content_type(content_type), do: {:error, {:invalid_content_type, content_type}}

  defp validate_created_at(%DateTime{}), do: :ok
  defp validate_created_at(created_at), do: {:error, {:invalid_created_at, created_at}}

  defp valid_header_name?(name), do: Regex.match?(@header_name_pattern, name)
  defp valid_header_value?(value), do: Regex.match?(@header_value_pattern, value)
end
