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

  @type build_error ::
          :missing_selected_output_format
          | :missing_selected_output_reason
          | {:invalid_selected_output_format, term()}
          | {:invalid_selected_output_reason, term()}

  @spec build(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, build_error()}
  def build(conn, %ProcessingRequest{} = request, origin_identity, opts \\ [])
      when is_binary(origin_identity) and is_list(opts) do
    with {:ok, output} <- output(request, opts) do
      material = [
        schema_version: @schema_version,
        origin_identity: origin_identity,
        operations: operations(request),
        output: output,
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

  defp output(%ProcessingRequest{format: nil}, opts) do
    with {:ok, format} <- selected_output_format(opts),
         {:ok, reason} <- selected_output_reason(opts) do
      {:ok, [format: format, automatic: true, selection: reason]}
    end
  end

  defp output(%ProcessingRequest{format: format}, _opts) do
    {:ok, [format: format, automatic: false]}
  end

  defp selected_output_format(opts) do
    case Keyword.fetch(opts, :selected_output_format) do
      {:ok, format} when format in [:avif, :webp, :jpeg, :png] ->
        {:ok, format}

      {:ok, format} ->
        {:error, {:invalid_selected_output_format, format}}

      :error ->
        {:error, :missing_selected_output_format}
    end
  end

  defp selected_output_reason(opts) do
    case Keyword.fetch(opts, :selected_output_reason) do
      {:ok, reason} when reason in [:auto, :source, :fallback] ->
        {:ok, reason}

      {:ok, reason} ->
        {:error, {:invalid_selected_output_reason, reason}}

      :error ->
        {:error, :missing_selected_output_reason}
    end
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
