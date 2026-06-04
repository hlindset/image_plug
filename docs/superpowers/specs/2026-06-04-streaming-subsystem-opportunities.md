# Request-time streaming subsystem — re-architecture opportunities memo

**Date:** 2026-06-04
**Status:** Exploration / proposal. No implementation. Ranked opportunities for the maintainer to pick from.
**Scope:** The request-time encode-streaming path — `ImagePipe.Request.SourceSession`, its `Producer`, `Runner`, `Response.Sender`/`PreparedStream`, and the `Source.WrappedStream` source-body path.

This memo deliberately does **not** re-propose the honest-surface cleanups already landed in #158
(test-only Producer client relocated, `StreamError`→tag translation collapsed per module, `:busy`
guard deleted). It revisits the items #158 declined, plus new findings from a fresh read.

---

## Two findings that reframe the subsystem

### Finding 1 — The source is fully buffered before decode; `WrappedStream`'s suspend/resume half is dead

`WrappedStream` wraps the HTTP source enumerable (`source.ex:109`), but its only consumer is
`Processor.seekable_input/1`, which does `Enum.to_list()` → `IO.iodata_to_binary()`
(`processor.ex:184`). `Enum.to_list` drives with `{:cont, …}` and **never suspends**, so the entire
suspend/resume + `continue_safely` + `consumer_failure_ref` machinery (`wrapped_stream.ex:158-202`)
has no live caller. The only job that runs is: count bytes, enforce `max_body_bytes`, raise
`StreamError`. That is a `Stream.transform`, not a 140-line hand-rolled `Enumerable`.

