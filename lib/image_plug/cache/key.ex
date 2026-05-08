defmodule ImagePlug.Cache.Key do
  @moduledoc """
  Deterministic cache key material for processed image responses.
  """

  import Plug.Conn, only: [fetch_cookies: 1, get_req_header: 2]

  alias ImagePlug.Output.Negotiation
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform.Material

  @schema_version 2
  @enforce_keys [:hash, :material, :serialized_material]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          material: keyword(),
          serialized_material: binary()
        }

  @spec build(Plug.Conn.t(), Plan.t(), String.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(conn, %Plan{} = plan, origin_identity, opts \\ [])
      when is_binary(origin_identity) and is_list(opts) do
    with {:ok, source} <- source_material(plan.source),
         {:ok, pipelines} <- pipelines_material(plan.pipelines),
         {:ok, output} <- output_material(conn, plan.output, opts),
         {:ok, cache} <- cache_material(plan.cache) do
      material = [
        schema_version: @schema_version,
        origin_identity: origin_identity,
        source: source,
        pipelines: pipelines,
        output: output,
        cache: cache,
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

  defp source_material(%Plain{path: path}), do: {:ok, [kind: :plain, path: path]}
  defp source_material(source), do: {:error, {:unsupported_source, source}}

  defp pipelines_material(pipelines) do
    {:ok,
     Enum.map(pipelines, fn %Pipeline{operations: operations} ->
       Enum.map(operations, &operation_material/1)
     end)}
  end

  defp operation_material(operation) do
    Material.material(operation)
  end

  defp output_material(conn, %Output{mode: :automatic} = output, opts) do
    accept_header = conn |> get_req_header("accept") |> Enum.join(",")

    {:ok,
     [
       mode: :automatic,
       modern_candidates: Negotiation.modern_candidates(accept_header, opts),
       auto: [
         avif: Keyword.get(opts, :auto_avif, true),
         webp: Keyword.get(opts, :auto_webp, true)
       ],
       quality: output.quality,
       format_qualities: output.format_qualities
     ]}
  end

  defp output_material(_conn, %Output{mode: {:explicit, format}} = output, _opts) do
    {:ok,
     [
       mode: :explicit,
       format: format,
       quality: output.quality,
       format_qualities: output.format_qualities
     ]}
  end

  defp output_material(_conn, output, _opts) do
    {:error, {:invalid_output_plan, output}}
  end

  defp cache_material(%Cache{cachebuster: cachebuster})
       when is_binary(cachebuster) or is_nil(cachebuster) do
    {:ok, [cachebuster: cachebuster]}
  end

  defp cache_material(cache), do: {:error, {:invalid_cache_plan, cache}}

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
    Base.encode16(:crypto.hash(:sha256, serialized_material), case: :lower)
  end
end
