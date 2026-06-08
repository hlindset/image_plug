# ONE-OFF #164 MEASUREMENT — NOT part of the maintained decode-mode bench suite.
#
# Gate for #164 (deferred look-ahead pre-clamp). Measures the libvips working-set
# high-water of the oversized buffer that the delivery-backstop / orientation
# flush copy_memory materializes on an oversized-ENLARGE request, before #150/#165's
# post-hoc clamp downscales it.
#
# Design + gate: docs/superpowers/specs/2026-06-08-oversized-buffer-materialization-benchmark-design.md
#
# Control (NO orientation needed — see the design's "premise correction"): the
# oversized buffer is materialized on EVERY oversized-enlarge request (plain or
# oriented), because Resize stays lazy and Request.Processor.materialize_before_delivery
# copy_memory's the resized (oversized, pre-clamp) image. So we compare the SAME
# final output produced two ways at a fixed host cap:
#   * Arm A (current):  request target = oversize -> backstop copies the OVERSIZED
#                        buffer -> post-hoc clamp downscales to ~cap.
#   * Arm B (optimized proxy): request target = cap -> backstop copies the CAP-sized
#                        buffer -> clamp no-ops. (== what the look-ahead would produce.)
#   gap (A - B) = the avoidable oversized buffer = what #164 would save.
#
# Drives the REAL seam (decode -> PlanExecutor -> materialize_before_delivery ->
# Output.Clamp -> Encoder consumed) via Request.Processor + the producer's clamp
# math, with a hand-built Plan. Output is PNG and max_result_pixels is raised so
# the per-axis dimension cap is the SOLE binding limit (no encoder / pixel-cap
# confound). libvips op cache disabled. One case per OS process (the high-water
# counter is process-wide, monotonic, non-resettable).
#
# Run with mise so tool versions match:
#   # whole matrix (spawns one `mix run` per case, collates):
#   mise exec -- mix run bench/oversized_buffer_highwater.exs
#   # one case in-process (emits one CSV row); used by the orchestrator:
#   mise exec -- mix run bench/oversized_buffer_highwater.exs case A 16000 8192
#   mise exec -- mix run bench/oversized_buffer_highwater.exs case B 8192 8192
#   mise exec -- mix run bench/oversized_buffer_highwater.exs case selfcheck 0 0

