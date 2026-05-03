defmodule ImagePlug.Cache.Key do
  @moduledoc """
  Deterministic cache key material for processed image responses.
  """

  import Plug.Conn

  alias ImagePlug.OutputNegotiation
  alias ImagePlug.ProcessingRequest

  @schema_version 1
  @enforce_keys [:hash, :material, :serialized_material]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          material: keyword(),
          serialized_material: binary()
        }

  @spec build(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) ::
          {:ok, t()}
  def build(conn, %ProcessingRequest{} = request, origin_identity, opts \\ [])
      when is_binary(origin_identity) and is_list(opts) do
    material = [
      schema_version: @schema_version,
      origin_identity: origin_identity,
      operations: operations(request),
      output: output(conn, request, opts),
      selected_headers: selected_headers(conn, opts),
      selected_cookies: selected_cookies(conn, opts)
    ]

    serialized_material = serialize_material(material)

    {:ok,
     %__MODULE__{
       hash: hash(serialized_material),
       material: material,
       serialized_material: serialized_material
     }}
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
      resizing_type: request.resizing_type,
      enlarge: request.enlarge,
      extend: request.extend,
      extend_gravity: request.extend_gravity,
      extend_x_offset: request.extend_x_offset,
      extend_y_offset: request.extend_y_offset,
      gravity: request.gravity,
      gravity_x_offset: request.gravity_x_offset,
      gravity_y_offset: request.gravity_y_offset
    ]
  end

  defp output(conn, %ProcessingRequest{format: nil}, opts) do
    accept_header = conn |> get_req_header("accept") |> Enum.join(",")

    [
      mode: :automatic,
      modern_candidates: OutputNegotiation.modern_candidates(accept_header, opts),
      auto: [
        avif: Keyword.get(opts, :auto_avif, true),
        webp: Keyword.get(opts, :auto_webp, true)
      ]
    ]
  end

  defp output(_conn, %ProcessingRequest{format: format}, _opts) do
    [mode: :explicit, format: format]
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

  defp canonicalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
    else
      Enum.map(value, &canonicalize/1)
    end
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
