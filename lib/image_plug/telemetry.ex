defmodule ImagePlug.Telemetry do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [],
    exports: []

  @default_prefix [:image_plug]

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

  @spec span(keyword(), [atom()], map() | keyword(), (-> term())) :: term()
  def span(opts, stage, start_metadata, fun) when is_function(fun, 0) do
    do_span(opts, stage, start_metadata, fn start_metadata ->
      {result, stop_metadata} = fun.()
      {result, merge_metadata(start_metadata, stop_metadata)}
    end)
  end

  defp do_span(opts, stage, start_metadata, span_fun) when is_list(stage) do
    start_metadata = clean_metadata(start_metadata)

    :telemetry.span(event_prefix(opts, stage), start_metadata, fn ->
      span_fun.(start_metadata)
    end)
  end

  @spec event_prefix(keyword(), [atom()]) :: [atom()]
  def event_prefix(opts, stage) when is_list(opts) and is_list(stage) do
    Keyword.get(opts, :telemetry_prefix, @default_prefix) ++ stage
  end

  @spec clean_metadata(map() | keyword()) :: map()
  def clean_metadata(metadata) do
    metadata
    |> Map.new()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec merge_metadata(map() | keyword(), map() | keyword()) :: map()
  def merge_metadata(left, right) do
    left
    |> clean_metadata()
    |> Map.merge(clean_metadata(right))
  end

  @spec error(term()) :: atom()
  def error({tag, _value}) when is_atom(tag), do: tag
  def error({tag, _value, _extra}) when is_atom(tag), do: tag
  def error(tag) when is_atom(tag), do: tag
  def error(_reason), do: :error
end
