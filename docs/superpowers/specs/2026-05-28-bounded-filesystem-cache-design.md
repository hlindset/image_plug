# Bounded Filesystem Cache Design

## Scope

`ImagePipe.Cache.FileSystem` stores processed image responses on disk with no
size cap; entries accumulate until the operator runs out of space or sweeps
the directory externally. This design adds an optional bounded mode driven by
a `:max_size_bytes` soft cap, with cost-aware W-TinyLFU admission and
eviction, a Bloom doorkeeper, persisted Count-Min Sketch (CMS) state for
warm-start across restarts, and multi-node warm-start by reading peer state
files at boot.

V1 covers:

- Soft `:max_size_bytes` cap with synchronous victim selection at commit time.
- Cost-aware W-TinyLFU admission policy (frequency × encode/transform cost ÷
  body size) with a Bloom doorkeeper.
- Persisted CMS, doorkeeper, protected-segment list, and aging epoch to a
  per-node state file (`<node_id>.state`) for warm-start.
- Multi-node warm-start by reading peer state files at boot, with a TTL-based
  cleanup ticker.

V1 doesn't cover live cross-node gossip (no `:pg` transport, no live
broadcasts), value-level cache sharing through the network (bodies share via
the filesystem if the filesystem is shared, otherwise not at all), or
sharded ownership / routing schemes. "Deferred Behaviors" names these
omissions so they stay explicit.

This extends the existing `ImagePipe.Cache.FileSystem` adapter in place. The
unbounded path stays the default and is unchanged when `:max_size_bytes` is
absent.

## Current State

`ImagePipe.Cache.FileSystem` is a pure-callback module implementing the
`ImagePipe.Cache` behaviour. It stores cache entries under
`<root>/<path_prefix>/ab/cd/<hash>.meta` and content-addressed body files
`<hash>.<body_sha256>.body`. The adapter validates paths under root with
`Path.safe_relative/2`, writes via temp + atomic rename, and treats decode
failures, invalid metadata, and read errors as cache misses that fail open.

The adapter has no eviction. Entries live until they're removed externally.
`:max_body_bytes` rejects individual entries that exceed a per-entry size
limit but doesn't bound total disk use.

`Entry.Metadata` carries `content_type`, `headers`, `created_at`, and
`output_format`. The `Sink` flow opens a sink, writes chunks, commits or
aborts. Telemetry events `[..., :cache, :stage, ...]` and
`[..., :cache, :write, ...]` fire on stage and commit results.

This codebase is greenfield and unreleased. No on-disk cache compatibility
needs to be preserved.

## Design Goals

Keep the cache contract path-oriented and deterministic. Bounded mode is opt-in
via configuration; absent `:max_size_bytes`, behavior is unchanged.

Admission and eviction decisions must reflect what actually costs the cache
the most to regenerate. An image cache has wildly varying entry sizes and
processing costs — a 4 KB favicon and an 8 MB hero image shouldn't compete on
the same frequency axis. Use cost-aware scoring (frequency × cost ÷ size).

Treat admission state as warmth metadata, not source of truth. The body
files on disk are authoritative; CMS, queues, and the doorkeeper are
in-memory state with disk-backed warm-start. A new node booting with no
warm-start data should serve traffic correctly, just with worse admission
decisions until it builds frequency knowledge.

Fail open on coordination state errors. State file corruption, decode
failures, missing peer files, and filesystem permission issues should log,
emit telemetry, and degrade gracefully — never crash the request path.

Keep the design surface narrow. No `StateSync` behaviour, no live peer
gossip protocol, no broker process. Multi-node coordination is exclusively
"reads other nodes' files at boot" plus periodic cleanup of stale files.

## Architecture and Components

All new modules live under the existing `ImagePipe.Cache` boundary, nested
under `ImagePipe.Cache.FileSystem.*`. No new top-level namespace.

New modules:

- `ImagePipe.Cache.FileSystem.Sketch` — pure-data Count-Min Sketch with
  element-wise merge, conservative-update increment, sample-based aging, and
  binary serialization.
- `ImagePipe.Cache.FileSystem.Doorkeeper` — Bloom filter (~1–2 KB) that gates
  one-hit-wonders out of the CMS. Reset on the same schedule as CMS aging.
- `ImagePipe.Cache.FileSystem.Policy` — pure functions implementing
  cost-aware W-TinyLFU admission (`admit?/3`) and victim selection
  (`victim/2`) over the queue state.
- `ImagePipe.Cache.FileSystem.Admission` — `GenServer` owning the in-memory
  CMS, doorkeeper, W-TinyLFU queues (window + SLRU), local-size accounting,
  and a `boot_cms` snapshot loaded from peer files at startup. Serializes
  admission decisions and eviction. Exposes `child_spec/1`.
- `ImagePipe.Cache.FileSystem.Registry` — `Registry` for naming `Admission`
  processes by `{root, node_id}` so multiple bounded caches per host are
  supported.

`ImagePipe.Cache.FileSystem` remains the public-facing adapter:

- Conforms to the `ImagePipe.Cache` behaviour exactly as today.
- Exposes `child_spec/1` returning a supervisor when `:max_size_bytes` is
  set. Supervisor starts `Registry` and `Admission`. Unbounded mode (no
  `:max_size_bytes`) returns no child spec; host doesn't need to add
  anything to their supervision tree.
- Dispatches on cache hits (cast hit-increment to `Admission`) and on
  `commit_sink` (synchronous admission decision returning victim
  descriptors with `key_hash` and `body_sha256`; adapter then deletes
  victim files itself).

