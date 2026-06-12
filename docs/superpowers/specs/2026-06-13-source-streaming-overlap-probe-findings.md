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

Per `(fixture, rate)` we time the decode **sink** reached three ways, plus two
references:

- `download_only` — drain the throttled enum, no decode → the download floor.
- `decode_cold` — open + `avg` from an in-RAM copy → pure decode cost
  (rate-independent; the **ceiling on any overlap saving**).
- `baseline` — drain to a binary, *then* decode → today's ImagePipe shape (serial).
- `pipe` / `spool` — `new_from_enum(mode:)` + sink, end-to-end → the overlapped path.

Derived per overlapped mode: `saving = baseline − total`;
`tail = total − download_only` (decode not hidden); `overlap% = (decode_cold − tail) /
decode_cold` (fraction of decode hidden under the download).

**The sink models the real pipeline, not a synthetic full decode.** The default
`shrink` sink opens `access: :sequential` (the Processor always opens sequential) and
shrink-on-loads to ~1024px where the format supports it (`DecodePlanner`), then reads
every (shrunk) pixel with `Operation.avg/1` — the work a request must do before it can
transform/encode. A `full` sink (sequential, no shrink-on-load) is also available; it
is a *conservative* choice for hunting overlap (a larger decode = more work that could
hide under the download), and gives the same verdict. **Crucially, only JPEG has
shrink-on-load; HEIF/AVIF and TIFF have none** (see the support table below), so for
the seek-heavy formats both sinks decode full-res — exactly what the real pipeline
pays.

Fixtures (2400×3600, same pixels, three encodings; generated on the fly into the
gitignored `bench/.cache/`): **JPEG** (forward), **AVIF** = AV1-in-HEIF (seek-heavy,
expensive decode), **tiled JPEG-compressed TIFF** (seek-heavy, cheap decode).

**Anti-tautology self-checks** (all passed on every cell): `avg` really forces a
decode (`decode_cold` ≫ header-only open, 22–700×); the enum really throttles
(`download_only` ≈ `size/rate`, ratio ~1.07); `baseline` is serial
(`≈ download_only + decode_cold`, Δ < 15%). The forward cell is the positive
control — it *does* overlap (40–95%), so the harness detects overlap when present.

### Shrink-on-load support (the decisive structural fact)

| format | source loader shrink-on-load | real-pipeline decode |
|---|---|---|
| JPEG (forward) | `shrink:` (DCT, powers of 2) | shrink-decode (still entropy-decodes the whole stream) |
| AVIF / HEIF (seek-heavy) | **none** (only `page`/`n`/`thumbnail`) | **full-res decode**, then resize |
| TIFF (seek-heavy) | **none** (only `page`/`n`) | **full-res decode**, then resize |

So the probe's seek-heavy decode is not an artifact of a heavy synthetic sink — it is
what the pipeline genuinely does for those formats.

## Results — realistic `shrink` sink (local macOS, libvips w/ heif/avif/tiff; medians, 3 samples + warmup)

Rates in Mbps (1 Mbps = 125 KB/s). `save` = wall-clock saved vs baseline; `ovl` =
fraction of decode hidden.

```
FORWARD  jpg  (3433KB, decode_cold 40.2ms — shrink-on-load to ~1200px)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms     38.5ms    42.0 ( 0%/  0%)   41.3 ( 0%/  0%)
  100Mbps     304.1ms    342.5ms   328.3 ( 4%/ 40%)  306.2 (11%/ 95%)
  16Mbps     1888.1ms   1928.1ms  1895.2 ( 2%/ 82%) 1900.5 ( 1%/ 69%)
  4Mbps      7511.0ms   7550.3ms  7534.6 ( 0%/ 41%) 7509.3 ( 1%/104%)

SEEK_HEAVY  avif  (1160KB, decode_cold 223.7ms — no shrink-on-load, full decode)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms    212.1ms   232.6 ( 0%/ 0%)   234.2 ( 0%/ 0%)
  100Mbps     112.0ms    339.2ms   346.1 ( 0%/ 0%)   341.6 ( 0%/ 0%)
  16Mbps      640.7ms    870.3ms   879.3 ( 0%/ 0%)   866.5 ( 0%/ 0%)
  4Mbps      2546.2ms   2766.9ms  2780.9 ( 0%/ 0%)  2782.9 ( 0%/ 0%)

SEEK_HEAVY  tiff  (7105KB, decode_cold 14.0ms — no shrink-on-load, full decode)
  rate       download   baseline   pipe (save/ovl)   spool (save/ovl)
  unlimited     0.0ms     11.9ms    19.4 ( 0%/ 0%)   13.1 ( 0%/ 7%)
  100Mbps     624.0ms    643.3ms   647.7 ( 0%/ 0%)   642.7 ( 0%/ 0%)
  16Mbps     3888.0ms   3910.5ms  3910.9 ( 0%/ 0%)  3908.8 ( 0%/ 0%)
  4Mbps     15546.8ms  15576.4ms 15696.9 ( 0%/ 0%) 15593.7 ( 0%/ 0%)
```

