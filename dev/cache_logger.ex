defmodule ImagePipe.SimpleServer.CacheLogger do
  @moduledoc false
  # Dev-only :telemetry -> Logger bridge for the cache layer. The library emits
  # telemetry events only (see telemetry guidelines); this handler is the kind
  # of host-side logging integration a real host would attach itself. It exists
  # purely so `mix image_pipe.server --cache` shows what the cache is doing:
  # reads (hit/miss), writes (stored/rejected/error), admission decisions, and
  # background eviction/flush/cleanup activity.

  require Logger

  @handler_id "image-pipe-dev-cache-logger"

  @events [
    [:image_pipe, :cache, :lookup, :stop],
    [:image_pipe, :cache, :lookup, :exception],
    [:image_pipe, :cache, :write, :stop],
    [:image_pipe, :cache, :write, :exception],
    [:image_pipe, :cache, :admission, :stop],
    [:image_pipe, :cache, :eviction, :stop],
    [:image_pipe, :cache, :flush, :stop],
    [:image_pipe, :cache, :cleanup, :stop],
    [:image_pipe, :cache, :warm_start, :stop],
    [:image_pipe, :cache, :stage]
  ]

  @doc """
  Attach the cache logging handler. Idempotent — a previously attached handler
  with the same id is detached first so repeated dev-server starts in one VM
  don't fail with `:already_exists`.
  """
  def attach do
    _ = :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:image_pipe, :cache, :lookup, :stop], measurements, metadata, _config) do
    Logger.debug("cache lookup: #{Map.get(metadata, :cache)}#{format_error(metadata)}#{duration(measurements)}")
  end

  def handle_event([:image_pipe, :cache, :write, :stop], measurements, metadata, _config) do
    detail =
      case Map.get(metadata, :cache) do
        :write -> "stored"
        :admission_rejected -> "rejected by admission"
        :write_error -> "error#{format_error(metadata)}"
        other -> inspect(other)
      end

    Logger.debug("cache write: #{detail} #{format_format(metadata)}#{duration(measurements)}")
  end

  def handle_event([:image_pipe, :cache, :admission, :stop], _measurements, metadata, _config) do
    case Map.get(metadata, :result) do
      :admitted ->
        Logger.debug("cache admission: admitted (evicted #{Map.get(metadata, :victim_count, 0)})")

      :rejected ->
        Logger.debug("cache admission: rejected (reason=#{Map.get(metadata, :reason)})")

      other ->
        Logger.debug("cache admission: #{inspect(other)}")
    end
  end

  def handle_event([:image_pipe, :cache, :eviction, :stop], measurements, metadata, _config) do
    Logger.debug(
      "cache eviction: #{Map.get(measurements, :count, 0)} entries, " <>
        "#{format_bytes(Map.get(measurements, :bytes, 0))} (#{Map.get(metadata, :trigger)})"
    )
  end

  def handle_event([:image_pipe, :cache, :flush, :stop], measurements, _metadata, _config) do
    Logger.debug("cache flush: state persisted (#{format_bytes(Map.get(measurements, :bytes, 0))})")
  end

  def handle_event([:image_pipe, :cache, :cleanup, :stop], measurements, _metadata, _config) do
    Logger.debug("cache cleanup: removed #{Map.get(measurements, :removed, 0)} stale peer state files")
  end

  def handle_event([:image_pipe, :cache, :warm_start, :stop], _measurements, metadata, _config) do
    Logger.debug(
      "cache warm start: own_state=#{Map.get(metadata, :own_state_loaded)} " <>
        "peers=#{Map.get(metadata, :peer_state_files, 0)}"
    )
  end

  def handle_event([:image_pipe, :cache, :stage], _measurements, metadata, _config) do
    Logger.debug("cache stage: #{Map.get(metadata, :cache)}#{format_error(metadata)}")
  end

  def handle_event([:image_pipe, :cache, _op, :exception], _measurements, metadata, _config) do
    Logger.warning(
      "cache exception: #{Map.get(metadata, :kind)} #{inspect(Map.get(metadata, :reason))}"
    )
  end

  defp duration(%{duration: native}) do
    us = System.convert_time_unit(native, :native, :microsecond)
    " (#{:erlang.float_to_binary(us / 1000, decimals: 1)}ms)"
  end

  defp duration(_measurements), do: ""

  defp format_error(%{error: error}), do: " error=#{inspect(error)}"
  defp format_error(_metadata), do: ""

  defp format_format(%{output_format: format}) when not is_nil(format), do: "(format=#{format})"
  defp format_format(_metadata), do: ""

  defp format_bytes(bytes) when bytes >= 1_000_000,
    do: "#{:erlang.float_to_binary(bytes / 1_000_000, decimals: 1)}MB"

  defp format_bytes(bytes) when bytes >= 1_000,
    do: "#{:erlang.float_to_binary(bytes / 1_000, decimals: 1)}KB"

  defp format_bytes(bytes), do: "#{bytes}B"
end
