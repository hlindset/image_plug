defmodule ImagePlug.Source.S3 do
  @moduledoc false

  @behaviour ImagePlug.Source

  alias ImagePlug.Plan.Source.Object
  alias ImagePlug.Source
  alias ImagePlug.Source.ReqStream
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.Source.S3.Credentials

  @internal_option_keys [
    :url,
    :base_url,
    :method,
    :body,
    :params,
    :into,
    :retry,
    :redirect,
    :max_redirects,
    :auth,
    :aws_sigv4
  ]
  @signed_header_names ["authorization", "host", "x-amz-content-sha256", "x-amz-security-token"]
  @cacheable_byte_header_names ["range", "accept", "accept-encoding"]
  @config_keys [:region, :endpoint, :credentials, :req_options, :cache]

  @impl Source
  def validate_options(opts) when is_list(opts) do
    with {:ok, default} <- validate_default(Keyword.get(opts, :default, [])),
         {:ok, buckets} <- validate_buckets(Keyword.get(opts, :buckets, nil), default),
         :ok <- validate_top_level_keys(opts) do
      {:ok, [default: default, buckets: buckets]}
    end
  end

  def validate_options(_opts), do: {:error, {:invalid_source_config, :invalid_options}}

  @impl Source
  def resolve(
        %Object{adapter: :s3, scope: bucket, key: key, revision: revision},
        opts,
        _runtime_opts
      )
      when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" and
             (is_binary(revision) or is_nil(revision)) do
    with {:ok, config} <- bucket_config(bucket, opts) do
      endpoint = Keyword.fetch!(config, :endpoint)

      {:ok,
       %Resolved{
         adapter: :s3,
         source_kind: :object,
         identity: [
           kind: :object,
           adapter: :s3,
           endpoint: endpoint,
           bucket: bucket,
           key: key,
           revision: revision
         ],
         cache: Keyword.fetch!(config, :cache),
         fetch: [
           endpoint: endpoint,
           bucket: bucket,
           key: key,
           revision: revision,
           region: Keyword.fetch!(config, :region),
           credentials: Keyword.get(config, :credentials),
           req_options: Keyword.fetch!(config, :req_options),
           cache: Keyword.fetch!(config, :cache)
         ]
       }}
    end
  end

  def resolve(%Object{adapter: :s3}, _opts, _runtime_opts),
    do: {:error, {:source, :invalid_object}}

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, runtime_opts) do
    with {:ok, credentials} <-
           Credentials.fetch(fetch[:bucket], fetch[:credentials], runtime_opts) do
      req_options =
        fetch
        |> Keyword.fetch!(:req_options)
        |> sanitize_req_options(fetch[:cache])
        |> Keyword.merge(
          url: build_url(fetch),
          method: :get,
          max_redirects: 0,
          aws_sigv4: aws_sigv4_options(fetch[:region], credentials)
        )

      {:ok, %Response{stream: ReqStream.stream(req_options, runtime_opts)}}
    end
  end

  defp validate_top_level_keys(opts) do
    case Keyword.keys(opts) -- [:default, :buckets] do
      [] -> :ok
      [_key | _rest] -> {:error, {:invalid_source_config, :unknown_option}}
    end
  end

  defp validate_default(opts) when is_list(opts), do: validate_config(opts, require_core?: true)
  defp validate_default(_opts), do: {:error, {:invalid_source_config, :invalid_default}}

  defp validate_buckets(nil, default) do
    with :ok <- require_credentials(default) do
      {:ok, nil}
    end
  end

  defp validate_buckets(buckets, default) when is_map(buckets) do
    buckets
    |> Enum.reduce_while({:ok, %{}}, fn
      {bucket, opts}, {:ok, acc} when is_binary(bucket) and bucket != "" and is_list(opts) ->
        merged = Keyword.merge(default, opts)

        case validate_config(merged, require_core?: true) do
          {:ok, config} ->
            case require_credentials(config) do
              :ok -> {:cont, {:ok, Map.put(acc, bucket, config)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, {:invalid_source_config, :invalid_bucket_config}}}
    end)
  end

  defp validate_buckets(_buckets, _default),
    do: {:error, {:invalid_source_config, :invalid_bucket_config}}

  defp validate_config(opts, require_core?: true) do
    with :ok <- validate_config_keys(opts),
         {:ok, endpoint} <- validate_endpoint(Keyword.get(opts, :endpoint)),
         {:ok, region} <- validate_region(Keyword.get(opts, :region)),
         {:ok, credentials} <- validate_optional_credentials(Keyword.get(opts, :credentials)),
         {:ok, req_options} <- validate_req_options(Keyword.get(opts, :req_options, [])),
         {:ok, cache} <- validate_cache(Keyword.get(opts, :cache, :normal)) do
      config = [region: region, endpoint: endpoint, req_options: req_options, cache: cache]
      {:ok, maybe_put_credentials(config, credentials)}
    end
  end

  defp validate_config_keys(opts) do
    case Keyword.keys(opts) -- @config_keys do
      [] -> :ok
      [_key | _rest] -> {:error, {:invalid_source_config, :unknown_option}}
    end
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    case uri do
      %URI{
        scheme: scheme,
        host: host,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      }
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        with :ok <- validate_endpoint_port(endpoint, scheme) do
          {:ok, String.trim_trailing(endpoint, "/")}
        end

      _uri ->
        {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  defp validate_endpoint(_endpoint), do: {:error, {:invalid_source_config, :invalid_endpoint}}

  defp validate_endpoint_port(endpoint, scheme) do
    endpoint
    |> String.replace_prefix(scheme <> "://", "")
    |> endpoint_authority()
    |> validate_authority_port()
  end

  defp endpoint_authority(rest) do
    rest
    |> String.split(["/", "?", "#"], parts: 2)
    |> hd()
  end

  defp validate_authority_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [_host, ""] -> :ok
      [_host, ":" <> port] -> validate_port(port)
      _other -> {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  defp validate_authority_port(authority) do
    case String.split(authority, ":", parts: 2) do
      [_host] -> :ok
      [_host, port] -> validate_port(port)
    end
  end

  defp validate_port(port) do
    if String.match?(port, ~r/^[0-9]+$/) do
      case Integer.parse(port) do
        {port, ""} when port in 1..65_535 -> :ok
        _invalid -> {:error, {:invalid_source_config, :invalid_endpoint}}
      end
    else
      {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  defp validate_region(region) when is_binary(region) and region != "", do: {:ok, region}
  defp validate_region(_region), do: {:error, {:invalid_source_config, :invalid_region}}

  defp validate_optional_credentials(nil), do: {:ok, nil}
  defp validate_optional_credentials(credentials), do: Credentials.validate(credentials)

  defp require_credentials(config) do
    if Keyword.has_key?(config, :credentials) do
      :ok
    else
      {:error, {:invalid_source_config, :missing_credentials}}
    end
  end

  defp validate_req_options(req_options) when is_list(req_options), do: {:ok, req_options}

  defp validate_req_options(_req_options),
    do: {:error, {:invalid_source_config, :invalid_req_options}}

  defp validate_cache(cache) when cache in [:normal, :skip], do: {:ok, cache}
  defp validate_cache(_cache), do: {:error, {:invalid_source_config, :invalid_cache}}

  defp maybe_put_credentials(config, nil), do: config

  defp maybe_put_credentials(config, credentials),
    do: Keyword.put(config, :credentials, credentials)

  defp bucket_config(bucket, opts) do
    case Keyword.fetch!(opts, :buckets) do
      nil ->
        {:ok, Keyword.fetch!(opts, :default)}

      buckets ->
        case Map.fetch(buckets, bucket) do
          {:ok, config} -> {:ok, config}
          :error -> {:error, {:source, :denied_bucket}}
        end
    end
  end

  defp sanitize_req_options(req_options, cache) do
    req_options
    |> Keyword.drop(@internal_option_keys)
    |> Keyword.update(:headers, [], &sanitize_headers(&1, cache))
  end

  defp sanitize_headers(headers, cache) do
    denied = denied_header_names(cache)

    Enum.reject(headers, fn {name, _value} ->
      String.downcase(to_string(name)) in denied
    end)
  end

  defp denied_header_names(:normal), do: @signed_header_names ++ @cacheable_byte_header_names
  defp denied_header_names(:skip), do: @signed_header_names

  defp aws_sigv4_options(region, credentials) do
    credentials
    |> Keyword.put(:service, :s3)
    |> Keyword.put(:region, region)
  end

  defp build_url(fetch) do
    endpoint = Keyword.fetch!(fetch, :endpoint)
    bucket = Keyword.fetch!(fetch, :bucket)
    key = Keyword.fetch!(fetch, :key)
    revision = Keyword.get(fetch, :revision)

    IO.iodata_to_binary([
      endpoint,
      "/",
      encode_path_segment(bucket),
      "/",
      encode_key(key),
      revision_query(revision)
    ])
  end

  defp encode_key(key) do
    key
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &encode_path_segment/1)
  end

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp revision_query(nil), do: ""

  defp revision_query(revision),
    do: ["?versionId=", URI.encode(revision, &URI.char_unreserved?/1)]
end
