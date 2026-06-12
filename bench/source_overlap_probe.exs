# Source-overlap probe (#263, Phase 1 — the gate).
#
# Answers the one question that gates the whole streaming/seekable-source spike:
#
#     Does decode actually OVERLAP a slow download — and for seek-heavy formats
#     (HEIF/AVIF, tiled TIFF), only via `mode: :spool`?
#
# It is deliberately a *synthetic, Vix-level* probe: the source is an Elixir
# enumerable fed straight to `Vix.Vips.Image.new_from_enum/2`, so no HTTP/pipeline
# wiring is needed. `:pipe` runs the bytes through the real OS-pipe feeder; `:spool`
# fills the real native seekable buffer (`Vix.SourceSpool`). If overlap is absent
# here, it cannot appear in the real pipeline either, so we stop before building the
# expensive real-`ImagePipe.call` harness (Phase 2, deferred).
#
# Requires the vix fork that ships `new_from_enum(mode: :pipe | :spool | :auto)`
# (hlindset/vix @ my-experimental-fixes). The probe asserts that at startup.
#
# Run with mise so tool versions match:
#
#   # default matrix (3 samples, rates unlimited/100/16/4 Mbps):
#   mise exec -- mix run bench/source_overlap_probe.exs
#
#   # more samples, custom rates (Mbps; "unlimited" allowed):
#   mise exec -- mix run bench/source_overlap_probe.exs 5 unlimited,40,8,2
#
#   # machine-readable rows for collation (suppresses the human tables):
#   mise exec -- mix run bench/source_overlap_probe.exs --csv
#
#   # force regeneration of the cached fixtures:
#   mise exec -- mix run bench/source_overlap_probe.exs --regen
#
# METHODOLOGY (overlap measured without a fragile decode-start hook):
#   For each (fixture, rate) we time, around wall-clock, a forced FULL decode
#   (`Operation.avg/1` reads every pixel) reached three ways, plus two references:
#     * download_only  — drain the throttled enum, no decode      → the download floor
#     * decode_cold    — new_from_buffer + avg from an in-RAM copy → pure decode cost
#                        (rate-independent; measured once per fixture)
#     * baseline       — drain enum to a binary, THEN decode       → today's ImagePipe
#                        shape (serial: ≈ download_only + decode_cold)
#     * pipe / spool   — new_from_enum(mode:) + avg, end-to-end    → the overlapped path
#   Derived per overlapped mode:
#     saving   = baseline - mode_total              (wall-clock saved vs serial)
#     tail     = mode_total - download_only         (decode cost NOT hidden under download)
#     overlap% = (decode_cold - tail) / decode_cold (fraction of decode hidden)
#   The win scales with source slowness, so overlap% is read at the SLOWEST rate.
#
# SELF-CHECKS (printed; hard failures abort — this is the anti-tautology gate):
#   1. sink-decodes   — decode_cold >> header-only open  (avg really forces decode)
#   2. throttle-floor — throttled download_only ≈ size/rate (the enum really throttles)
#   3. baseline-serial— baseline ≈ download_only + decode_cold (the timing model holds)
#
# This probe measures LATENCY/overlap only (the gate). Peak-RSS / N×content_length
# memory ceilings and the /info early-abort tension are Phase-2 concerns, deferred.