There is **no roadmap reason** to keep the dead half: shrink-on-load (#28) is fully merged
(#142 + #144) and consumes the source via `new_from_buffer`/`new_from_file` — seekable, not
incremental. Concurrent download+decode (#139) is **closed**, and even its design keeps libvips I/O
in C against a temp file / growing file; it would never resume a suspended Elixir source
continuation.

### Finding 2 — The "process affinity" justification was a myth; the property actually worth protecting is prompt cancellation, which is real

The prior plan justified the two-process `SourceSession`+`Producer` split partly with "the libvips
streaming target has process affinity, hence the `$callers` plumbing." A spike (below) **falsified**
this. The `$callers` plumbing is stdlib Task ownership (the code comment at `source_session.ex:83`
says so), not a Vix affinity mechanism.

What the split *does* legitimately buy — prompt kill of an in-progress expensive encode when the
client disconnects — is **real, and the spike confirmed it works even for non-streamable AVIF**.

---

## The de-risking spike (run 2026-06-04, throwaway)

Four sub-questions, exercising the real `Image.stream!` encode path:

| Sub-question | Result |
|---|---|
| (a) Does a suspended encode continuation resume from a *different, unlinked* process? | **Yes — byte-identical** (4,742,486 B same-process vs cross-process), decodes `fail_on: :error`. Affinity falsified. |
| (b) Does it still work after the *creator* process dies? | **No — `{:noproc}`.** The `Vix.TargetPipe` is linked to its creator. The real constraint is OTP link topology: the owner must outlive the stream. |
| (c) Killing the owner mid-encode — how fast does the encode writer task die? | **~0 ms for both `.jpg` and `.avif`.** |
| (d) Does the kill actually *free the CPU*, or does the dirty NIF thread detach and keep burning? | **CPU genuinely freed.** Fresh AVIF encodes immediately after a mid-flight kill averaged 9,280 ms vs a clean baseline of 9,480 ms — identical within noise. The dirty encode NIF aborts; it does not detach. |

**Conclusion:** The two-process core is **vindicated by cancellation, not by affinity.** A killable
process must own the demand-driven continuation, and `SourceSession` must stay responsive to
owner-DOWN *during* a chunk pull so it can issue the kill. The affinity comment is wrong and should
be corrected to cite the real reasons (link topology + cancellation), ideally referencing a
preserved version of spike (a)/(b) as a regression test.

---

## Ranked opportunities (post-spike)

### #3 — `WrappedStream` → `Stream.transform` *(recommended first)*
- **What:** Replace the hand-rolled `Enumerable` impl with a byte-counting `Stream.transform` that
  raises `StreamError` on `max_body_bytes` / non-binary chunks. Likely also collapse the atomics
  error channel, which appears redundant with the already-caught raised `StreamError`
  (`processor.ex:186`).
- **Why simpler:** ~−80 lines; removes a custom `Enumerable` (and its consumer-vs-producer
  failure separation, which only matters for a *suspending* consumer that can fail — there is none).
- **Behavior preserved:** `{:source, :body_too_large}` → 422 wire contract; the `StreamError`
  reason surfacing at `processor.ex:186`.
- **Risk:** Low-medium. Gone is the only real risk (roadmap collision — see Finding 1).
- **Pre-req:** A ~10-minute consumer audit confirming no production caller suspends the wrapped
  stream. **Effort:** Medium.

### #5 — Fold the parent-EXIT trap into the supervisor link *(recommended second)*
- **What:** In the real path `parent == the supervisor pid` (`start_session` deletes `:parent`;
  `start_link` defaults `parent` to `self()`, which under `DynamicSupervisor.start_child` is the
  supervisor). The `{:EXIT, parent, reason}` trap (`source_session.ex:179-187`) and the supervisor
  link are the same relationship expressed twice. Of the "three liveness mechanisms," only two are
  distinct: supervisor-link (orderly shutdown) and owner-monitor (request-process disconnect).
- **Why simpler:** Removes a field and a clause; the liveness model reads as two relationships.
- **Risk:** Low-medium — tests pin the "parent-shutdown reason ≠ owner-down reason" distinction; the
  fold must preserve `:shutdown` vs `{:shutdown, {:owner_down, _}}`. **Effort:** Small.

### #2 — Producer rearchitecture *(re-scoped DOWN by the spike)*
- **Original idea:** collapse the two-process split. The spike **vindicated the core**: a
  killable, demand-driven encode-owner process is genuinely needed for prompt cancellation, and
  `SourceSession` can't `GenServer.call` it (that would block its mailbox during the pull), so the
  async `{ref, result}` + monitor shape is intrinsic — the current bare-`spawn_link` + `make_ref`
  loop is already close to minimal.
- **Actionable remainder (low payoff):**
  1. **Correct the load-bearing-but-wrong affinity comment** in the plan/code; cite link topology +
     cancellation; optionally preserve spike (a)/(b) as a deterministic regression test that finally
     *justifies* the design with evidence. (Cheap, high doc-honesty value.)
  2. Optionally revisit the #158-deferred `producer_request_ref` / `terminate/2` double-cleanup nits
     with the focused state-machine analysis they require — but these are marginal.
- **Risk:** The rearchitecture is not worth it; the comment fix is ~zero risk. **Effort:** Small (comment) / not recommended (rearchitecture).

### #4 — Buffered-vs-streamed split by format streamability *(DECLINED)*
- **Premise falsified by the spike.** It assumed AVIF/WebP can't be cancelled mid-encode, so
  streaming buys nothing for them. (c)/(d) show AVIF cancellation is prompt *and* frees the CPU.
  Buffering AVIF would lose the ability to abort a ~8 s encode on disconnect — a real DoS
  regression. The current "first chunk = whole encode, but abortable" behavior is correct. **Leave it.**

### Minor / parked
- **#6 Elide the `Prepared` DTO:** `prepare/1` could return its 4 fields directly and let `Runner`
  build `PreparedStream` in one step, deleting one intra-`Request`-boundary struct without crossing
  the `Request`/`Response` boundary that (correctly) blocks a full merge. Low payoff, low risk.
- **#7 `{:protocol,_}` 500 hole:** `Response.Sender` has no `{:protocol,_}` clause, but the tags are
  unreachable for the single sequential caller, so adding a defensive clause would *violate* the
  "no guards for impossible internal misuse" rule. The disciplined move is to narrow the taxonomy
  (are `:invalid_phase`/`:not_prepared` also impossible-misuse, like the removed `:busy`?), engaging
  #158's explicit decision to keep them. Low payoff.
- **#8 #158 deferrals** (`producer_request_ref`, `terminate/2` double-cleanup, cache-sink locale):
  parked; several are subsumed by the (now not-recommended) #2.

---

## Recommended sequencing

1. **#3** — the biggest honest simplification, now unblocked; do the consumer audit, then the
   `Stream.transform` rewrite.
2. **#5** — small, clean liveness-model sharpening.
3. **#2 comment fix** — correct the affinity myth and, ideally, land spike (a)/(b) as the regression
   test that finally justifies the two-process core with evidence. Skip the rearchitecture.
4. **#4** — declined; record the spike as the rationale.

Per repo policy, any of these that becomes an implementation plan must go through a parallel
disjoint-reviewer cycle before implementation, with at least one reviewer on observable imgproxy
compatibility against real upstream (e.g. `local/imgproxy-master`).

---

## Spike methodology (for reproduction / regression)

The spike built `Image.stream!(image, suffix: …, buffer_size: 0)` continuations via
`Enumerable.reduce(stream, {:cont, nil}, fn c, _ -> {:suspend, c} end)`. (a) shipped a suspended
continuation to an unlinked `spawn` and compared the reassembled body to a same-process baseline.
(b) created the continuation in a separate process, killed it, and observed `{:noproc}` on resume.
(c) located the `Vix.TargetPipe` writer task via the owner's links + `:sys.get_state(pipe).task_pid`,
killed the owner mid-encode, and timed the writer's `:DOWN`. (d) timed three fresh AVIF encodes
immediately after a mid-flight kill against a clean three-encode baseline. Test images were a real
photo (`priv/static/images/beach.jpg`) upscaled 4× for entropy.
