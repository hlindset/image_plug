defmodule ImagePlug.Cache.Key do
  @moduledoc """
  Deterministic cache key data for processed image responses.
  """

  import Plug.Conn, only: [fetch_cookies: 1, get_req_header: 2]

  alias ImagePlug.Output.Negotiation
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.KeyData
  alias ImagePlug.Plan.Source.Identity

  @schema_version 2
  @transform_key_data_version 1
  @enforce_keys [:hash, :data, :serialized_data]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hash: String.t(),
          data: keyword(),
          serialized_data: binary()
        }

  @spec build(Plug.Conn.t(), Plan.t(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(conn, %Plan{} = plan, source_identity, opts \\ []) when is_list(opts) do
    with :ok <- validate_source_identity(source_identity),
         {:ok, pipelines} <- pipelines_data(plan.pipelines),
         {:ok, output} <- output_data(conn, plan.output, opts),
         {:ok, cache} <- cache_data(plan.cachebuster) do
      data = [
        schema_version: @schema_version,
        source_identity: source_identity,
        pipelines: pipelines,
        transform: transform_data(),
        output: output,
        cache: cache,
        selected_headers: selected_headers(conn, opts),
        selected_cookies: selected_cookies(conn, opts)
      ]

      serialized_data = serialize_key_data(data)

      {:ok,
       %__MODULE__{
         hash: hash(serialized_data),
         data: data,
         serialized_data: serialized_data
       }}
    end
  end

  @spec serialize_key_data(term()) :: binary()
  def serialize_key_data(key_data) do
    key_data
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp validate_source_identity(identity) do
    if Identity.valid?(identity),
      do: :ok,
      else: {:error, {:invalid_source_identity, identity}}
  end

  defp pipelines_data(pipelines) do
    {:ok,
     Enum.map(pipelines, fn %Pipeline{operations: operations} ->
       Enum.map(operations, &KeyData.data/1)
     end)}
  end

  defp transform_data, do: [key_data_version: @transform_key_data_version]

  defp output_data(conn, %Output{mode: :automatic} = output, opts) do
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

  defp output_data(_conn, %Output{mode: {:explicit, format}} = output, _opts) do
    {:ok,
     [
       mode: :explicit,
       format: format,
       quality: output.quality,
       format_qualities: output.format_qualities
     ]}
  end

  defp output_data(_conn, output, _opts) do
    {:error, {:invalid_output_plan, output}}
  end

  defp cache_data(cachebuster) when is_binary(cachebuster) or is_nil(cachebuster) do
    {:ok, [cachebuster: cachebuster]}
  end

  defp cache_data(cachebuster), do: {:error, {:invalid_cachebuster, cachebuster}}

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

  defp hash(serialized_data) do
    Base.encode16(:crypto.hash(:sha256, serialized_data), case: :lower)
  end
end