defmodule SourceOverlapProbe do
  @cache_dir "bench/.cache"
  @gen_source "priv/static/images/waterfall.jpg"
  @thumb_width 3600

  @default_samples 3
  @default_rates [:unlimited, 100, 16, 4]
  # Aim for ~15 ms per throttle tick: small enough for a smooth rate, large enough
  # that BEAM timer jitter (~1 ms) is a minor fraction.
  @chunk_target_ms 15

  @fixtures [
    {:forward, :jpg, "probe.jpg"},
    {:seek_heavy, :avif, "probe.avif"},
    {:seek_heavy, :tiff, "probe.tif"}
  ]

  def main(argv) do
    {csv?, argv} = pop_flag(argv, "--csv")
    {regen?, argv} = pop_flag(argv, "--regen")
    {samples, rates} = parse(argv)

    # Remove cross-iteration noise from the libvips operation cache.
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)

    assert_vix_fork!()

    fixtures = ensure_fixtures(regen?, samples)
    results = for fx <- fixtures, rate <- rates, do: measure_cell(fx, rate, samples)

    checks = self_checks(fixtures, results)
    unless csv?, do: print_self_checks(checks)
    abort_on_hard_failures(checks)

    if csv?, do: emit_csv(results), else: report(fixtures, results, rates)
  end

  # ── fork capability gate ──────────────────────────────────────────────────

  defp assert_vix_fork! do
    Code.ensure_loaded(Vix.Vips.Image)

    unless function_exported?(Vix.Vips.Image, :new_from_enum, 2) and
             Code.ensure_loaded?(Vix.SourceSpool) do
      abort("""
      This probe requires the vix fork with new_from_enum(mode: :pipe | :spool | :auto).
      Pin {:vix, git: "https://github.com/hlindset/vix.git", ref: "<my-experimental-fixes HEAD>"}.
      """)
    end
  end

  # ── fixtures (cached, gitignored) ─────────────────────────────────────────

  defp ensure_fixtures(regen?, samples) do
    File.mkdir_p!(@cache_dir)
    if regen?, do: Enum.each(@fixtures, fn {_, _, f} -> File.rm(Path.join(@cache_dir, f)) end)

    missing? =
      Enum.any?(@fixtures, fn {_, _, f} -> not File.exists?(Path.join(@cache_dir, f)) end)

    if missing?, do: generate_fixtures()

    Enum.map(@fixtures, fn {class, fmt, file} ->
      path = Path.join(@cache_dir, file)
      bin = File.read!(path)
      # decode_cold / header-open are rate-independent: measure once per fixture.
      decode_cold = median(for _ <- 1..(samples + 1), do: time_us(fn -> decode_buffer(bin) end))
      header_open = median(for _ <- 1..(samples + 1), do: time_us(fn -> open_buffer(bin) end))

      %{
        class: class,
        fmt: fmt,
        path: path,
        bin: bin,
        size: byte_size(bin),
        decode_cold: decode_cold,
        header_open: header_open
      }
    end)
  end

  # One materialized source -> three encodings of the SAME pixels. JPEG is forward
  # (decodes as bytes arrive). AVIF (AV1-in-HEIF) and tiled TIFF are seek-heavy: the
  # loader seeks, so `:pipe` must buffer the whole stream before decoding.
  defp generate_fixtures do
    IO.puts("generating fixtures from #{@gen_source} (#{@thumb_width}px wide)…")

    {:ok, img} =
      Vix.Vips.Image.copy_memory(Vix.Vips.Operation.thumbnail!(@gen_source, @thumb_width))

    Vix.Vips.Operation.jpegsave!(img, Path.join(@cache_dir, "probe.jpg"), Q: 90)

    Vix.Vips.Operation.heifsave!(img, Path.join(@cache_dir, "probe.avif"),
      compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1,
      Q: 63
    )

    # Tiled + JPEG-compressed TIFF: random-access tiles, non-trivial per-tile decode,
    # and a moderate encoded size (uncompressed/deflate would be far larger and skew
    # the download axis).
    Vix.Vips.Operation.tiffsave!(img, Path.join(@cache_dir, "probe.tif"),
      tile: true,
      tile_width: 256,
      tile_height: 256,
      compression: :VIPS_FOREIGN_TIFF_COMPRESSION_JPEG,
      Q: 90
    )
  end

  # ── throttled source ──────────────────────────────────────────────────────

  # A fresh enum each call; the consumer (feeder / producer / our drain) paces on the
  # per-chunk sleep. `binary_part/3` returns a sub-binary (no copy).
  defp throttled(bin, :unlimited), do: chunk_stream(bin, 65_536, 0)

  defp throttled(bin, rate_bps) do
    chunk = max(4096, round(rate_bps * @chunk_target_ms / 1000))
    sleep_ms = max(1, round(chunk / rate_bps * 1000))
    chunk_stream(bin, chunk, sleep_ms)
  end

  defp chunk_stream(bin, chunk, sleep_ms) do
    size = byte_size(bin)

    Stream.unfold(0, fn
      off when off >= size ->
        nil

      off ->
        if sleep_ms > 0, do: Process.sleep(sleep_ms)
        len = min(chunk, size - off)
        {binary_part(bin, off, len), off + len}
    end)
  end

  # ── the four timed operations ─────────────────────────────────────────────

  defp download_only(bin, rate_bps) do
    throttled(bin, rate_bps) |> Enum.reduce(0, fn c, acc -> acc + byte_size(c) end)
  end

  defp baseline(bin, rate_bps) do
    data = throttled(bin, rate_bps) |> Enum.to_list() |> IO.iodata_to_binary()
    decode_buffer(data)
  end

  defp overlap(bin, rate_bps, :pipe) do
    {:ok, img} = Vix.Vips.Image.new_from_enum(throttled(bin, rate_bps), mode: :pipe)
    sink(img)
  end

  defp overlap(bin, rate_bps, :spool) do
    size = byte_size(bin)

    {:ok, img} =
      Vix.Vips.Image.new_from_enum(throttled(bin, rate_bps),
        mode: :spool,
        content_length: size,
        max_bytes: size * 2
      )

    sink(img)
  end

  defp decode_buffer(bin), do: bin |> open_buffer() |> sink()
  defp open_buffer(bin), do: with({:ok, img} <- Vix.Vips.Image.new_from_buffer(bin, []), do: img)
  # avg/1 reads every pixel — forces the full decode the lazy image defers.
  defp sink(img), do: Vix.Vips.Operation.avg!(img)

  # ── measurement ───────────────────────────────────────────────────────────

  # samples + 1: the first run is a discarded warmup.
  defp measure_cell(fx, rate, samples) do
    bps = rate_bps(rate)
    dl = median(for _ <- 1..(samples + 1), do: time_us(fn -> download_only(fx.bin, bps) end))
    base = median(for _ <- 1..(samples + 1), do: time_us(fn -> baseline(fx.bin, bps) end))

    modes =
      for mode <- [:pipe, :spool], into: %{} do
        total =
          median(for _ <- 1..(samples + 1), do: time_us(fn -> overlap(fx.bin, bps, mode) end))

        tail = total - dl
        overlap_pct = pct_clamped(fx.decode_cold - tail, fx.decode_cold)

        {mode,
         %{
           total: total,
           saving: base - total,
           saving_pct: pct_clamped(base - total, base),
           tail: tail,
           overlap_pct: overlap_pct
         }}
      end

    %{
      class: fx.class,
      fmt: fx.fmt,
      size: fx.size,
      rate: rate,
      download_only: dl,
      baseline: base,
      decode_cold: fx.decode_cold,
      modes: modes
    }
  end

  # ── self-checks (anti-tautology gate) ─────────────────────────────────────

  defp self_checks(fixtures, results) do
    sink = Enum.map(fixtures, &sink_decodes_check/1)

    throttle =
      results |> Enum.reject(&(&1.rate == :unlimited)) |> Enum.map(&throttle_floor_check/1)

    serial = Enum.map(results, &baseline_serial_check/1)
    sink ++ throttle ++ serial
  end

  # decode_cold must dwarf a header-only open, or `avg` isn't forcing a decode.
  defp sink_decodes_check(fx) do
    ratio = safe_ratio(fx.decode_cold, fx.header_open)

    %{
      name: "sink-decodes #{fx.fmt}",
      ok: ratio >= 3.0,
      hard: true,
      detail:
        "decode_cold #{ms(fx.decode_cold)} / header_open #{ms(fx.header_open)} = #{f2(ratio)}x (want ≥3x)"
    }
  end

  # The throttled drain must take roughly size/rate; otherwise the enum isn't pacing.
  defp throttle_floor_check(r) do
    expected_us = r.size / rate_bps(r.rate) * 1_000_000
    ratio = safe_ratio(r.download_only, expected_us)

    %{
      name: "throttle-floor #{r.fmt}@#{rate_label(r.rate)}",
      ok: ratio >= 0.6,
      hard: true,
      detail:
        "download_only #{ms(r.download_only)} vs expected #{ms(expected_us)} = #{f2(ratio)}x (want ≥0.6x)"
    }
  end

  # baseline is serial by construction, so it must ≈ download_only + decode_cold.
  # A loose bound (this validates the timing model, not a tight SLA).
  defp baseline_serial_check(r) do
    expected = r.download_only + r.decode_cold
    rel = abs(r.baseline - expected) / max(expected, 1)

    %{
      name: "baseline-serial #{r.fmt}@#{rate_label(r.rate)}",
      ok: rel <= 0.35,
      hard: false,
      detail:
        "baseline #{ms(r.baseline)} vs dl+decode #{ms(expected)} (Δ #{f2(rel * 100)}%, want ≤35%)"
    }
  end

  defp print_self_checks(checks) do
    IO.puts("\nself-checks:")

    Enum.each(checks, fn c ->
      mark = if c.ok, do: "ok  ", else: if(c.hard, do: "FAIL", else: "warn")
      IO.puts("  [#{mark}] #{c.name}: #{c.detail}")
    end)
  end

  defp abort_on_hard_failures(checks) do
    hard = Enum.filter(checks, &(&1.hard and not &1.ok))

    unless hard == [] do
      abort(
        "hard self-check failure(s): #{Enum.map_join(hard, "; ", & &1.name)} — results not trustworthy"
      )
    end
  end

  # ── reporting ─────────────────────────────────────────────────────────────

  defp report(fixtures, results, rates) do
    IO.puts(
      "\nsource-overlap probe  (samples median; saving = baseline − mode; overlap% = decode hidden under download)\n"
    )

    Enum.each(fixtures, fn fx ->
      cells = Enum.filter(results, &(&1.fmt == fx.fmt))

      IO.puts(
        "#{String.upcase(to_string(fx.class))}  #{fx.fmt}  (#{kb(fx.size)}, decode_cold #{ms(fx.decode_cold)})"
      )

      IO.puts(
        "  " <>
          col("rate", 11) <>
          col("download", 11) <>
          col("baseline", 11) <>
          col("pipe", 11) <> col("(save/ovl)", 16) <> col("spool", 11) <> col("(save/ovl)", 16)
      )

      Enum.each(cells, fn r ->
        p = r.modes.pipe
        s = r.modes.spool

        IO.puts(
          "  " <>
            col(rate_label(r.rate), 11) <>
            col(ms(r.download_only), 11) <>
            col(ms(r.baseline), 11) <>
            col(ms(p.total), 11) <>
            col("#{f0(p.saving_pct)}%/#{f0(p.overlap_pct)}%", 16) <>
            col(ms(s.total), 11) <>
            col("#{f0(s.saving_pct)}%/#{f0(s.overlap_pct)}%", 16)
        )
      end)

      IO.puts("")
    end)

    verdict(fixtures, results, rates)
  end

  # The decision metric is the ABSOLUTE wall-clock saving, not overlap%. overlap% is
  # the fraction of decode hidden under the download — but the most any overlap can
  # save is the decode cost itself (decode_cold), so a high overlap% of a cheap decode
  # is still a negligible win. The fork (the SourceSpool seekable buffer) is justified
  # only if :spool delivers a MATERIAL saving on a SEEK-HEAVY fixture (forward overlap
  # needs no spool — :pipe already gives it). Read at the slowest rate, where the win
  # is largest in relative terms.
  @material_saving_ms 100
  @material_saving_pct 5

  defp verdict(fixtures, results, rates) do
    slow = rates |> Enum.reject(&(&1 == :unlimited)) |> List.last()
    if is_nil(slow), do: throw(:no_throttled_rate)

    IO.puts(
      "verdict @ #{rate_label(slow)}  (max possible saving = decode_cold; spool justified only by a material seek-heavy saving)\n"
    )

    IO.puts(
      "  " <>
        col("fixture", 18) <>
        col("max(decode)", 13) <>
        col("pipe save", 18) <> col("spool save", 18) <> "overlap p/s"
    )

    rows =
      Enum.map(fixtures, fn fx ->
        {fx, Enum.find(results, &(&1.fmt == fx.fmt and &1.rate == slow))}
      end)

    Enum.each(rows, fn {fx, r} ->
      p = r.modes.pipe
      s = r.modes.spool

      IO.puts(
        "  " <>
          col("#{fx.fmt} (#{fx.class})", 18) <>
          col("#{ms(fx.decode_cold)}ms", 13) <>
          col("#{ms(p.saving)}ms/#{f0(p.saving_pct)}%", 18) <>
          col("#{ms(s.saving)}ms/#{f0(s.saving_pct)}%", 18) <>
          "#{f0(p.overlap_pct)}%/#{f0(s.overlap_pct)}%"
      )
    end)

    decide(rows)
  end

  defp decide(rows) do
    material =
      Enum.filter(rows, fn {fx, r} ->
        fx.class == :seek_heavy and material?(r.modes.spool)
      end)

    IO.puts("")

    if material == [] do
      IO.puts("""
      NO-GO: no seek-heavy fixture shows a material :spool saving (≥#{@material_saving_ms}ms and ≥#{@material_saving_pct}%).
      The overlappable formats (forward) decode too cheaply to matter and need only :pipe;
      the expensive seek-heavy decode (AVIF/AV1) is monolithic and cannot overlap a download.
      ⇒ Do not adopt the forked native dep for slow-source latency. Document and stay on the
        drain baseline. (The spool may still have a separate memory-shape case — out of scope.)
      """)
    else
      names = Enum.map_join(material, ", ", fn {fx, _} -> to_string(fx.fmt) end)

      IO.puts("""
      GREENLIGHT: material :spool saving on seek-heavy fixture(s): #{names}.
      ⇒ Proceed to Phase 2 (real-pipeline harness) to confirm the win end-to-end.
      """)
    end
  end

  defp material?(m),
    do: m.saving >= @material_saving_ms * 1000 and m.saving_pct >= @material_saving_pct

  defp emit_csv(results) do
    for r <- results, {mode, m} <- r.modes do
      IO.puts(
        Enum.join(
          [
            r.class,
            r.fmt,
            rate_label(r.rate),
            r.size,
            ms(r.download_only),
            ms(r.decode_cold),
            ms(r.baseline),
            mode,
            ms(m.total),
            ms(m.saving),
            f0(m.saving_pct),
            f0(m.overlap_pct)
          ],
          ","
        )
      )
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp time_us(fun) do
    t0 = System.monotonic_time(:microsecond)
    _ = fun.()
    System.monotonic_time(:microsecond) - t0
  end

  defp rate_bps(:unlimited), do: :unlimited
  defp rate_bps(mbps) when is_integer(mbps), do: mbps * 125_000

  defp rate_label(:unlimited), do: "unlimited"
  defp rate_label(mbps), do: "#{mbps}Mbps"

  defp median([]), do: 0

  defp median(list) do
    # drop the warmup (first sample), then take the median of the rest
    sorted = list |> Enum.drop(1) |> Enum.sort()
    n = length(sorted)
    if n == 0, do: hd(list), else: Enum.at(sorted, div(n, 2))
  end

  defp pct_clamped(_num, 0), do: 0.0
  defp pct_clamped(num, den), do: max(0.0, num / den * 100)

  defp safe_ratio(_a, b) when b in [0, 0.0], do: 0.0
  defp safe_ratio(a, b), do: a / b

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 1)
  defp kb(bytes), do: "#{:erlang.float_to_binary(bytes / 1024, decimals: 0)}KB"
  defp f0(x), do: :erlang.float_to_binary(x * 1.0, decimals: 0)
  defp f2(x), do: :erlang.float_to_binary(x * 1.0, decimals: 2)
  defp col(s, w), do: String.pad_trailing(to_string(s), w)

  defp pop_flag(argv, flag), do: {flag in argv, Enum.reject(argv, &(&1 == flag))}

  defp parse(argv) do
    samples =
      case Enum.find(argv, &(Integer.parse(&1) != :error)) do
        nil -> @default_samples
        s -> s |> Integer.parse() |> elem(0) |> max(1)
      end

    rates =
      case Enum.find(argv, &String.contains?(&1, ",")) || Enum.find(argv, &rate_token?/1) do
        nil -> @default_rates
        spec -> spec |> String.split(",", trim: true) |> Enum.map(&to_rate/1)
      end

    {samples, rates}
  end

  defp rate_token?(s), do: s == "unlimited"
  defp to_rate("unlimited"), do: :unlimited
  defp to_rate(s), do: s |> Integer.parse() |> elem(0)

  defp abort(msg) do
    IO.puts(:stderr, "\n#{msg}\n")
    System.halt(1)
  end
end

SourceOverlapProbe.main(System.argv())
