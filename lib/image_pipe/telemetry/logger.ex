defmodule ImagePipe.Telemetry.Logger do
  @moduledoc false
  # Default :telemetry -> Logger handler for ImagePipe. Attached opt-in via
  # ImagePipe.Telemetry.attach_default_logger/1. Reads event maps and calls
  # Logger only; no other dependencies.

  require Logger

  @handler_id "image-pipe-default-logger"

  # group => span event suffixes (each gets :stop + :exception)
  @group_span_events %{
    request: [[:request], [:send]],
    parse: [[:parse]],
    source: [[:source, :resolve], [:source, :fetch], [:source, :fetch_decode]],
    transform: [[:transform, :execute], [:transform, :operation], [:transform, :detect]],
    cache: [[:cache, :lookup], [:cache, :write], [:cache, :admission], [:cache, :warm_start]]
  }

  # cache one-shot events (already terminal; not spans)
  @cache_oneshot [
    [:cache, :eviction, :stop],
    [:cache, :flush, :stop],
    [:cache, :cleanup, :stop],
    [:cache, :stage]
  ]

  # transform one-shot events (already terminal; not spans)
  @transform_oneshot [
    [:transform, :detect, :skipped],
    [:transform, :detect, :blend]
  ]

  @all_groups Map.keys(@group_span_events)

  def all_groups, do: @all_groups

  def attach(opts) do
    groups = Keyword.get(opts, :events, :all) |> expand_groups()
    prefix = Keyword.get(opts, :prefix, ImagePipe.Telemetry.default_prefix())
    level = Keyword.get(opts, :level, :info)
    debug? = Keyword.get(opts, :debug, false)

    config = %{prefix: prefix, level: level, debug?: debug?, plen: length(prefix)}

    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      event_names(groups, prefix),
      &__MODULE__.handle_event/4,
      config
    )
  end

  def detach, do: :telemetry.detach(@handler_id)

  defp expand_groups(:all), do: @all_groups
  defp expand_groups(groups) when is_list(groups), do: groups

  defp event_names(groups, prefix) do
    spans =
      groups
      |> Enum.flat_map(&Map.get(@group_span_events, &1, []))
      |> Enum.flat_map(fn e -> [e ++ [:stop], e ++ [:exception]] end)

    cache_oneshots = if :cache in groups, do: @cache_oneshot, else: []
    transform_oneshots = if :transform in groups, do: @transform_oneshot, else: []

    Enum.map(spans ++ cache_oneshots ++ transform_oneshots, fn e -> prefix ++ e end)
  end

  @doc false
  def handle_event(event, measurements, metadata, config) do
    suffix = Enum.drop(event, config.plen)
    level = level_for(suffix, metadata, config.level)

    message =
      if List.last(suffix) == :exception do
        exception_message(suffix, metadata)
      else
        message(suffix, measurements, metadata)
      end

    Logger.log(level, fn -> message end, log_metadata(event, measurements, metadata))

    if config.debug? do
      Logger.debug(fn ->
        "image_pipe #{label(suffix)} raw: measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
      end)
    end

    :ok
  end

  # --- level ---
  defp level_for(suffix, metadata, base) do
    cond do
      List.last(suffix) == :exception -> :warning
      metadata[:result] == :cache_error -> :warning
      detect_fallback_warning?(suffix, metadata) -> :warning
      true -> base
    end
  end

  # A face-aware crop that could not be fulfilled and degraded to attention
  # saliency: a configured detector that produced no usable detection
  # (`:unavailable`, `:error`) or a request with no detector configured at all
  # (`:no_detector`, the `[:transform, :detect, :skipped]` one-shot). `:no_regions`
  # (no face in frame) is a normal result, not a warning.
  defp detect_fallback_warning?([:transform, :detect | _], meta),
    do: meta[:result] in [:unavailable, :error, :no_detector]

  defp detect_fallback_warning?(_suffix, _meta), do: false

  # --- message ---
  defp message([:transform, :operation | _], _m, meta) do
    "image_pipe transform: #{meta[:operation]} (##{(meta[:index] || 0) + 1})"
  end

  defp message([:transform, :detect, :skipped | _], _m, _meta),
    do: "image_pipe transform detect: skipped (no detector configured)"

  defp message([:transform, :detect, :blend | _], _m, meta) do
    "image_pipe transform detect blend: attention #{point(meta[:attention])} -> " <>
      "#{point(meta[:blended])} (face #{point(meta[:face])}, weight #{meta[:weight]})"
  end

  defp message([:cache, :lookup | _], _m, meta), do: "image_pipe cache lookup: #{meta[:cache]}"

  defp message([:cache, :write | _], _m, meta) do
    detail =
      case meta[:cache] do
        :write -> "stored"
        :admission_rejected -> "rejected by admission"
        :write_error -> "error"
        other -> inspect(other)
      end

    "image_pipe cache write: #{detail}"
  end

  defp message([:cache, :admission | _], _m, meta) do
    "image_pipe cache admission: #{meta[:result]}"
  end

  defp message([:cache, :eviction | _], measurements, meta) do
    "image_pipe cache eviction: #{measurements[:count]} entries (#{meta[:trigger]})"
  end

  defp message(suffix, _m, meta) do
    "image_pipe #{label(suffix)}: #{outcome(meta)}"
  end

  defp exception_message(suffix, meta) do
    "image_pipe #{label(suffix)}: exception (#{meta[:kind]} #{inspect(meta[:reason])})"
  end

  defp outcome(meta), do: meta[:cache] || meta[:result] || :ok

  defp label(suffix) do
    suffix
    |> Enum.reject(&(&1 in [:stop, :exception]))
    |> Enum.map_join(" ", &Atom.to_string/1)
  end

  defp point({x, y}), do: "(#{round2(x)},#{round2(y)})"
  defp point(_other), do: "(?,?)"

  defp round2(n) when is_number(n), do: Float.round(n * 1.0, 2)
  defp round2(_other), do: nil

  # --- logger metadata ---
  defp log_metadata(event, measurements, metadata) do
    base = [event: event]

    base =
      case measurements[:duration] do
        nil -> base
        native -> [{:duration_us, System.convert_time_unit(native, :native, :microsecond)} | base]
      end

    Keyword.merge(base, Map.to_list(metadata))
  end
end
