# Decode-mode benchmark: streaming (new_from_enum, the pre-Plan-A path) vs buffered
# (new_from_buffer, the Plan-A path), measuring wall-clock and peak process memory for a
# representative decode -> downscale -> encode workload.
#
# Run with mise so tool versions match:
#
#   # one mode per OS process -> cleanest, isolated peak-memory reading:
#   mise exec -- mix run bench/decode_modes.exs streaming
#   mise exec -- mix run bench/decode_modes.exs buffered
#
#   # both modes in one process -> time is comparable; peak RSS is captured per mode
#   # (sampled during each mode's run), but the libvips high-water (if available) is
#   # cumulative. Prefer single-mode runs for the most rigorous memory numbers.
#   mise exec -- mix run bench/decode_modes.exs both
#
# Optional args (positional): <mode> <access> <path> <width> <iters>
#   mode   : streaming | buffered | both     (default: both)
#   access : sequential | random             (default: sequential)
#   path   : image file                      (default: priv/static/images/waterfall.jpg)
#   width  : target downscale width in px    (default: 400)
#   iters  : timed iterations (1 warmup is always discarded)  (default: 20)
#
# MEMORY NOTES:
#   * Peak RSS is sampled from the OS (`ps -o rss`) during each mode's run, so it includes
#     libvips' off-heap allocations. This is the most build-portable signal and is where
#     streaming vs buffered diverges most under `random` access (the streaming pipe cannot
#     seek, so libvips materializes the whole decoded image).
#   * Vix.Vips.tracked_get_mem_highwater/0 is also printed, but it reports 0 unless libvips
#     was compiled with memory tracking (the dev build here is not). It is process-global and
#     non-resettable, so when present it is only a clean per-mode peak in a single-mode run.
#   * The libvips operation cache is disabled below to remove cross-iteration noise.