Every commit serializes through a single `Admission` process via
synchronous `call`. `admit/1` is in-memory and runs in microseconds, so
single-process serialization is fine for typical image-proxy throughput
(thousands of commits/sec). The serialization ceiling becomes relevant
only at much higher write rates, where sharding `Admission` by key-hash
prefix is a possible future option (it complicates byte accounting, so
deliberately deferred). Per-call victim walks over ETS ordered sets are
O(victims) inside the critical section; typical victim counts are
small.

`ImagePipe.Plug.init/1` does not verify the registered `Admission`
process at startup — adapter lookup is lazy at request time (see
Supervision integration). A missing process means the adapter treats
the request as cache-disabled and logs a warning; traffic continues to
flow rather than crashing the boot path.

## Admission and Eviction Algorithm

### Count-Min Sketch

4 hash rows × 4096 counters × 8-bit, ~16 KB per node. Hash positions come
from `:erlang.phash2/2` with four different salts. Conservative update
(increment only the minimum hash positions per key) for better accuracy.

Configurable via `:sketch_depth` (default 4) and `:sketch_width`. The
default for `:sketch_width` is derived from `:max_size_bytes` assuming a
~50 KB average entry: `max(4096, max_size_bytes ÷ 25_000)`. For a 10 GB
cap this gives ~400K counters per row (~400 KB at 4 rows × 8-bit); for a
100 MB cap, the floor of 4096. Operators with significantly different
average entry sizes should override.

### Doorkeeper

Bloom filter, default `:doorkeeper_bits = max(8192, max_size_bytes ÷
12_500)` — sized ~2× the sketch width so the false-positive rate at peak
distinct-key count is manageable. Same "assume ~50 KB average entry"
caveat. Sits in front of CMS, triggered by **any observed sighting** of
a key — either a hit (on `get/2`) or a miss processed through to a
commit (on `commit_sink`):

- First sighting of a key → add to doorkeeper, don't touch CMS.
- Subsequent sighting → CMS increment.

Counting misses-resolved-to-commits as sightings is necessary for
**oversized entries** that skip the window: those entries never become
window-cached hits, so their only mechanism to accumulate frequency is
across repeated commits for the same key. Without miss-as-sighting they
could never accumulate the frequency needed to win main admission, and
repeated requests would produce unbounded recompute storms. For
window-eligible entries the extra increment on first commit is
redundant-but-harmless: the window provides the cheap runway, and the
doorkeeper-add on first sighting prevents one-hit-wonders from
polluting CMS.

Doorkeeper resets on the same schedule as CMS aging. The point is to
keep one-hit wonders out of the CMS so counter capacity goes to actually
recurring keys.

### Aging

Sample-based reset. Each CMS increment also increments a global counter.
When the counter crosses `sketch_width × 10`, every CMS counter is halved
(`(c + 1) >>> 1` to avoid sticky zeros) and the doorkeeper is cleared. The
`aging_epoch` field in the serialized snapshot increments each time aging
runs; `increments_since_reset` captures progress within the current epoch
for fidelity across warm-restart.

### W-TinyLFU queue layout (byte-budgeted)

Three queues, each tracking bytes:

- **Window LRU** — `:window_ratio × :max_size_bytes` (default 1%; `0`
  disables the window for operators with measured-steady workloads).
  Holds freshly admitted entries. Fresh commits go here unconditionally
  (unless oversized — see admission flow). The window's job is to give
  rising entries a runway: while in the window, an entry serves hits
  from disk normally, those hits accumulate CMS frequency, and when the
  entry is eventually pushed out by newer admissions it competes for
  main with real evidence. **Empty at boot, never persisted** — window
  is pure recency, not warmth memory.

  When `:window_ratio` is `0`, the window is effectively disabled: every
  candidate's `size_bytes > 0` triggers the "oversized" branch of the
  admission flow and goes directly to the main gate. Rejections become
  more frequent under this configuration since new entries must beat
  incumbents on first commit. Use only when you have measured a steady
  long-tail workload where the bursty recompute-storm scenario doesn't
  apply.
- **Probationary** (main).
- **Protected** (main). Promotion from probationary on second hit.

The main budget (`:max_size_bytes` − window) is shared between
probationary and protected. Protected has a **soft target** of 20% of the
main budget — at promotion time, if protected exceeds 20%, its LRU is
demoted back to probationary. Probationary uses whatever main bytes
protected isn't using: `probationary_budget = main_budget −
max(0.20 × main_budget, current_protected_size)`. When protected is empty
(common under low-hit workloads), probationary gets the full main budget,
so no capacity is stranded. When protected hits its 20% target,
probationary settles at 80%.

Each queue is an `:ets.new(:ordered_set, ...)` table keyed by an
in-memory integer position + entry hash. `Admission` owns the tables
exclusively (no concurrent access). ETS is used for ordered iteration
during victim selection, not for shared access. Positions are
monotonically increasing arbitrary-size integers — BEAM bignums grow
indefinitely without overflow, so no compaction is required during
runtime. Positions are in-memory-only: never persisted, never cross
restart boundaries; on boot, main queues are rebuilt via the directory
scan with fresh positions starting from 1, and window starts empty.

### Queue entry shape

Each queue tracks the following per entry, all derived from the on-disk
meta file:

```elixir
%{
  key_hash: binary,           # cache key hash, 64 hex chars
  size_bytes: non_neg_integer,
  body_sha256: binary,        # needed to construct the body filename
  cost_us: non_neg_integer
}
```

`size_bytes` drives byte budgeting and is already on the existing meta
payload as `body_byte_size`. `body_sha256` is required to construct
`<hash>.<body_sha256>.body` when the adapter deletes a victim — Admission
returns full descriptors, not bare hashes. `cost_us` is the new metadata
field.

### Cost-aware scoring

```
score(entry) = frequency(key) × effective_cost(entry) / max(size_bytes, 1)

