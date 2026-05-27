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
  per-node state file (`<node_id>.cms`) for warm-start.
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
  `commit_sink` (synchronous admission decision returning victim hashes;
  adapter then deletes victim files itself).

`ImagePipe.Plug.init/1` verifies the registered `Admission` process exists
when `:max_size_bytes` is set. Missing process raises at init; never accepts
traffic into a misconfigured bounded cache.

## Admission and Eviction Algorithm

### Count-Min Sketch

4 hash rows × 4096 counters × 8-bit, ~16 KB per node. Hash positions come
from `:erlang.phash2/2` with four different salts. Conservative update
(increment only the minimum hash positions per key) for better accuracy.

Configurable via `:sketch_depth` (default 4) and `:sketch_width` (default
4096).

### Doorkeeper

Bloom filter sized proportionally to `:sketch_width`. Sits in front of CMS:

- First sighting of a key → add to doorkeeper, don't touch CMS.
- Subsequent sighting (key in doorkeeper) → increment CMS.

Doorkeeper resets on the same schedule as CMS aging. The point is to keep
one-hit wonders out of the CMS so counter capacity goes to actually
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

- **Window LRU** — `:window_ratio × :max_size_bytes` (default 1%). Holds
  freshly admitted entries that haven't yet earned a place in main. When
  window exceeds its budget, the LRU entry is evicted from the window and
  becomes a *candidate* for main.
- **Probationary SLRU** — 80% of (`:max_size_bytes` − window).
- **Protected SLRU** — 20% of (`:max_size_bytes` − window). Promotion from
  probationary on second hit. Protected overflow demotes its LRU back to
  probationary.

Each queue is an `:ets.new(:ordered_set, ...)` table keyed by integer
position + entry hash. `Admission` owns the tables exclusively (no
concurrent access). ETS is used for ordered iteration during victim
selection, not for shared access.

### Cost-aware scoring

```
score(entry) = frequency(key) × max(cost_us, 1) / max(size_bytes, 1)
```

`cost_us` is the sum of source-fetch, transform-execute, and encode
wall-clock durations from the miss that produced the entry. These stage
durations are all available before `commit_sink` runs; the request-level
`[..., :request, :stop]` span hasn't fired yet at commit time, so the
sum-of-stages is what we have. It captures the work the cache actually
avoids on a hit — send time, which the cache also avoids, is small enough
relative to fetch+transform+encode to ignore as a scoring signal.

### Admission flow on a new candidate `C` (window evictee)

1. If main has room → admit `C` to probationary MRU.
2. Else pick probationary LRU victim `V`. If `score(C) > score(V)` → evict
   `V`, admit `C`. Else → reject `C`.

When a `commit_sink` lands an entry larger than current free space, victims
are selected in a single batch (probationary LRU outward) until enough
bytes are freed *or* total candidate score exceeds entry score. If the
entry is too large or too low-scoring to admit, commit returns successfully
but emits a `cache: :admission_rejected` stage telemetry event and the
body file is not committed (tmp file is cleaned). Same fail-open shape as
`:max_body_bytes` today.

### Hit promotion

- Hit on probationary → move to protected MRU. If protected overflows by
  bytes, demote protected LRU to probationary.
- Hit on protected → move to protected MRU.
- Hit on window → move to window MRU.

### Soft cap semantics

Concurrent commits may both pass admission and both write, briefly
exceeding the cap. The next admission call sees the new total and selects a
larger victim batch to compensate. Overshoots are bounded by the largest
in-flight entry size; telemetry captures overshoot magnitude.

## Data Flow and On-Disk Layout

### On-disk layout

```
<root>/<path_prefix>/                      # existing partitioned cache entries
  ab/cd/<hash>.meta                        # existing, fields added
  ab/cd/<hash>.<body_sha256>.body          # existing, unchanged

<root>/.cache_state/                       # new — coordination state, not entries
  <node_id>.cms                            # per-node CMS + doorkeeper + protected-segment IDs
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

### `<node_id>.cms` file format

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
  protected_hashes: [binary]               # cache key hashes in the protected segment
}
```

### Lookup flow (cache hit path)

1. `ImagePipe.Cache.lookup/4` → adapter `get(key, opts)` (unchanged
   signature).
2. Adapter reads meta + body as today.
3. On a successful hit, adapter `cast`s `{:hit, key_hash}` to `Admission`.
   Fire-and-forget; the hit path never blocks on admission state.
4. `Admission` increments CMS via doorkeeper gate, moves the entry to its
   queue's MRU position, or — if the entry isn't tracked yet (cold boot
   before scan completes) — adds it to probationary at MRU.

### Sink commit flow (cache write path)

1. `Sink.commit/2` → adapter `commit_sink(state, opts)`.
2. Adapter writes body+meta temp files as today.
3. **Before** the body/meta renames, adapter `call`s
   `Admission.admit(entry_meta)`. Synchronous, fast (in-memory).
4. `Admission` updates its queue state speculatively and returns either
   `{:ok, victim_hashes}` (list of cache key hashes whose files the
   adapter should delete) or `:reject`.
5. If `:reject` → adapter cleans temp files, emits the
   `cache: :admission_rejected` stage event, returns `:ok` to the sink
   (fail-open).
6. If `{:ok, victim_hashes}` → adapter performs the body+meta renames,
   then for each victim hash computes its meta and body paths via the
   existing `paths/2` helper and `File.rm/1`s them (best-effort,
   ENOENT-tolerant). Errors other than `:enoent` are logged at warning;
   `Admission`'s in-memory accounting already considers those bytes freed,
   so any orphan body bytes are accepted as a known V1 limitation (see
   Deferred Behaviors).

