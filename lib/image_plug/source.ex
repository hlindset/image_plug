defmodule ImagePlug.Source do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Plan, ImagePlug.Telemetry],
    exports: [
      Resolved,
      Response,
      StreamError
    ]

  alias ImagePlug.Plan.Source, as: PlanSource
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
  def resolve(source, opts, runtime_opts) when is_list(opts) and is_list(runtime_opts) do
    with {:ok, adapter, source_kind} <- source_adapter(source),
         {:ok, module, adapter_opts} <- fetch_adapter_config(adapter, opts) do
      source_metadata =
        source_metadata(source_kind, source_adapter_kind(module, adapter_opts))

      Telemetry.span(runtime_opts, [:source, :resolve], source_metadata, fn ->
        result =
          safe_adapter_call(fn ->
            case module.resolve(source, adapter_opts, runtime_opts) do
              {:ok, %Resolved{} = resolved} -> validate_resolved(resolved, adapter)
              {:error, {:source, _reason}} = error -> error
              _other -> {:error, {:source, :invalid_adapter_result}}
            end
          end)

        {result, result_metadata(result)}
      end)
    end
  end

  @spec fetch(Resolved.t(), keyword(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def fetch(%Resolved{} = resolved, opts, runtime_opts)
      when is_list(opts) and is_list(runtime_opts) do
    with :ok <- validate_resolved_for_fetch(resolved),
         {:ok, module, adapter_opts} <- fetch_adapter_config(resolved.adapter, opts) do
      source_metadata =
        source_metadata(resolved.source_kind, source_adapter_kind(module, adapter_opts))

      Telemetry.span(runtime_opts, [:source, :fetch], source_metadata, fn ->
        result =
          safe_adapter_call(fn ->
            case module.fetch(resolved, adapter_opts, runtime_opts) do
              {:ok, %Response{} = response} -> wrap_response(response, runtime_opts)
              {:error, {:source, _reason}} = error -> error
              _other -> {:error, {:source, :invalid_adapter_result}}
            end
          end)

        {result, result_metadata(result)}
      end)
    end
  end

  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{stream: stream}, runtime_opts) when is_list(runtime_opts) do
    max_body_bytes = Keyword.get(runtime_opts, :max_body_bytes, :infinity)
    {:ok, %Response{stream: %WrappedStream{stream: stream, max_body_bytes: max_body_bytes}}}
  end

  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}

  defp validate_sources(sources) when is_list(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn
      {adapter, {module, adapter_opts}}, {:ok, source_configs}
      when is_atom(adapter) and is_atom(module) and is_list(adapter_opts) ->
        case safe_adapter_call(fn -> module.validate_options(adapter_opts) end) do
          {:ok, validated_opts} when is_list(validated_opts) ->
            ordered_opts = order_validated_options(adapter_opts, validated_opts)
            {:cont, {:ok, Map.put(source_configs, adapter, {module, ordered_opts})}}

          {:error, {:source, _reason}} = error ->
            {:halt, error}

          _other ->
            {:halt, {:error, {:source, :invalid_adapter_config}}}
        end

      _entry, _acc ->
        {:halt, {:error, {:source, :invalid_adapter_config}}}
    end)
  end

  defp validate_sources(_sources), do: {:error, {:source, :invalid_adapter_config}}

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

  defp source_adapter(%PlanSource.Path{}), do: {:ok, :path, :path}
  defp source_adapter(%PlanSource.URL{scheme: :http}), do: {:ok, :http, :url}
  defp source_adapter(%PlanSource.URL{scheme: :https}), do: {:ok, :https, :url}

  defp source_adapter(%PlanSource.Object{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :object}

  defp source_adapter(%PlanSource.Reference{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :reference}

  defp source_adapter(_source), do: {:error, {:source, :missing_adapter}}

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
      primitive?(identity)
  end

  defp primitive?(value)
       when is_atom(value) or is_binary(value) or is_boolean(value) or is_integer(value) or
              is_float(value) or is_nil(value),
       do: true

  defp primitive?(value) when is_list(value), do: primitive_list?(value)

  defp primitive?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> primitive_list?()
  end

  defp primitive?(%_{}), do: false

  defp primitive?(value) when is_map(value) do
    Enum.all?(value, fn {key, map_value} -> primitive?(key) and primitive?(map_value) end)
  end

  defp primitive?(_value), do: false

  defp primitive_list?([]), do: true
  defp primitive_list?([value | rest]), do: primitive?(value) and primitive_list?(rest)
  defp primitive_list?(_value), do: false

  defp source_metadata(source_kind, source_adapter_kind) do
    %{source_kind: source_kind, source_adapter_kind: source_adapter_kind}
  end

  defp source_adapter_kind(ImagePlug.Source.HTTP, _opts), do: :http
  defp source_adapter_kind(ImagePlug.Source.File, _opts), do: :file
  defp source_adapter_kind(ImagePlug.Source.S3, _opts), do: :s3
  defp source_adapter_kind(_module, opts), do: Keyword.get(opts, :telemetry_kind, :custom)

  defp result_metadata({:ok, _value}), do: %{result: :ok}
  defp result_metadata({:error, reason}), do: %{result: Telemetry.error(reason)}

  defp safe_adapter_call(fun) when is_function(fun, 0) do
    fun.()
  rescue
    _error -> {:error, {:source, :adapter_exception}}
  catch
    _kind, _reason -> {:error, {:source, :adapter_exception}}
  end
end