where effective_cost(entry) =
  if entry.cost_us > 0 then entry.cost_us
  else entry.size_bytes   # collapses to freq when cost is unknown
```

Score is a **float**, computed with Elixir's `/` operator. Integer
division (`div/2`) would silently truncate to zero for any large entry
where `freq × cost < size_bytes` (an 8 MB hero with cost=50 ms and freq=3
gives 0.0178…), destroying cost-awareness for exactly the entries the
design exists to protect.

`cost_us` is the sum of source-fetch, transform-execute, and encode
wall-clock durations from the miss that produced the entry. These stage
durations are all available before `commit_sink` runs; the request-level
`[..., :request, :stop]` span hasn't fired yet at commit time, so the
sum-of-stages is what we have. It captures the work the cache actually
avoids on a hit — send time, which the cache also avoids, is small enough
relative to fetch+transform+encode to ignore as a scoring signal.

When `cost_us` is 0 (e.g., `put_entry` calls without stage durations),
`effective_cost` falls back to `size_bytes` so the score collapses to
`freq` alone (size-neutral). This avoids the otherwise-pathological case
where cost-unknown entries score 4–6 orders of magnitude below
cost-known peers and become near-unadmittable.

### Admission flow

`Admission.admit(candidate_descriptor)` is the synchronous entry point
called by the adapter on commit. The candidate is a fresh entry being
written. Two layers: the **window step** (where it lands) and the **main
gate** (run for any entry that flows from window into main).

**Window step:**

1. **Hard reject:** if `candidate.size_bytes > :max_size_bytes`, reject
   outright. The entry cannot fit even an empty cache.
2. **Oversized:** if `candidate.size_bytes > window_budget`, skip the
   window and run the main gate directly with `candidate`. Whatever the
   main gate returns is the result of `admit/1`.
3. **Same-key re-commit:** if `candidate.key_hash` is already in some
   queue (window, probationary, or protected), replace the existing
   entry in place with the new descriptor (new `size_bytes`,
   `body_sha256`, `cost_us`). Do not run the main gate; the entry is
   already a cache resident.
   - **Hard reject on growth past hard cap:** if `candidate.size_bytes
     > :max_size_bytes`, reject the replacement and keep the old entry
     intact. The old entry remains valid; the adapter cleans the
     candidate's tmp files. Return `{:reject, :over_cap}`.
   - **Body victim only when content differs:** return the *old*
     descriptor as a victim **only if** `old.body_sha256 !=
     new.body_sha256`. For content-identical rewrites (same
     `body_sha256`), the new body file is the same path as the old —
     deleting the "old" body would delete the just-rewritten body.
     Skip body deletion; the meta file replacement is sufficient.
   - **Soft-cap exceedance allowed:** if the new descriptor's size
     pushes its queue over budget, do not evict the just-replaced
     entry to compensate (K is never its own victim). Allow the soft
     cap to overshoot; the next admission call will rebalance through
     normal eviction.
4. **Normal admission:** insert `candidate` at window MRU. While the
   window is over `window_budget`, pop the window LRU as `E` and run the
   main gate with `E`. Any victims the main gate produces, plus any
   window evictees that the main gate rejects, are collected into a
   single list returned with `{:admit, victims}`.

**Main gate** (for entry `X`, called from steps 2 or 4 above):

1. **Free main space:** if available main bytes ≥ `X.size_bytes`, insert
   `X` at probationary MRU. No victims. "Available main bytes" =
   `main_budget − current_probationary_size − current_protected_size`.
2. **Identify victims (probationary first, then protected under
   pressure):** walk probationary LRU outward, collecting victims until
   cumulative `size_bytes` ≥ `X.size_bytes`. If probationary is
   exhausted before enough bytes are freed, **extend the walk into
   protected LRU outward** as additional victims. Protected entries
   selected this way are demoted to victim status; they don't return to
   probationary. This keeps protected from one-way ratcheting under
   sustained admission pressure: an entry that earned protected status
   but is no longer accessed can still be evicted when newer hot
   entries need its bytes. If both queues together can't free enough
   bytes, return `:no_evictable_victims`.
3. **Score check (weighted average):** admit `X` only if

   ```
   score(X) > Σ(freq(v) × effective_cost(v)) / Σ(size_bytes(v))
   ```

   — i.e., the candidate's value-per-byte must exceed the
   value-per-byte of the bytes being freed. Otherwise the candidate
   loses; its files must be deleted (it's in the victim list returned
   by the *outer* `admit/1` call). The same weighted-average rule
   applies whether victims came from probationary alone or a mix of
   probationary and protected.

The weighted-average rule compares like with like: candidate's `freq ×
cost / size` against the aggregate `Σ(freq × cost) / Σ(size)` of
victims. A large candidate sweeping in a high-scoring outlier isn't
unfairly penalized because the outlier's high score is diluted by other
victims' bytes. This was the previous spec's "beat the best victim"
pathology.

**Return contract:**

- `{:admit, victims}` — candidate is admitted (adapter should rename
  tmp files into place). `victims` is a list of descriptors
  `[%{key_hash, body_sha256, ...}]` whose body+meta files the adapter
  must delete. The list may contain:
  - probationary victims displaced to make room for the candidate (or
    for a window evictee that won main),
  - window evictees that lost their main-gate run (those entries had
    been cached previously and now must be removed from disk),
  - the prior descriptor when this is a same-key re-commit (step 3),
    **only when `old.body_sha256 != new.body_sha256`** — content-
    identical rewrites skip the body deletion.
- `{:reject, reason}` — candidate is rejected (oversized step 2 only,
  when main gate rejects). Adapter cleans tmp files. `reason` is one of
  `:over_cap`, `:score_too_low`, or `:no_evictable_victims`.

In normal-path admission (window step 4), the candidate is always
admitted — only a window evictee can lose the main gate, never the fresh
candidate. So `{:reject, ...}` is reserved for the oversized-direct-to-
main path and the hard-cap path.

Rejection emits a `cache: :admission_rejected` stage telemetry event
with the `reason:` atom. Same fail-open shape as `:max_body_bytes` today.

### Hit promotion

- Hit on window → move to window MRU. Doorkeeper-gated CMS increment for
  the key. The entry stays in the window; promotion to main happens via
  the window-eviction path, not by hit count alone.
- Hit on probationary → move to protected MRU. If protected now exceeds
  its 20% soft target, demote protected LRU to probationary MRU.
  Doorkeeper-gated CMS increment.
- Hit on protected → move to protected MRU. Doorkeeper-gated CMS
  increment.

### Soft cap and reconciliation

Concurrent commits may both pass admission and both write, briefly
exceeding the cap. The next admission call sees the new total and selects a
larger victim batch to compensate. Overshoots are bounded by the *sum* of
in-flight entry sizes across all concurrent commits whose admission
decisions have completed but whose file renames and victim deletes have
not yet run — not just the largest single one. For typical workloads
this is a small handful of entries; telemetry captures the overshoot
magnitude.

Admission's accounting is updated speculatively when a candidate is
admitted — bytes are counted as freed when victim descriptors are
returned to the adapter, even though the adapter's `File.rename/2` and
`File.rm/1` calls happen after that. If any of those file operations
fail, in-memory accounting diverges from disk: the cache may believe an
entry is admitted when its rename failed, or that bytes are freed when
victim deletion failed. These are tolerated as part of the soft-cap
contract and repaired at restart — the boot scan walks the actual
on-disk state and rebuilds queues from ground truth. Between restarts,
drift is bounded by the rate of `File.rename/2` and `File.rm/1`
failures, which are corner cases (disk full, permissions, filesystem
corruption) that indicate the cache has bigger problems than admission
drift.

**Same-key concurrent commits.** The existing unbounded adapter already
has a race when two requests miss for the same key concurrently: both
write to different randomized tmp files and both rename to
`<hash>.meta`, last-rename-wins. Body files are content-addressed so
they don't collide, but one body becomes orphaned (no meta points to
it). Bounded mode inherits this race; additionally, `Admission`'s
in-memory descriptor for the key may briefly disagree with the meta
on disk if the timing interleaves admit calls with renames. The
practical effect is the same as the unbounded race: a transient
orphan body, possibly miscounted bytes in `Admission` until restart.
Restart-via-boot-scan reconciles. Not engineered around in V1; a per-
key finalization callback or generation token would close the window
but adds complexity disproportionate to the impact for typical
image-proxy traffic where deduplication usually happens upstream.

**This is a bounded-Admission-tracked-bytes contract, not a strict
disk-bytes contract.** Orphan bodies (from concurrent same-key races
or victim-delete failures) are bytes the cache has stopped counting
but that still exist on disk. Operators who need a strict disk bound
should monitor disk usage independently (e.g., `du`) and treat the
soft cap as a target rather than a guarantee.

### Merged CMS amplification and ordering caveats

When multiple nodes serve overlapping traffic through a load balancer,
each node's `local_cms` records local sightings independently and `boot_cms`
element-wise sums peer CMSes at restart. A key seen 100 times on each of
3 nodes shows as count 300 in the merged view. This amplifies absolute
counts but **approximately** preserves relative ordering for
well-separated counts. Two important caveats:

- Collision error sums across the merge — keys that are near-tied
  pre-merge can reorder post-merge due to summed per-sketch collision
  noise.
- Conservative-update sketches aren't strictly additive: the
  element-wise sum of two conservative-update sketches isn't itself a
  conservative-update sketch, and the merged estimate's relationship to
  any global true count is approximate at best.

Treat `boot_cms` as a directional hint rather than a precise oracle.
The practical effect on admission decisions is small — scoring decisions
are made on ratios, not absolute counts.

**Aging applies to both, but is triggered by local activity only.** The
aging counter (sample-based reset at `sketch_width × 10` increments) is
incremented by `local_cms` activity only. When the threshold is
crossed, the halving operation applies to *both* `local_cms` and
`boot_cms`. Peer-derived data fades gradually as local traffic
dominates, but boot counts can never trigger aging on their own. A busy
node fades its peer-derived knowledge quickly; an idle node holds stale
peer data indefinitely. Acceptable — the idle node has nothing better
to score against.

## Data Flow and On-Disk Layout

### On-disk layout

```
<root>/<path_prefix>/                      # existing partitioned cache entries
  ab/cd/<hash>.meta                        # existing, fields added
  ab/cd/<hash>.<body_sha256>.body          # existing, unchanged

