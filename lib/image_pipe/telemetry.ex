defmodule ImagePipe.Telemetry do
  @moduledoc """
  Telemetry helpers and an opt-in default Logger handler for ImagePipe.

  ImagePipe emits `:telemetry` events only. Hosts attach their own handlers
  (metrics, OpenTelemetry, APM). For convenience, `attach_default_logger/1`
  attaches a stdlib `Logger` handler covering ImagePipe's events.
  """

  use Boundary,
    top_level?: true,
    deps: [],
    exports: [Trace, Trace.Stack, Trace.Context]

  alias ImagePipe.Telemetry.Logger, as: DefaultLogger
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.Capture

  @default_prefix [:image_pipe]

  @valid_levels Logger.levels()

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

  @doc """
  Attach the default `Logger` handler for ImagePipe telemetry. Opt-in and
  idempotent.

  Raises `ArgumentError` on invalid options. This is host-startup configuration,
  so it raises (matching `Oban.Telemetry.attach_default_logger` /
  `Phoenix.Logger`) rather than returning a tagged error.

  Options:
    * `:level` — base log level (default `:info`); errors/exceptions escalate to `:warning`.
    * `:events` — `:all` (default) or a list of `[:request, :parse, :source, :transform, :cache]`.
    * `:prefix` — telemetry event prefix list (default `#{inspect(@default_prefix)}`).
    * `:debug` — when `true`, also log the full raw measurements/metadata (default `false`).
  """
  @spec attach_default_logger(keyword()) :: :ok
  def attach_default_logger(opts \\ []) when is_list(opts) do
    :ok = validate_logger_opts(opts)

    case DefaultLogger.attach(opts) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the default Logger handler."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: DefaultLogger.detach()

  defp validate_logger_opts(opts) do
    known = [:level, :events, :prefix, :debug]

    with [] <- Keyword.keys(opts) -- known,
         :ok <- validate_events(Keyword.get(opts, :events, :all)),
         :ok <- validate_level(Keyword.get(opts, :level, :info)),
         :ok <- validate_debug(Keyword.get(opts, :debug, false)) do
      validate_prefix(Keyword.get(opts, :prefix, @default_prefix))
    else
      unknown when is_list(unknown) ->
        raise ArgumentError, "unknown attach_default_logger options: #{inspect(unknown)}"
    end
  end

  defp validate_events(:all), do: :ok

  defp validate_events(groups) when is_list(groups) do
    case groups -- DefaultLogger.all_groups() do
      [] -> :ok
      bad -> raise ArgumentError, "unknown telemetry logger event groups: #{inspect(bad)}"
    end
  end

  defp validate_events(other),
    do: raise(ArgumentError, ":events must be :all or a list, got: #{inspect(other)}")

  defp validate_level(level) when level in @valid_levels, do: :ok

  defp validate_level(other),
    do: raise(ArgumentError, ":level must be a valid Logger level, got: #{inspect(other)}")

  defp validate_debug(debug) when is_boolean(debug), do: :ok

  defp validate_debug(other),
    do: raise(ArgumentError, ":debug must be a boolean, got: #{inspect(other)}")

  defp validate_prefix(prefix) when is_list(prefix) and prefix != [] do
    if Enum.all?(prefix, &is_atom/1) do
      :ok
    else
      raise ArgumentError, ":prefix must be a non-empty list of atoms, got: #{inspect(prefix)}"
    end
  end

  defp validate_prefix(other),
    do: raise(ArgumentError, ":prefix must be a non-empty list of atoms, got: #{inspect(other)}")

  @doc "Attach the opt-in span tracer. See `ImagePipe.Telemetry.Trace`."
  @spec attach_tracer(keyword()) :: :ok
  def attach_tracer(opts) do
    exporter = Keyword.fetch!(opts, :exporter)
    prefix = Keyword.get(opts, :prefix, default_prefix())

    Trace.set_exporter(exporter)
    Trace.set_extract_inbound(Keyword.get(opts, :extract_inbound, false))
    Capture.attach(%{prefix: prefix, exporter: exporter})
  end

  @spec detach_tracer() :: :ok
  def detach_tracer do
    Capture.detach()
    Trace.set_exporter(nil)
    Trace.set_extract_inbound(false)
    :ok
  end

  @spec span(keyword(), [atom()], map() | keyword(), (-> term())) :: term()
  def span(telemetry_opts, stage, start_metadata, fun) when is_function(fun, 0) do
    do_span(telemetry_opts, stage, start_metadata, fn start_metadata ->
      {result, stop_metadata} = fun.()
      {result, merge_metadata(start_metadata, stop_metadata)}
    end)
  end

  @spec execute(keyword(), [atom()], map() | keyword(), map() | keyword()) :: :ok
  def execute(telemetry_opts, stage, measurements, metadata) when is_list(stage) do
    telemetry_opts
    |> event_prefix(stage)
    |> :telemetry.execute(Map.new(measurements), clean_metadata(metadata))
  end

  @spec telemetry_opts(keyword()) :: keyword()
  def telemetry_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:telemetry_prefix])
  end

  defp do_span(telemetry_opts, stage, start_metadata, span_fun) when is_list(stage) do
    start_metadata = clean_metadata(start_metadata)

    :telemetry.span(event_prefix(telemetry_opts, stage), start_metadata, fn ->
      span_fun.(start_metadata)
    end)
  end

  defp event_prefix(telemetry_opts, stage) when is_list(telemetry_opts) and is_list(stage) do
    Keyword.get(telemetry_opts, :telemetry_prefix, @default_prefix) ++ stage
  end

  defp clean_metadata(metadata) do
    metadata
    |> Map.new()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp merge_metadata(left, right) do
    left
    |> clean_metadata()
    |> Map.merge(clean_metadata(right))
  end
end
