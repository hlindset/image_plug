defmodule ImagePlug.Source.HTTP do
  @moduledoc false

  @behaviour ImagePlug.Source

  alias ImagePlug.Plan.Source.URL
  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.Source.StreamError

  @internal_option_keys [:url, :base_url, :method, :body, :params, :into, :retry, :max_redirects]
  @host_header_names ["host"]
  @cacheable_byte_header_names ["range", "accept", "accept-encoding"]
  @default_ports %{http: 80, https: 443}

  @options_schema NimbleOptions.new!(
                    allowed_hosts: [type: {:list, :string}, required: true],
                    req_options: [type: :keyword_list, default: []],
                    receive_timeout: [type: :non_neg_integer],
                    connect_timeout: [type: :non_neg_integer],
                    pool_timeout: [type: :non_neg_integer],
                    max_redirects: [type: :non_neg_integer, default: 0],
                    cache: [type: {:in, [:normal, :skip]}, default: :normal]
                  )

  @impl Source
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @impl Source
  def resolve(%URL{scheme: scheme} = source, opts, _runtime_opts)
      when scheme in [:http, :https] do
    host = String.downcase(source.host)

    if host in Keyword.fetch!(opts, :allowed_hosts) do
      port = source.port || Map.fetch!(@default_ports, scheme)

      {:ok,
       %Resolved{
         adapter: scheme,
         source_kind: :url,
         identity: [
           kind: :url,
           adapter: scheme,
           scheme: scheme,
           host: host,
           port: port,
           path: source.path,
           query: source.query
         ],
         cache: Keyword.fetch!(opts, :cache),
         fetch: [
           url: build_url(%{source | host: host, port: port}),
           cache: Keyword.fetch!(opts, :cache)
         ]
       }}
    else
      {:error, {:source, :denied_host}}
    end
  end

  @impl Source
  def fetch(%Resolved{fetch: fetch}, opts, _runtime_opts) do
    req_options =
      opts
      |> Keyword.fetch!(:req_options)
      |> sanitize_req_options(fetch[:cache])
      |> Keyword.merge(url: fetch[:url], method: :get, max_redirects: 0)

    {:ok, %Response{stream: request_stream(req_options)}}
  end

  defp request_stream(req_options) do
    Stream.resource(
      fn -> :start end,
      fn
        :done ->
          {:halt, :done}

        :start ->
          case Req.get(req_options) do
            {:ok, %{status: status, body: body}} when status in 200..299 ->
              {[body], :done}

            {:ok, _response} ->
              raise StreamError, reason: :bad_status

            {:error, _reason} ->
              raise StreamError, reason: :bad_status
          end
      end,
      fn _state -> :ok end
    )
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

  defp denied_header_names(:normal), do: @host_header_names ++ @cacheable_byte_header_names
  defp denied_header_names(:skip), do: @host_header_names

  defp build_url(%URL{} = source) do
    path =
      source.path
      |> Enum.map(fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
      |> Enum.join("/")

    path = "/" <> path
    port = source.port || Map.fetch!(@default_ports, source.scheme)
    authority = source.host <> port_suffix(source.scheme, port)
    query = if is_binary(source.query), do: "?" <> source.query, else: ""

    "#{source.scheme}://#{authority}#{path}#{query}"
  end

  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
