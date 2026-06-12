# Source streaming/seekable overlap — synthetic probe findings (#263, Phase 1)

**Status: gate complete — NO-GO for slow-source latency.** The synthetic Vix-level
probe does not find a slow-source latency win that justifies adopting the forked
native dependency (`hlindset/vix` `SourceSpool`). Recommendation: document and stay on
the current drain-to-binary baseline. Phase 2 (the real-`ImagePipe.call` harness,
single-open resolution, `/info` early-abort) is **not** greenlit by these numbers.

Harness: [`bench/source_overlap_probe.exs`](../../../bench/source_overlap_probe.exs).

## The question this gates

imgproxy's stated headline win for a seekable source buffer is **slow-download
overlap**: decode overlaps the download instead of following it, so total ≈
`T_download` and you save ~`T_decode`. The issue framed the decisive case as
*seek-heavy formats* (HEIF/AVIF, multipage/tiled TIFF), where `:pipe` must buffer the
whole stream (`read_to_memory`) before decoding and therefore *only* `:spool` could
overlap. The probe answers, cheaply and before any pipeline wiring: **does decode
actually overlap a slow download, and for seek-heavy formats only via `:spool`?**

## Method

A synthetic, Vix-level probe (no HTTP / pipeline): an Elixir enumerable is fed
straight to `Vix.Vips.Image.new_from_enum/2`. `:pipe` exercises the real OS-pipe
feeder; `:spool` fills the real native seekable buffer (`Vix.SourceSpool`). A
`Stream.unfold` throttle paces delivery to a target bytes/sec.

Per `(fixture, rate)` we time a forced **full** decode (`Operation.avg/1` reads every
pixel) reached three ways, plus two references:

- `download_only` — drain the throttled enum, no decode → the download floor.
- `decode_cold` — `new_from_buffer` + `avg` from an in-RAM copy → pure decode cost
  (rate-independent; the **ceiling on any overlap saving**).
- `baseline` — drain to a binary, *then* decode → today's ImagePipe shape (serial).
- `pipe` / `spool` — `new_from_enum(mode:)` + `avg`, end-to-end → the overlapped path.

Derived per overlapped mode: `saving = baseline − total`;
`tail = total − download_only` (decode not hidden); `overlap% = (decode_cold − tail) /
decode_cold` (fraction of decode hidden under the download).

Fixtures (same pixels, three encodings; generated on the fly into the gitignored
`bench/.cache/`): **JPEG** (forward), **AVIF** = AV1-in-HEIF (seek-heavy, expensive
decode), **tiled JPEG-compressed TIFF** (seek-heavy, cheap decode).

**Anti-tautology self-checks** (all passed on every cell): `avg` really forces a
decode (`decode_cold` ≫ header-only open, 28–700×); the enum really throttles
(`download_only` ≈ `size/rate`, ratio ~1.07); `baseline` is serial
(`≈ download_only + decode_cold`, Δ < 10%). The forward-`:pipe` cell is the positive
control — it *does* overlap (64–74%), so the harness detects overlap when present.

## Results (local macOS, libvips with heif/avif/tiff; medians, 3 samples + warmup)

Rates in Mbps (1 Mbps = 125 KB/s). `save` = wall-clock saved vs baseline; `ovl` =
fraction of decode hidden.

```
FORWARD  jpg  (3433KB, decode_cold 49.0ms)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms     50.3ms    52.9 ( 0%/ 0%)    50.8 ( 0%/ 0%)
  100Mbps     304.0ms    355.2ms   334.5 ( 6%/38%)   313.1 (12%/81%)
  16Mbps     1889.0ms   1938.8ms  1903.1 ( 2%/71%)  1893.3 ( 2%/91%)
  4Mbps      7528.0ms   7560.3ms  7545.5 ( 0%/64%)  7534.2 ( 0%/87%)

SEEK_HEAVY  avif  (1160KB, decode_cold 226.1ms)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms    237.1ms   232.6 ( 2%/ 0%)   239.2 ( 0%/ 0%)
  100Mbps     112.0ms    344.2ms   339.4 ( 1%/ 0%)   348.1 ( 0%/ 0%)
  16Mbps      639.9ms    872.7ms   874.4 ( 0%/ 0%)   872.4 ( 0%/ 0%)
  4Mbps      2544.9ms   2786.7ms  2778.7 ( 0%/ 0%)  2781.8 ( 0%/ 0%)

SEEK_HEAVY  tiff  (7105KB, decode_cold 14.2ms)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms     13.4ms    17.6 ( 0%/ 0%)    14.0 ( 0%/ 2%)
  100Mbps     624.0ms    638.0ms   646.3 ( 0%/ 0%)   641.4 ( 0%/ 0%)
  16Mbps     3889.9ms   3908.9ms  3907.9 ( 0%/ 0%)  3912.1 ( 0%/ 0%)
  4Mbps     15551.2ms  15560.9ms 15582.0 ( 0%/ 0%) 15588.7 ( 0%/ 0%)
```