<root>/.cache_state/                       # new — coordination state, not entries
  <node_id>.state                            # per-node CMS + doorkeeper + protected-segment IDs
```

The `.cache_state/` directory uses a leading-dot name so existing
hash-partition path matching naturally excludes it. `validate_under_root/2`
already prevents user input from reaching it.

### Metadata fields added

The `.meta` payload (and `Entry.Metadata`) gains one field:

- `cost_us` — integer microseconds. Sum of source-fetch, transform-execute,
  and encode stage durations from the miss that produced the entry.
  Captures the work the cache avoids on a hit. 0 when unknown (e.g., a
  put_entry path without stage durations).

The cache key hash (already on `ImagePipe.Cache.Key`) is what `Admission`
uses to identify entries in queues, protected lists, and admit/evict
calls — no separate `entry_id` is introduced.

This is a greenfield codebase — no migration, no version gating, no
backwards compatibility for "old" entries. Old shapes don't exist.

### `<node_id>.state` file format

Serialized via `:erlang.term_to_binary/2` with `[:deterministic]`:

```elixir
%{
  format_version: 1,
  node_id: binary,
  written_at: integer,                     # unix milliseconds
  aging_epoch: non_neg_integer,
  increments_since_reset: non_neg_integer,
  sketch: binary,                          # CMS counters
  doorkeeper: binary,                      # Bloom bits
  protected_hashes: [binary]               # cache key hashes, LRU → MRU order
}
```

`protected_hashes` is ordered LRU-to-MRU. Restoration is a **two-pass
boot** because the directory walk hits entries in partition order, not
protected order:

1. **Scan pass.** Walk the cache directory, read each `.meta`, and
   accumulate `Map.new(key_hash → descriptor)` (with `size_bytes`,
   `body_sha256`, `cost_us`, and `mtime`). No queue insertions yet.
2. **Insert pass.** Iterate `protected_hashes` LRU-first; for each
   hash, look up in the map. If present, insert at protected MRU
   (resulting order matches the persisted LRU→MRU sequence). If absent
   — entry deleted between writes — skip silently. Then iterate
   remaining map entries (those not in `protected_hashes`), sort by
   `mtime`, and insert each at probationary MRU.

Window starts empty regardless.

### Lookup flow (cache hit path)

1. `ImagePipe.Cache.lookup/4` → adapter `get(key, opts)` (unchanged
   signature).
2. Adapter reads meta + body as today.
3. On a successful hit, adapter `cast`s `{:hit, key_hash}` to `Admission`.
   Fire-and-forget; the hit path never blocks on admission state.
4. `Admission` applies the doorkeeper-gated CMS increment (first
   hit-sighting → doorkeeper; subsequent → CMS), then moves the entry to
   its queue's MRU position. If the entry isn't tracked yet (cold boot
   before scan completes), `Admission` synthesizes a probationary entry
   at MRU using the descriptor information the adapter cast along with
   the hash.

### Sink commit flow (cache write path)

1. `Sink.commit/2` → adapter `commit_sink(state, opts)`.
2. Adapter writes body+meta temp files as today.
3. **Before** the body/meta renames, adapter `call`s
   `Admission.admit(descriptor)` where `descriptor` includes `key_hash`,
   `size_bytes`, `body_sha256`, and `cost_us`. Synchronous, fast
   (in-memory). See the Admission flow section for the full window-step
   + main-gate logic.
4. `Admission` updates its queue state speculatively and returns either
   `{:admit, victims}` or `{:reject, reason}`.
5. If `{:reject, reason}` → adapter cleans temp files, emits the
   `cache: :admission_rejected` stage event with `reason:`, returns `:ok`
   to the sink (fail-open).
6. If `{:admit, victims}` → adapter performs the body+meta renames, then
   for each victim descriptor `%{key_hash, body_sha256, ...}`:
   - Computes the body path as `<paths.dir>/<key_hash>.<body_sha256>.body`
     and `File.rm/1`s it.
   - Computes the meta path via the existing `paths/2` helper and
     `File.rm/1`s it.
   Both deletes are ENOENT-tolerant. Errors other than `:enoent` are
   logged at warning. `Admission`'s in-memory accounting already
   considers those bytes freed, so any orphan body bytes are accepted as
   a known V1 limitation (see Deferred Behaviors and the Soft cap and
   reconciliation subsection).

In the normal window-first path the candidate is always admitted (its
files always rename into place); victims are old entries already on disk
that must be removed. The `{:reject, ...}` path only fires when the
candidate skipped the window (oversized) and lost its direct main-gate
run, or when it exceeded the hard cap.

### Boot / warm-start flow

1. `Admission.init/1` reads `<state_dir>/<node_id>.state` (own file) if
   present; restores `local_cms`, doorkeeper, aging epoch, and protected
   segment.
2. Reads all other `<state_dir>/*.state` files with `now - mtime <
   :state_ttl`. Decodes each. Element-wise sums them into `boot_cms`
   (read-only, never republished). Files past TTL are skipped. Decode
   failures are logged and skipped.
3. Concurrently, a background `Task` runs the **two-pass scan** described
   in the `<node_id>.state` file format section: first pass walks the
   directory and builds a `key_hash → descriptor` map; second pass
   sends the descriptor batches to `Admission` via `call` for the
   insert pass. The scan task never writes to `Admission`'s ETS tables
   directly — `Admission` owns its tables and applies the batches in
   the main process, keeping ownership rules clean. Window starts empty.
   For large caches this scan can take seconds; the adapter remains
   responsive throughout (see step 4).
4. While the scan is in flight, the adapter still serves reads and
   writes. Hits on un-scanned entries synthesize a probationary entry
   on the fly. Writes during scan may briefly over-admit; tolerated.

**Scan conflict resolution.** Runtime traffic during the scan can
populate queue state via hits (synthesized probationary entries) and
writes (admit calls) before the scan reaches those keys. When the scan
later tries to insert a descriptor for an already-tracked key,
`Admission` **skips the insert** — the runtime descriptor is fresher
than what the scan read from disk. This prevents stale-data resurrection
when a write happened concurrently with the directory walk.

`Admission` keeps two CMS sources:

- `local_cms` — incremented on local sightings via the doorkeeper gate
  (both hits via `get/2` and misses-through-commit via `commit_sink`).
  The canonical thing this node persists. Ages on schedule.
- `boot_cms` — loaded once at startup from peer files. Read-only, never
  republished. Ages on the same schedule as `local_cms` (gradually fades
  as new traffic dominates). The separation avoids the "new node claims
  merged history as its own contribution" double-counting problem when
  the local file is written.

Scoring reads `freq(key) = local_cms.estimate(key) + boot_cms.estimate(key)`
— each sketch is queried independently (each returns the min over its
own hash rows) and the two estimates are summed. The two sketches are
not counter-wise merged into a third matrix; that would require keeping
a merged matrix in sync and would behave differently under collisions.

### Periodic background work

- Persist local state to `<state_dir>/<node_id>.state` every
  `:flush_interval` seconds (default 30). Debounced — only writes when
  **state is dirty**, where "dirty" means any of: CMS counters changed,
  doorkeeper bits added, protected-segment membership or LRU order
  changed, or aging epoch incremented. Hit promotions and demotions
  set the dirty flag even when CMS doesn't increment (first-sighting
  case where doorkeeper absorbs the increment). Atomic rename pattern.
- Run TTL cleanup every `:cleanup_interval` seconds (default 3600 = 1h).
  List `<state_dir>/*.state`, `File.rm/1` files with mtime older than
  `:state_ttl` (default 604_800 = 7 days). Skip own file. ENOENT-tolerant.
- Aging fires on increment count, not on a timer; no scheduled event.

## Configuration

Extends the existing `ImagePipe.Cache.FileSystem` options. Presence of
`:max_size_bytes` activates bounded mode; absence keeps current unbounded
behavior.

**New required options when `:max_size_bytes` is set:**

- `:max_size_bytes` — positive integer (must be `> 0`). The soft cap.
  `0` and negative values are rejected at validation. There's no
  hard-coded minimum above zero — small caps work and are useful for
  tests, but the math becomes unrealistic below a few hundred KB
  (window budget rounds to bytes, protected target rounds to tiny
  fractions of entries). For production, several MB is the practical
  floor for the cache to be useful.

  **Budget math under tiny caps:** all budget computations clamp
  available bytes to `max(0, ...)` to avoid negative values from
  flowing into queue checks (a single protected entry larger than the
  20% target can produce a negative `probationary_budget` under the
  formula otherwise). Division operations in score and budget
  calculations never divide by zero; sizes use `max(size_bytes, 1)`
  and budgets use `max(budget, 0)` defensively.
- `:node_id` — binary string. Identifies this node's state files. No
  default; operator-controlled. **Must be stable across restarts of the
  same logical node** — a fresh `node_id` on every boot causes cold-start
  CMS every time. In k8s, use the StatefulSet ordinal pattern (e.g.
  `image-pipe-0`), not the pod name (which has a random suffix).

**New optional options (with defaults):**

| Key | Default | Notes |
|---|---|---|
| `:window_ratio` | `0.01` | Window as fraction of `:max_size_bytes`. `0` disables the window (escape hatch for operators with measured-steady workloads who want the 1% capacity back). Default-on because for an unknown workload, the window's bounded worst case beats windowless's unbounded recompute-storm worst case under bursts. |
| `:sketch_depth` | `4` | CMS hash rows |
| `:sketch_width` | `max(4096, :max_size_bytes ÷ 25_000)` | CMS counters per row. Derived default assumes ~50 KB average entry; override if your workload differs significantly. |
| `:doorkeeper_bits` | `max(8192, :max_size_bytes ÷ 12_500)` | Doorkeeper Bloom filter bit count. Same assumption. |
| `:flush_interval` | `30` | Seconds. State file write cadence |
| `:cleanup_interval` | `3600` | Seconds. Peer state file cleanup cadence |
| `:state_ttl` | `604_800` | Seconds (7 days). Peer files older than this are ignored at warm-start and deleted by cleanup |
| `:state_dir` | `<root>/.cache_state` | Where state files live |

Existing options (`:root`, `:path_prefix`, `:max_body_bytes`,
`:key_headers`, `:key_cookies`) unchanged.

**Cross-validation.** Setting any bounded option (`:window_ratio`,
`:node_id`, etc.) without `:max_size_bytes` is rejected at validation time
with a clear error. NimbleOptions schema extension handles this with a
post-check.

**Supervision integration.** Host adds the adapter to their supervision
tree explicitly when bounded mode is configured:

```elixir
children = [
  {ImagePipe.Cache.FileSystem,
    root: "/var/cache/image_pipe",
    max_size_bytes: 10_000_000_000,
    node_id: "pod-a"},
  # ...
]
```

The supervisor starts `Registry` and the `Admission` GenServer (registered
under `{root, node_id}` so multiple bounded caches per host are supported).
**Lookup is lazy** — `ImagePipe.Plug.init/1` does not verify the
registered process at startup. Instead, the adapter performs
`Registry.lookup/2` at request time inside `commit_sink` and `get/2`. If
the process is absent (e.g., the host's supervision tree starts the
endpoint before the cache supervisor), the adapter logs a warning and
behaves as if the cache were disabled for that request — fail open. This
avoids spurious boot crashes from supervision-tree ordering and matches
the rest of the cache's fail-open posture.

Document the recommended pattern: place the cache adapter child spec
*before* the endpoint in the host's supervision tree, so it's started
first. Hosts that forget will see cache-disabled warnings in logs
rather than crashes.

Unbounded mode is unchanged — host doesn't need to add anything to their
supervision tree.

## Error Handling and Telemetry

### Failure modes

1. **Admission process not running when bounded config is set.** Adapter
   does a lazy `Registry.lookup/2` at request time. Absent process →
   logs a warning and treats the operation as cache-disabled for that
   request (`get/2` returns `:miss`; `commit_sink` skips admission and
   doesn't write). Fail open. Tolerates supervision-tree ordering issues
   that would otherwise crash boot.

2. **Admission process crash mid-request.** OTP supervisor restarts it;
   `init/1` re-reads warm-start files. In-flight `commit_sink` calls hit
   the restarted process and either succeed (admission completed before
   crash) or return as if rejected (`commit_sink` returns `:ok`, body tmp
   file cleaned).

3. **Warm-start file decode failure.** `:erlang.binary_to_term(_, [:safe])`
   may raise; caught, logged at warning, that file is skipped. Cold-boot
   proceeds if no other peer files are readable. Mirrors how
   `decode_metadata/1` handles invalid entry metadata today.

4. **State directory permissions / unwritable.** Periodic flush returns
   `{:error, reason}`; logged at warning, counted in telemetry, doesn't
   crash. Cache stays bounded based on in-memory state; warm-start data
   just stops being persisted.

5. **Eviction body/meta delete failure.** `File.rm/1` errors except
   `:enoent` are logged at warning and counted. Body files orphaned from
   their metadata become invisible to `get/2` but consume disk. Acceptable;
   a future orphan-sweep pass could reconcile, but not in this design.

6. **Concurrent commits exceeding cap.** Soft cap by design. Next admission
   call selects a larger victim batch to compensate.

### Telemetry events

Following the existing `:telemetry.span/3` shape and the codebase's
telemetry guidelines (low-cardinality, product-neutral, shared
`ImagePipe.Telemetry` helpers):

| Event | Type | Metadata |
|---|---|---|
| `[<prefix>, :cache, :admission, :start]` / `:stop` | span | `:decision` (`:admitted \| :rejected`), `:victims_count`, `:bytes_freed`, `:bytes_admitted`, `:reason` (when rejected) |
| `[<prefix>, :cache, :eviction, :stop]` | event | `:count`, `:bytes_freed`, `:errors_count` |
| `[<prefix>, :cache, :warm_start, :start]` / `:stop` | span | `:peer_files_read`, `:protected_hashes_loaded`, `:files_skipped` |
| `[<prefix>, :cache, :flush, :stop]` | event | `:result` (`:ok \| :error`), `:bytes_written`, `:error` (when failed) |
| `[<prefix>, :cache, :cleanup, :stop]` | event | `:files_removed`, `:errors_count` |
| `[<prefix>, :cache, :stage, ...]` (existing) | event | new `cache:` value: `:admission_rejected` |

All metadata is low-cardinality and product-neutral. No CMS contents in
telemetry. No `node_id` (operator-set, potentially sensitive). No file
paths. No cache keys. Reason codes use atoms like `:over_cap`,
`:score_too_low`, `:no_evictable_victims`.

CMS aging is *not* a telemetry event — it's a frequent internal mechanism
whose timing is uninteresting to operators.

## Testing Strategy

### Pure-module tests (no GenServer)

- `Sketch` — increment, conservative update, aging halving, serialization
  round-trip.
- `Policy` — `admit?/3` decisions across score combinations; victim
  selection over varied queue states; edge cases (empty queues,
  single-entry, candidate larger than cap).
- `Doorkeeper` — add/contains, false-positive rate under target across
  random key streams, reset clears state.

### Property tests (StreamData)

- CMS `estimate(k) >= true_count(k)` — never underestimates.
- Aging preserves relative ordering for high-frequency keys.
- Soft-cap invariant: after any admission sequence, total
  `Admission`-tracked bytes never exceed cap by more than the *sum* of
  in-flight admitted-but-not-yet-renamed-or-deleted entry sizes across
  all concurrent commits.
- File-write atomicity smoke test under concurrent writers.

### Admission GenServer tests (via `start_supervised!/1`)

- Boot from empty state, populated `<node_id>.state`, populated peer files,
  mix.
- Admission decisions serialize correctly under concurrent `call`s.
- Aging triggers at configured sample threshold.
- Protected-segment promotion on second hit; demotion on overflow.
- Crash-and-restart: warm-start reproduces prior state. Use
  `Process.monitor/1` + `assert_receive {:DOWN, ...}`, no `Process.sleep`.
- TTL cleanup removes files older than `:state_ttl` (drive by writing
  files with old mtimes via `File.touch!/2`).

### Adapter end-to-end tests (real `ImagePipe.call/2`)

- Bounded mode: cycle 1.5× cap worth of distinct entries, verify evicted
  body and meta files are gone from disk, surviving entries are the
  higher-scoring ones, total disk usage stays within soft-cap bounds.
- Unbounded mode (`:max_size_bytes` absent): no Admission process needed,
  existing behavior preserved, existing tests unchanged.
- Admission rejection per reason code: separate cases for `:over_cap`,
  `:score_too_low`, and `:no_evictable_victims`; verify body tmp file
  cleaned and response still streams to client for each.
- Cross-node warm-start: pre-place two `<node_id>.state` files in
  `<state_dir>`, boot Admission, assert merged frequency reflects both via
  `:sys.get_state/1` snapshot inspection.

### Failure and edge-case tests

- **Rename failure after admission**: stub `File.rename/2` to return
  `{:error, :enospc}` for a single commit; verify accounting drift is
  bounded, no crash, telemetry surfaces the failure, and the next
  successful commit doesn't compound the drift.
- **Meta present, body missing**: place a `.meta` file with no matching
  `.body`; `get/2` returns `:miss` and the orphaned meta is left in
  place (V1 doesn't sweep, by design).
- **Body present, meta missing**: place a `.body` with no matching
  `.meta`; `get/2` returns `:miss`. The orphan body is invisible.
- **Corrupt own `<node_id>.state`**: write a truncated/garbage file; boot
  logs a warning, falls back as if the file didn't exist, cold-boots
  CMS, scans disk normally.
- **Scan racing with commits for the same key**: drive a commit while the
  background scan is mid-traversal of the same partition; verify final
  queue state is consistent (one queue entry, correct size, no
  duplicates).
- **Duplicate commit for same key replacing an older body**: write entry
  K with body B1, then re-write K with body B2 (different `body_sha256`,
  possibly different size). Queue tracks the new descriptor; old body
  file is deleted; admission accounting reflects the size delta.
- **Same key hash with different size/cost/body_sha256**: verify the
  queue entry is replaced (not duplicated), size accounting adjusts, and
  cost ranking uses the new `cost_us`.
- **Restart after failed victim delete**: simulate a victim delete that
  fails with `:eacces`; restart Admission; verify boot scan picks up the
  orphan body (or skips it) without crashing or double-counting bytes.
- **Invalid `:max_size_bytes`**: `:max_size_bytes: 0` and negative
  values should be rejected at validation. Assert the rejection happens
  (specific error tuple or exception type) — not the exact error
  string, per "Tests deliberately not written" below.
- **Tiny but legal caps**: `:max_size_bytes: 1024` should be accepted
  (legal positive integer); verify the math doesn't crash, budgets are
  computed without negatives or division-by-zero, and at least the hard
  reject path works as expected.

### Architecture tests

Extend `test/image_pipe/architecture_boundary_test.exs`:

- All new modules under `ImagePipe.Cache.FileSystem.*`.
- No new top-level namespace.
- Existing boundary deps satisfied.

### Tests deliberately not written

Per project test guidelines:

- No hand-built `%Sketch{}` or `%Admission.State{}` values to test
  rejection of impossible internal misuse.
- No `function_exported?/3` or module-existence assertions.
- No tests pinning private validation error strings or bang-vs-non-bang
  choices.
- No characterization tests of the old unbounded adapter (greenfield,
  nothing to pin).

## Deferred Behaviors

V1 deliberately excludes:

- **Live cross-node gossip.** No `StateSync` behaviour, no `:pg` transport,
  no live broadcasts. Frequency convergence between live peers happens
  only through file-based warm-start across restarts.
- **Cross-node CMS sharing in steady state.** If load balancing is sticky
  enough that some nodes never see keys other nodes consider hot, those
  nodes' admission decisions stay narrow. Add live gossip later if real
  workloads show admission churn.
- **Value-level cache sharing through the network.** Bodies share through
  the filesystem when the filesystem is shared (the existing
  deterministic-path behavior). Without a shared filesystem, each node has
  a private body cache.
- **Sharded ownership / consistent-hash routing.** Each node bounded
  independently; no key-to-node ownership scheme.
- **Orphan body file sweep.** If eviction deletes metadata but fails to
  delete the body, the body lingers on disk. Acceptable failure mode for
  V1.

## Implementation Plan

Single plan covering the whole design. Estimated 750–1000 LOC including
tests.

1. `Sketch` pure module + serialization round-trip + property tests.
2. `Doorkeeper` pure module + reset behavior tests.
3. `Policy` pure module + admission and victim-selection tests.
4. `Entry.Metadata` `cost_us` field; thread the running sum of
   source-fetch, transform-execute, and encode stage durations into the
   sink so it's available when `commit_sink` runs.
5. `Admission` GenServer:
   - Boot warm-start: read own + peer state files, build `local_cms`
     and `boot_cms`.
   - Background two-pass directory scan: build `key_hash → descriptor`
     map, then insert protected entries in LRU→MRU order and remaining
     entries into probationary by mtime. Window starts empty.
   - `admit/1` synchronous call with window-step + main-gate logic;
     `hit/2` cast; aging on increment count.
   - Periodic state file flush; periodic TTL cleanup.
6. `FileSystem` adapter integration:
   - `child_spec/1` returning a supervisor when `:max_size_bytes` is set.
   - Registry naming under `{root, node_id}`.
   - Lazy `Registry.lookup/2` at request time; absent process → log
     warning + behave as cache-disabled (fail open).
   - `commit_sink` calls `Admission.admit/1` before rename; on
     `{:reject, reason}` cleans tmp files and emits stage event; on
     `{:admit, victims}` renames tmp files and deletes each victim's
     body + meta paths (ENOENT-tolerant).
   - `get/2` casts hit to Admission on success.
7. Config schema extension with NimbleOptions:
   - New options with derived defaults (`:sketch_width`,
     `:doorkeeper_bits` from `:max_size_bytes`).
   - Cross-validation: bounded options without `:max_size_bytes`
     rejected; `:max_size_bytes` must be a positive integer (0 and
     negatives rejected).
8. New telemetry events through `ImagePipe.Telemetry` helpers.
9. Tests:
   - All pure-module + property tests.
   - Admission GenServer integration tests (incl. window lifecycle and
     same-key re-commit replacement).
   - Adapter end-to-end tests (bounded + unbounded modes, rejection
     reasons, cross-node warm-start, window-evictee main-gate cascade).
   - Failure / edge-case tests (rename failure, partial corruption,
     scan races, restart-after-failed-delete, tiny legal caps and
     invalid non-positive caps).
   - Architecture boundary tests.
10. Documentation update in `docs/cache.md`: bounded-mode configuration,
    `:node_id` stability requirement, rolling-deploy / multi-node
    behavior, soft-cap semantics, supervision-tree ordering note,
    telemetry additions.
