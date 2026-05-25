defmodule ImagePipe.Telemetry do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [],
    exports: []

  @default_prefix [:image_pipe]

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

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