These are local timings; treat the **pattern**, not the absolute ms, as the result.

## Interpretation

**The absolute saving from overlap is bounded by `decode_cold`** — overlap can at best
hide the entire decode. That bound is what kills the case:

1. **Forward (JPEG) overlaps well — but decode is cheap, so the win is negligible.**
   `overlap%` climbs to 64–91% as bandwidth drops; `:spool` even beats `:pipe` (87% vs
   64% at 4 Mbps). But JPEG `decode_cold` is only ~49 ms, so the wall-clock saving is
   ~26 ms on a 7.5 s download — **0%**. The mechanism works; there is just nothing
   worth hiding. And forward overlap needs only `:pipe` — the spool adds no latency
   advantage here.

2. **AVIF — the seek-heavy format with *expensive* decode (226 ms), exactly where
   overlap would pay — shows 0% overlap via `:pipe` AND `:spool`, at every rate.**
   AV1 intra decode needs the complete compressed bitstream before it can produce
   pixels: it is a monolithic CPU step that runs *after* arrival, seekable buffer or
   not. The spool lets libvips *seek* the arriving bytes, but seeking-during-arrival is
   not decode-overlap — the issue's hypothesis conflated the two. `total ≈ baseline ≈
   download + decode` confirms full serialization.

3. **Tiled TIFF decode is too cheap (~14 ms) to register any overlap**, so it cannot
   adjudicate the spool either way; nothing observed.

The cell the issue expected to justify the spool — *seek-heavy × slow source ⇒ `:spool`
overlap, the biggest win* — **is empty**. The overlappable formats decode cheaply and
need only `:pipe`; the one expensive-decode seek-heavy format cannot overlap at all.

## Decision

**NO-GO on adopting the forked native dependency for slow-source latency.** Stay on the
current drain-to-binary baseline ([`processor.ex`](../../../lib/image_pipe/request/processor.ex)).
The gate (`bench/source_overlap_probe.exs`) requires a material `:spool` saving on a
seek-heavy fixture (≥100 ms and ≥5% at the slow rate); none is present.

## Caveats / not measured (deliberately out of scope for the gate)

- **Memory shape, not latency.** The spool holds the encoded bytes in a native buffer
  instead of on the BEAM heap (and avoids the transient ~2× concat spike of
  `Enum.to_list |> IO.iodata_to_binary`). That is a *separate* question from slow-source
  latency and is **not** measured here; it would need the #164-style peak-RSS /
  high-water probes and a concurrency (`N × content_length`) ceiling. If the spool is
  ever revisited, it should be on the memory axis, not latency.
- **`:pipe` for forward formats is a real, fork-light win** (overlap that the drain
  baseline forfeits). It rides on `new_from_enum` itself, not on `SourceSpool`. Whether
  it is worth wiring into the real pipeline depends on whether forward decode is ever a
  meaningful fraction of request latency — these numbers say usually not.
- **Not exercised:** the real `ImagePipe.call`/`Processor` path, the two-open →
  single-open resolution (#170), the `/info` early-abort vs `size` tension, a
  genuinely *expensive* incremental-seek decode (e.g. a very large multipage/pyramidal
  TIFF), and HEIF preview/thumbnail-box early reads.

## Reproduce

```bash
mise exec -- mix run bench/source_overlap_probe.exs            # default matrix
mise exec -- mix run bench/source_overlap_probe.exs 5 unlimited,40,8,2
mise exec -- mix run bench/source_overlap_probe.exs --csv      # machine-readable
mise exec -- mix run bench/source_overlap_probe.exs --regen    # rebuild fixtures
```

Requires the vix fork that ships `new_from_enum(mode: :pipe | :spool | :auto)`:
`{:vix, git: "https://github.com/hlindset/vix.git", ref: "c5be4745bb5a24ee998d3221c84dfd75d41f8f0d"}`
(`my-experimental-fixes`). The probe asserts the capability at startup. The bump from
the prior pin also brings the `tracked_get_mem_highwater` NIF fix the memory benches
rely on.
