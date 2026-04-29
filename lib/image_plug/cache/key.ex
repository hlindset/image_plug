defmodule ImagePlug.Cache.Key do
  @moduledoc """
  Deterministic cache key material for processed image responses.
  """

  import Plug.Conn

  alias ImagePlug.ProcessingRequest

  @schema_version 1
  @enforce_keys [:hash, :material, :serialized_material]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          material: keyword(),
          serialized_material: binary()
        }

  @spec build(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: t()
  def build(conn, %ProcessingRequest{} = request, origin_identity, opts \\ [])
      when is_binary(origin_identity) and is_list(opts) do
    material = [
      schema_version: @schema_version,
      origin_identity: origin_identity,
      operations: operations(request),
      output: output(conn, request),
      selected_headers: selected_headers(conn, opts),
      selected_cookies: selected_cookies(conn, opts)
    ]

    serialized_material = serialize_material(material)

    %__MODULE__{
      hash: hash(serialized_material),
      material: material,
      serialized_material: serialized_material
    }
  end

  @spec serialize_material(term()) :: binary()
  def serialize_material(material) do
    material
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp operations(%ProcessingRequest{} = request) do
    [
      source_kind: request.source_kind,
      source_path: request.source_path,
      width: request.width,
      height: request.height,
      fit: request.fit,
      focus: request.focus
    ]
  end

  defp output(conn, %ProcessingRequest{format: :auto}) do
    accept =
      conn
      |> get_req_header("accept")
      |> Enum.join(",")
      |> normalize_accept()

    [format: :auto, accept: accept]
  end

  defp output(_conn, %ProcessingRequest{format: format}) do
    [format: format, accept: nil]
  end

  defp selected_headers(conn, opts) do
    opts
    |> Keyword.get(:key_headers, [])
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn name -> {name, get_req_header(conn, name)} end)
  end

  defp selected_cookies(conn, opts) do
    conn = fetch_cookies(conn)

    opts
    |> Keyword.get(:key_cookies, [])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case Map.fetch(conn.req_cookies, name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
  end

  defp normalize_accept(""), do: ""

  defp normalize_accept(accept) when is_binary(accept) do
    accept
    |> String.split(",", trim: true)
    |> Enum.map(&normalize_media_range/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp normalize_media_range(media_range) do
    [media_type | params] = String.split(media_range, ";")

    [
      media_type
      |> String.trim()
      |> String.downcase()
      | Enum.map(params, &normalize_accept_param/1)
    ]
    |> Enum.join(";")
  end

  defp normalize_accept_param(param) do
    case String.split(param, "=", parts: 2) do
      [name, value] ->
        String.downcase(String.trim(name)) <> "=" <> String.trim(value)

      [name] ->
        name
        |> String.trim()
        |> String.downcase()
    end
  end

  defp canonicalize(value) when is_list(value) do
    Enum.map(value, fn
      {key, item} -> {canonicalize(key), canonicalize(item)}
      item -> canonicalize(item)
    end)
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
    |> Enum.sort()
  end

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  defp canonicalize(value), do: value

  defp hash(serialized_material) do
    :crypto.hash(:sha256, serialized_material)
    |> Base.encode16(case: :lower)
  end
end