defmodule DecodeBench do
  @default_path "priv/static/images/waterfall.jpg"
  @sample_interval_ms 10

  def main(argv) do
    {mode, access, path, width, iters} = parse(argv)

    unless File.exists?(path) do
      IO.puts(:stderr, "fixture not found: #{path}")
      System.halt(1)
    end

    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)

    # streaming feeds raw opts to Image.open (which validates internally); buffered feeds
    # pre-validated opts straight to new_from_buffer. This mirrors the real decode paths.
    raw_opts = [access: access, fail_on: :error]
    {:ok, validated_opts} = Image.Options.Open.validate_options(raw_opts)

    IO.puts("""
    decode-mode benchmark
      file:    #{path} (#{fmt_bytes(File.stat!(path).size)} compressed)
      access:  #{access}
      width:   #{width}px target
      iters:   #{iters} (+1 warmup discarded)
    """)

    modes = if mode == :both, do: [:streaming, :buffered], else: [mode]
    Enum.each(modes, fn m -> run_mode(m, path, raw_opts, validated_opts, width, iters) end)
  end

  defp run_mode(mode, path, raw_opts, validated_opts, width, iters) do
    decode = decoder(mode, path, raw_opts, validated_opts)

    # Warmup (discarded): also captures decoded dimensions for reporting.
    {:ok, warm} = decode.()
    src_w = Vix.Vips.Image.width(warm)
    src_h = Vix.Vips.Image.height(warm)
    :erlang.garbage_collect()

    baseline_rss = read_rss_bytes()
    sampler = start_rss_sampler()

    times =
      for _ <- 1..iters do
        t0 = :erlang.monotonic_time(:microsecond)
        {out_w, out_h} = decode_resize_encode(decode, width)
        t1 = :erlang.monotonic_time(:microsecond)
        {t1 - t0, out_w, out_h}
      end

    peak_rss = stop_rss_sampler(sampler)
    durations = Enum.map(times, &elem(&1, 0))
    {_, out_w, out_h} = hd(times)

    IO.puts("""
    [#{mode}]
      decoded source:   #{src_w}x#{src_h}
      output:           #{out_w}x#{out_h}
      time (ms):        min #{ms(Enum.min(durations))}  median #{ms(median(durations))}  max #{ms(Enum.max(durations))}
      peak RSS:         #{fmt_bytes(peak_rss)}  (baseline before run: #{fmt_bytes(baseline_rss)}, delta #{fmt_bytes(peak_rss - baseline_rss)})
      libvips highwater:#{fmt_bytes(Vix.Vips.tracked_get_mem_highwater())} #{tracking_note()}
    """)
  end

  # Decode the resized output to a real encoded binary so the full
  # decode -> resize -> encode pipeline is actually evaluated (libvips is lazy).
  defp decode_resize_encode(decode, width) do
    {:ok, image} = decode.()
    scale = width / Vix.Vips.Image.width(image)
    {:ok, resized} = Image.resize(image, scale)
    _ = Image.write!(resized, :memory, suffix: ".jpg")
    {Vix.Vips.Image.width(resized), Vix.Vips.Image.height(resized)}
  end

  # streaming = the pre-Plan-A path: feed a lazy byte stream to Image.open -> new_from_enum.
  defp decoder(:streaming, path, raw_opts, _validated) do
    fn -> Image.open(File.stream!(path, 65_536, []), raw_opts) end
  end

  # buffered = the Plan-A path: read the whole compressed body, decode via new_from_buffer
  # with validated open options (access preserved).
  defp decoder(:buffered, path, _raw, validated_opts) do
    fn -> Vix.Vips.Image.new_from_buffer(File.read!(path), validated_opts) end
  end

  # --- peak RSS sampling (OS-level, captures libvips off-heap allocations) ---

  defp start_rss_sampler do
    spawn(fn -> sample_loop(read_rss_bytes()) end)
  end

  defp stop_rss_sampler(sampler) do
    send(sampler, {:stop, self()})

    receive do
      {:rss_peak, peak} -> peak
    after
      5_000 -> 0
    end
  end

  defp sample_loop(peak) do
    receive do
      {:stop, from} -> send(from, {:rss_peak, peak})
    after
      @sample_interval_ms -> sample_loop(max(peak, read_rss_bytes()))
    end
  end

  defp read_rss_bytes do
    case :os.cmd(~c"ps -o rss= -p #{System.pid()}") do
      ~c"" ->
        0

      chars ->
        chars
        |> to_string()
        |> String.trim()
        |> Integer.parse()
        |> case do
          {kb, _} -> kb * 1024
          :error -> 0
        end
    end
  end

  defp tracking_note do
    if Vix.Vips.tracked_get_mem_highwater() == 0,
      do: "(0 = libvips built without mem tracking)",
      else: ""
  end

  # --- arg parsing + formatting ---

  defp parse(argv) do
    mode = argv |> Enum.at(0, "both") |> to_mode()
    access = argv |> Enum.at(1, "sequential") |> to_access()
    path = Enum.at(argv, 2, @default_path)
    width = argv |> Enum.at(3, "400") |> String.to_integer()
    iters = argv |> Enum.at(4, "20") |> String.to_integer()
    {mode, access, path, width, iters}
  end

  defp to_mode("streaming"), do: :streaming
  defp to_mode("buffered"), do: :buffered
  defp to_mode("both"), do: :both

  defp to_mode(o),
    do: raise(ArgumentError, "mode must be streaming|buffered|both, got #{inspect(o)}")

  defp to_access("sequential"), do: :sequential
  defp to_access("random"), do: :random

  defp to_access(o),
    do: raise(ArgumentError, "access must be sequential|random, got #{inspect(o)}")

  defp median(list) do
    sorted = Enum.sort(list)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)

  defp fmt_bytes(b) when b >= 1_048_576,
    do: "#{:erlang.float_to_binary(b / 1_048_576, decimals: 1)} MiB"

  defp fmt_bytes(b) when b >= 1024, do: "#{:erlang.float_to_binary(b / 1024, decimals: 1)} KiB"
  defp fmt_bytes(b), do: "#{b} B"
end

DecodeBench.main(System.argv())