### Boot / warm-start flow

1. `Admission.init/1` reads `<state_dir>/<node_id>.cms` (own file) if
   present; restores `local_cms`, doorkeeper, aging epoch, and protected
   segment.
2. Reads all other `<state_dir>/*.cms` files with `now - mtime <
   :state_ttl`. Decodes each. Element-wise sums them into `boot_cms`
   (read-only, never republished). Files past TTL are skipped. Decode
   failures are logged and skipped.
3. Concurrently, a background `Task` walks the cache directory and reads
   each `.meta` file, building the initial queue state. Entries whose
   cache key hash appears in the loaded `protected_hashes` list go
   directly into protected MRU; others go to probationary in mtime order.
   For large caches this scan can take seconds; the adapter remains
   responsive throughout (see step 4).
4. While the scan is in flight, the adapter still serves reads and writes.
   Hits on un-scanned entries synthesize a probationary entry on the fly.
   Writes during scan may briefly over-admit; tolerated.

`Admission` keeps two CMS sources:

- `local_cms` — incremented on local hits, the canonical thing this node
  persists. Ages on schedule.
- `boot_cms` — loaded once at startup from peer files. Read-only, never
  republished. Ages on the same schedule as `local_cms` (gradually fades
  as new traffic dominates). The separation avoids the "new node claims
  merged history as its own contribution" double-counting problem when
  the local file is written.

Scoring reads `freq(key) = local_cms ⊕ boot_cms`.

### Periodic background work

- Persist local state to `<state_dir>/<node_id>.cms` every `:flush_interval`
  seconds (default 30). Debounced — only writes when CMS is dirty.
  Atomic rename pattern.
- Run TTL cleanup every `:cleanup_interval` seconds (default 3600 = 1h).
  List `<state_dir>/*.cms`, `File.rm/1` files with mtime older than
  `:state_ttl` (default 604_800 = 7 days). Skip own file. ENOENT-tolerant.
- Aging fires on increment count, not on a timer; no scheduled event.

## Configuration

Extends the existing `ImagePipe.Cache.FileSystem` options. Presence of
`:max_size_bytes` activates bounded mode; absence keeps current unbounded
behavior.

**New required options when `:max_size_bytes` is set:**

- `:max_size_bytes` — non-negative integer. The soft cap.
- `:node_id` — binary string. Identifies this node's state files. No
  default; operator-controlled.

**New optional options (with defaults):**

| Key | Default | Notes |
|---|---|---|
| `:window_ratio` | `0.01` | Window LRU as fraction of `:max_size_bytes` |
| `:sketch_depth` | `4` | CMS hash rows |
| `:sketch_width` | `4096` | CMS counters per row |
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
`ImagePipe.Plug.init/1` calls a new `ImagePipe.Cache.lookup_adapter_pid/1`
helper to verify the registered process exists when `:max_size_bytes` is
set.

Unbounded mode is unchanged — host doesn't need to add anything to their
supervision tree.

## Error Handling and Telemetry

### Failure modes

1. **Admission process not running when bounded config is set.** Plug init
   verifies the registered process via `Registry.lookup`. If absent, raise
   `ArgumentError`. Same posture as missing source modules today — fail
   loud at boot, never accept traffic into a misconfigured cache.

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
- Soft-cap invariant: after any admission sequence, total tracked bytes
  never exceed cap by more than the largest in-flight entry.
- File-write atomicity smoke test under concurrent writers.

### Admission GenServer tests (via `start_supervised!/1`)

- Boot from empty state, populated `<node_id>.cms`, populated peer files,
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
- Admission rejection: write an entry too large or too low-scoring, verify
  `:cache, :stage, ...` event with `cache: :admission_rejected`, body tmp
  file cleaned, response still streams to client.
- Cross-node warm-start: pre-place two `<node_id>.cms` files in
  `<state_dir>`, boot Admission, assert merged frequency reflects both via
  `:sys.get_state/1` snapshot inspection.

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
   - Boot warm-start (own file + peer files + protected segment).
   - Background directory scan.
   - `admit/1` synchronous call; `hit/2` cast; `evict/1` cast.
   - Aging on increment count.
   - Periodic state file flush.
   - Periodic TTL cleanup.
6. `FileSystem` adapter integration:
   - `child_spec/1` returning a supervisor when `:max_size_bytes` is set.
   - Registry naming.
   - Adapter `commit_sink` calls `Admission.admit/1` before rename; on
     `:reject`, cleans tmp files and emits stage event.
   - Adapter `get/2` casts hit to Admission on success.
   - Eviction handler deletes body + meta files.
7. Config schema extension with NimbleOptions; cross-validation for the
   `:max_size_bytes`-required keys.
8. New telemetry events through `ImagePipe.Telemetry` helpers.
9. `ImagePipe.Plug.init/1` registers/verifies the Admission process when
   bounded mode is configured.
10. Tests:
    - All pure-module + property tests.
    - Admission GenServer integration tests.
    - Adapter end-to-end tests (bounded + unbounded modes, rejection
      behavior, cross-node warm-start).
    - Architecture boundary tests.
11. Documentation update in `docs/cache.md`: bounded-mode configuration,
    rolling-deploy / multi-node behavior, soft-cap semantics, telemetry
    additions.
