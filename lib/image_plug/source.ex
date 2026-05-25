defmodule ImagePlug.Source do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Error, ImagePlug.Plan, ImagePlug.Telemetry],
    exports: [
      Resolved,
      Response,
      StreamError,
      HTTP,
      File,
      S3
    ]

  alias ImagePlug.Plan.Source, as: PlanSource
  alias ImagePlug.Plan.Source.Identity
  alias ImagePlug.Error
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.Source.WrappedStream
  alias ImagePlug.Telemetry

  @type error :: {:source, atom() | tuple()}

  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  @callback resolve(PlanSource.t(), keyword(), keyword()) ::
              {:ok, Resolved.t()} | {:error, error()}
  @callback fetch(Resolved.t(), keyword(), keyword()) :: {:ok, Response.t()} | {:error, error()}

  @source_kinds [:path, :url, :object, :reference]
  @cache_policies [:normal, :skip]

  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, error()}
  def validate_config(opts) when is_list(opts) do
    with {:ok, sources} <- validate_sources(Keyword.get(opts, :sources, [])) do
      {:ok, Keyword.put(opts, :sources, sources)}
    end
  end

  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} ->
        opts

      {:error, reason} ->
        raise ArgumentError, "invalid ImagePlug source options: #{inspect(reason)}"
    end
  end

  @spec resolve(PlanSource.t(), keyword(), keyword()) :: {:ok, Resolved.t()} | {:error, error()}
  def resolve(source, opts, runtime_opts) do
    with {:ok, adapter, source_kind} <- source_route(source),
         {:ok, module, adapter_opts} <- fetch_adapter_config(adapter, opts) do
      source_metadata = source_metadata(source_kind, adapter_opts)

      telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

      Telemetry.span(telemetry_opts, [:source, :resolve], source_metadata, fn ->
        result =
          case module.resolve(source, adapter_opts, runtime_opts) do
            {:ok, %Resolved{} = resolved} -> validate_resolved(resolved, adapter)
            {:error, {:source, _reason}} = error -> error
            _other -> {:error, {:source, :invalid_adapter_result}}
          end

        {result, result_metadata(result)}
      end)
    end
  end

  @spec fetch(Resolved.t(), keyword(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    with :ok <- validate_resolved_for_fetch(resolved),
         {:ok, module, adapter_opts} <- fetch_adapter_config(resolved.adapter, opts) do
      source_metadata = source_metadata(resolved.source_kind, adapter_opts)

      telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

      Telemetry.span(telemetry_opts, [:source, :fetch], source_metadata, fn ->
        result =
          case module.fetch(resolved, adapter_opts, runtime_opts) do
            {:ok, %Response{} = response} -> wrap_response(response, runtime_opts)
            {:error, {:source, _reason}} = error -> error
            _other -> {:error, {:source, :invalid_adapter_result}}
          end

        {result, result_metadata(result)}
      end)
    end
  end

  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{stream: stream}, runtime_opts) do
    max_body_bytes = Keyword.get(runtime_opts, :max_body_bytes, :infinity)
    {:ok, %Response{stream: %WrappedStream{stream: stream, max_body_bytes: max_body_bytes}}}
  end

  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}

  defp validate_sources(sources) when is_list(sources) do
    with {:ok, source_configs} <- source_configs(sources) do
      {:ok, expand_url_source_config(source_configs)}
    end
  end

  defp validate_sources(_sources), do: {:error, {:source, :invalid_adapter_config}}

  defp source_configs(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn entry, {:ok, source_configs} ->
      case source_config(entry) do
        {:ok, adapter, config} -> {:cont, {:ok, Map.put(source_configs, adapter, config)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp source_config({adapter, {module, adapter_opts}})
       when is_atom(adapter) and is_atom(module) and is_list(adapter_opts) do
    case module.validate_options(adapter_opts) do
      {:ok, validated_opts} when is_list(validated_opts) ->
        config = {module, order_validated_options(adapter_opts, validated_opts)}
        {:ok, adapter, config}

      {:error, {:source, _reason}} = error ->
        error

      _other ->
        {:error, {:source, :invalid_adapter_config}}
    end
  end

  defp source_config(_entry), do: {:error, {:source, :invalid_adapter_config}}

  defp expand_url_source_config(%{url: url_config} = source_configs) do
    source_configs
    |> Map.delete(:url)
    |> Map.put_new(:http, url_config)
    |> Map.put_new(:https, url_config)
  end

  defp expand_url_source_config(source_configs), do: source_configs

  defp order_validated_options(input_opts, validated_opts) do
    input_keys = Keyword.keys(input_opts)

    ordered_input_values =
      Enum.flat_map(input_keys, fn key ->
        case Keyword.fetch(validated_opts, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    extra_values =
      Enum.reject(validated_opts, fn {key, _value} ->
        key in input_keys
      end)

    ordered_input_values ++ extra_values
  end

  defp source_route(%PlanSource.Path{}), do: {:ok, :path, :path}
  defp source_route(%PlanSource.URL{scheme: :http}), do: {:ok, :http, :url}
  defp source_route(%PlanSource.URL{scheme: :https}), do: {:ok, :https, :url}

  defp source_route(%PlanSource.Object{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :object}

  defp source_route(%PlanSource.Reference{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :reference}

  defp source_route(_source), do: {:error, {:source, :missing_adapter}}

  defp fetch_adapter_config(adapter, opts) do
    case opts[:sources] do
      %{^adapter => {module, adapter_opts}} -> {:ok, module, adapter_opts}
      _sources -> {:error, {:source, :missing_adapter}}
    end
  end

  defp validate_resolved(%Resolved{adapter: adapter} = resolved, adapter) do
    if valid_resolved?(resolved),
      do: {:ok, resolved},
      else: {:error, {:source, :invalid_adapter_result}}
  end

  defp validate_resolved(%Resolved{}, _adapter), do: {:error, {:source, :invalid_adapter_result}}

  defp validate_resolved_for_fetch(%Resolved{} = resolved) do
    if valid_resolved?(resolved), do: :ok, else: {:error, {:source, :invalid_adapter_result}}
  end

  defp valid_resolved?(%Resolved{
         adapter: adapter,
         source_kind: source_kind,
         identity: identity,
         cache: cache
       }) do
    is_atom(adapter) and source_kind in @source_kinds and cache in @cache_policies and
      Identity.valid?(identity)
  end

  defp source_metadata(source_kind, adapter_opts) do
    %{
      source_kind: source_kind,
      source_adapter_kind: Keyword.get(adapter_opts, :telemetry_kind, :custom)
    }
  end

  defp result_metadata({:ok, _value}), do: %{result: :ok}

  defp result_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}
end