These are local timings; treat the **pattern**, not the absolute ms, as the result. In
the tiny-decode / long-download regime the `save`/`ovl` figures carry jitter of order a
few % (e.g. spool `ovl` 104% and pipe tiff `−120ms` at 4 Mbps are noise about a ~0 ms
true value) — the verdict reads the materiality threshold, not these point values.

The conservative `full` sink (`… full`) gives the same NO-GO: JPEG `decode_cold` 49 ms
(vs 40 ms), AVIF/TIFF identical; seek-heavy overlap still 0% at every rate.

## Interpretation

**The absolute saving from overlap is bounded by `decode_cold`** — overlap can at best
hide the entire decode. That bound is what kills the case:

1. **Forward (JPEG) overlaps well — but decode is cheap, so the win is negligible.**
   `overlap%` climbs to 40–95%+ as bandwidth drops (`:spool` and `:pipe` comparable).
   But JPEG `decode_cold` is only ~40 ms (and shrink-on-load barely shrinks it — DCT
   shrink still entropy-decodes the whole stream, 56 ms → 39 ms for `shrink: 4`), so the
   wall-clock saving is ≤41 ms on a 7.5 s download — **≤1%**. The mechanism works; there
   is just nothing worth hiding. And forward overlap needs only `:pipe` — the spool adds
   no latency advantage here.

2. **AVIF — the seek-heavy format with *expensive* decode (224 ms), exactly where
   overlap would pay — shows 0% overlap via `:pipe` AND `:spool`, at every rate.**
   AV1 intra decode needs the complete compressed bitstream before it can produce
   pixels: it is a monolithic CPU step that runs *after* arrival, seekable buffer or
   not. The spool lets libvips *seek* the arriving bytes, but seeking-during-arrival is
   not decode-overlap — the issue's hypothesis conflated the two. `total ≈ baseline ≈
   download + decode` confirms full serialization.

3. **Tiled TIFF decode is too cheap (~14 ms) to register any overlap**, so it cannot
   adjudicate the spool either way; nothing observed.

**What actually destroys overlap is not "needing all pixels."** The real pipeline does
stay sequential and shrink-on-load where it can — but a *sequential forward* decode
overlaps fine (the positive control proves it). Overlap is destroyed by either (a) the
loader having to **buffer the whole input before producing any output** — seek-heavy
formats via `:pipe`, which `:spool` is meant to fix — or (b) a **monolithic decode**
that needs the complete bitstream (AV1). For AVIF, `:spool` fixes (a) but (b) remains,
so there is still nothing to overlap. And because the seek-heavy formats have **no
shrink-on-load**, staying sequential does not let the pipeline consume *less* of the
source early either — it needs all of it before the monolithic decode.

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
- **`/info` (header-only) is the one genuine "don't read all pixels" case** and is the
  most promising place for a streaming win: the header arrives in the first bytes, so a
  seekable/streamed source could answer and *abort the rest of a slow download*. The
  probe does **not** measure this (its sink decodes pixels). It is in tension with
  reporting `size` (which needs the full byte count — see #260) and should get its own
  header-only / early-abort measurement if pursued. For HEIF specifically the `thumbnail`
  load flag (embedded preview) is a related untested early-availability path.
- **Not exercised:** the real `ImagePipe.call`/`Processor` path, the two-open →
  single-open resolution (#170), and a genuinely *expensive* incremental-seek decode
  (e.g. a very large multipage/pyramidal TIFF) — though no common web format offers
  expensive-and-incrementally-decodable, which is what the spool would need.

## Reproduce

```bash
mise exec -- mix run bench/source_overlap_probe.exs            # default matrix (shrink sink)
mise exec -- mix run bench/source_overlap_probe.exs 5 unlimited,40,8,2
mise exec -- mix run bench/source_overlap_probe.exs full       # conservative full-res decode
mise exec -- mix run bench/source_overlap_probe.exs --csv      # machine-readable
mise exec -- mix run bench/source_overlap_probe.exs --regen    # rebuild fixtures
```

Requires the vix fork that ships `new_from_enum(mode: :pipe | :spool | :auto)`:
`{:vix, git: "https://github.com/hlindset/vix.git", ref: "c5be4745bb5a24ee998d3221c84dfd75d41f8f0d"}`
(`my-experimental-fixes`). The probe asserts the capability at startup. The bump from
the prior pin also brings the `tracked_get_mem_highwater` NIF fix the memory benches
rely on.