defmodule OversizedBufferBench do
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Output, as: PlanOutput
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Request.Processor
  alias Vix.Vips.Image, as: VipsImage

  # Source: a 2000x3000 portrait, 3-band RGB (rects so it is genuine RGB, not a
  # constant libvips can shortcut). Long axis 3000 < every sweep target -> always
  # an enlargement -> shrink-on-load never fires (DecodePlanner), so both arms
  # decode at full source dims. The fit resize sizes the LONG axis (height) to the
  # target: height = target, width = 2*target/3.
  @src_w 2000
  @src_h 3000

  # Raised so ONLY the per-axis dimension cap binds (default 40M would also clamp).
  @max_pixels 100_000_000_000

  # Matrix (executed cells). {arm, target_long_axis, host_cap}; selfcheck is special.
  @matrix [
    {"B", 8192, 8192},
    {"A", 9000, 8192},
    {"A", 16000, 8192},
    {"A", 20000, 8192},
    {"A", 20000, 20000},
    {"selfcheck", 0, 0}
  ]

  @columns ~w(case arm target cap pre_w pre_h final_w final_h libvips_peak_bytes rss_peak_bytes ms)

  def main(["case", arm, target, cap]) do
    setup_libvips()
    row = run_case(arm, String.to_integer(target), String.to_integer(cap))
    IO.puts(Enum.map_join(@columns, ",", fn c -> to_string(Map.get(row, String.to_atom(c), "")) end))
  end

  def main(_argv), do: orchestrate()

  # --- orchestrator: one isolated `mix run` per case, then collate ---

  defp orchestrate do
    self_path = Path.relative_to_cwd(__ENV__.file)
    IO.puts(:stderr, "running #{length(@matrix)} cases (one OS process each)\n")

    rows =
      @matrix
      |> Enum.with_index(1)
      |> Enum.map(fn {{arm, target, cap}, i} ->
        IO.puts(:stderr, "[#{i}/#{length(@matrix)}] #{arm} target=#{target} cap=#{cap}")
        run_subprocess(self_path, arm, target, cap)
      end)

    report(rows)
  end

  defp run_subprocess(self_path, arm, target, cap) do
    {out, status} =
      System.cmd(
        "mix",
        ["run", self_path, "case", arm, to_string(target), to_string(cap)],
        stderr_to_stdout: false
      )

    case parse_row(out) do
      nil -> %{case: "#{arm}:#{target}:#{cap}", arm: arm, error: "exit #{status} / no row"}
      row -> row
    end
  end

  defp parse_row(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ","))
    |> Enum.find_value(fn
      fields when length(fields) == length(@columns) ->
        @columns |> Enum.map(&String.to_atom/1) |> Enum.zip(fields) |> Map.new()

      _ ->
        nil
    end)
  end

  # --- per-case execution ---

  defp run_case("selfcheck", _target, _cap) do
    # Counter sanity: copy_memory a known-large 3-band image; the tracked
    # high-water MUST be >= a conservative floor of its byte size. Guards against a
    # dead/zero high-water NIF that would make every arm read ~0 -> false STOP.
    {sampler, _} = start_rss_sampler()
    t0 = now_ms()
    big_w = 6000
    big_h = 6000
    image = solid_rgb(big_w, big_h)
    {:ok, mem} = VipsImage.copy_memory(image)
    _ = Image.write!(mem, :memory, suffix: ".png")
    ms = now_ms() - t0
    rss = stop_rss_sampler(sampler)
    hw = Vix.Vips.tracked_get_mem_highwater()
    known = big_w * big_h * 3
    floor = div(known, 2)

    IO.puts(:stderr, "  selfcheck: high-water=#{mib(hw)} known=#{mib(known)} floor=#{mib(floor)} -> #{if hw >= floor, do: "OK", else: "FAIL (counter dead?)"}")

    %{
      case: "selfcheck",
      arm: "selfcheck",
      target: 0,
      cap: 0,
      pre_w: big_w,
      pre_h: big_h,
      final_w: big_w,
      final_h: big_h,
      libvips_peak_bytes: hw,
      rss_peak_bytes: rss,
      ms: ms
    }
  end

  defp run_case(arm, target, cap) do
    {sampler, _} = start_rss_sampler()
    t0 = now_ms()

    image = decode_source()
    plan = plan_for(target)

    {:ok, final_state} = Processor.process_decoded_source(%{image: image}, plan, opts())
    pre = {Image.width(final_state.image), Image.height(final_state.image)}

    limits = %{max_width: cap, max_height: cap, max_pixels: @max_pixels}
    {:ok, clamped, _info} = Clamp.clamp(final_state.image, limits, opts())
    final = {Image.width(clamped), Image.height(clamped)}

    # Realize the full pipeline through a faithful encode (strip flags off so the
    # encode stays lazy and the measured peak is the backstop buffer, not an extra
    # finalize copy of the already-small clamped image).
    resolved = %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: false,
      strip_color_profile: false
    }

    {:ok, stream, _ct} = Encoder.stream_output(clamped, resolved, opts())
    Enum.each(stream, fn _chunk -> :ok end)

    ms = now_ms() - t0
    rss = stop_rss_sampler(sampler)
    hw = Vix.Vips.tracked_get_mem_highwater()

    {pw, ph} = pre
    {fw, fh} = final
    IO.puts(:stderr, "  #{arm} target=#{target} cap=#{cap}: pre=#{pw}x#{ph} final=#{fw}x#{fh} high-water=#{mib(hw)} rss=#{mib(rss)}")

    %{
      case: "#{arm}:#{target}:#{cap}",
      arm: arm,
      target: target,
      cap: cap,
      pre_w: pw,
      pre_h: ph,
      final_w: fw,
      final_h: fh,
      libvips_peak_bytes: hw,
      rss_peak_bytes: rss,
      ms: ms
    }
  end

  defp plan_for(target) do
    %Plan{
      source: nil,
      output: %PlanOutput{mode: {:explicit, :png}},
      auto_rotate: false,
      pipelines: [
        %Pipeline{
          operations: [
            %PlanResize{
              mode: :fit,
              width: :auto,
              height: {:px, target},
              dpr: {:ratio, 1, 1},
              enlargement: :allow,
              guide: :center
            }
          ]
        }
      ]
    }
  end

  # Minimal opts: the seam reads only image_module (defaults to Image) + telemetry
  # (safe when absent); we compute the clamp limits ourselves, so no max_result_* needed.
  defp opts, do: []

  defp decode_source do
    bytes = Image.write!(solid_rgb(@src_w, @src_h), :memory, suffix: ".png")
    tmp = Path.join(System.tmp_dir!(), "ip_bench_src_#{System.unique_integer([:positive])}.png")
    File.write!(tmp, bytes)
    {:ok, image} = Image.open(tmp, access: :sequential, fail_on: :error)
    image
  end

  # A genuine 3-band RGB image (not a constant): a few colored rects.
  defp solid_rgb(w, h) do
    w
    |> Image.new!(h, color: :white)
    |> Image.Draw.rect!(0, 0, w, div(h, 2), color: :red)
    |> Image.Draw.rect!(0, 0, div(w, 3), div(h, 3), color: :blue)
  end

  defp setup_libvips do
    # Disable the libvips operation cache so a retained cached buffer cannot
    # perturb the high-water reading (mirrors bench/decode_modes.exs).
    Vix.Vips.cache_set_max(0)
    Vix.Vips.cache_set_max_mem(0)
  end

  # --- reporting ---

  defp report(rows) do
    IO.puts("\n" <> Enum.join(@columns, ","))

    Enum.each(rows, fn row ->
      IO.puts(Enum.map_join(@columns, ",", fn c -> to_string(Map.get(row, String.to_atom(c), row[:error] || "")) end))
    end)

    b = Enum.find(rows, &(&1[:arm] == "B"))
    print_gaps(rows, b)
  end

  defp print_gaps(_rows, nil), do: IO.puts(:stderr, "\n(no Arm B floor row; cannot compute gaps)")

  defp print_gaps(rows, b) do
    base = int(b[:libvips_peak_bytes])

    IO.puts("\nGap vs Arm B (cap-sized floor = #{mib(base)} libvips high-water):")
    IO.puts(cell("cell", 18) <> cell("pre-clamp", 14) <> cell("high-water", 13) <> cell("gap A-B", 12))

    Enum.each(rows, fn row ->
      if row[:arm] == "A" do
        hw = int(row[:libvips_peak_bytes])

        IO.puts(
          cell(row[:case], 18) <>
            cell("#{row[:pre_w]}x#{row[:pre_h]}", 14) <>
            cell(mib(hw), 13) <> cell(mib(hw - base), 12)
        )
      end
    end)

    self_row = Enum.find(rows, &(&1[:arm] == "selfcheck"))

    if self_row,
      do: IO.puts("\nself-check high-water: #{mib(int(self_row[:libvips_peak_bytes]))} (must be a large nonzero number; see stderr OK/FAIL)")
  end

  # --- peak RSS sampling (secondary/directional; gate uses libvips high-water) ---

  defp start_rss_sampler do
    pid = spawn(fn -> sample_loop(read_rss_bytes()) end)
    {pid, nil}
  end

  defp stop_rss_sampler(pid) do
    send(pid, {:stop, self()})

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
      10 -> sample_loop(max(peak, read_rss_bytes()))
    end
  end

  defp read_rss_bytes do
    case :os.cmd(~c"ps -o rss= -p #{System.pid()}") do
      ~c"" -> 0
      chars -> chars |> to_string() |> String.trim() |> Integer.parse() |> rss_kb()
    end
  end

  defp rss_kb({kb, _}), do: kb * 1024
  defp rss_kb(:error), do: 0

  # --- helpers ---

  defp now_ms, do: System.monotonic_time(:millisecond)
  defp int(nil), do: 0
  defp int(v) when is_integer(v), do: v
  defp int(v), do: (case Integer.parse(to_string(v)) do
                      {n, _} -> n
                      :error -> 0
                    end)

  defp mib(b) when is_integer(b), do: "#{Float.round(b / 1_048_576, 1)} MiB"
  defp mib(_), do: "-"

  defp cell(v, w), do: String.pad_trailing(to_string(v), w)
end

OversizedBufferBench.main(System.argv())
