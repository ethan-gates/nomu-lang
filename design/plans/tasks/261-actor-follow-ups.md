# Actor follow-ups — shareable message arguments, and the send path's cost

**Avenue:** Risk (correctness, perf) · **Type/Lifecycle:** `sema · runtime · actors` · **Size:** M ·
**Status:** done (261.1–261.5) ·
**Source:** found while checking the removal of the value-type rule ([260](260-enum-layout.md).1): a
mutable class object can be sent to an actor handler.

## Today

- **Message arguments are checked for shareability (261.1).** `concurrency.md` names an actor message as a
  task boundary, where a value must be shareable (a class only when deeply immutable). The send checks each
  argument's type, as `task` and `fiber` do: `wk.take(b: Box(v: 1))` with `class Box { var v: Int }` is
  "type 'Box' is not shareable, so it cannot be passed to actor handler 'take'". Before, it compiled, and
  the sender and the actor shared a mutable object across fibers. Construction is checked the same way, since an
  actor's fields are its handlers' state: `Sink(box: b)` is "type 'Box' is not shareable, so it cannot be
  passed to actor 'Sink'". `Array` is a reference type, so an array cannot go to an actor either; an actor
  that needs one builds it.
- **A send takes a slot from the message pool (261.4).** Each handler call fills a message `{ header, next,
  thunk, self, args… }` in a raw pool slot (`runtime/msgpool.nomu`, `llvmgen/LLVMGenActor.swift`), enqueues
  it on the receiver's mailbox, and a pooled mailbox fiber drains it, calling each message's per-handler
  thunk indirectly; the thunk frees the slot once it has read it. Collections scan queued messages as roots.
- **[106](106-actor-fiber-aware-mutex.md) is closed (261.2).** Actors hold no mutex: a mailbox's
  `scheduled` flag lets one mailbox fiber drain it at a time, and a handler that parks parks that fiber.

## Work

- **261.1** Check actor message arguments for shareability, as `task` arguments are, with the same
  diagnostic. Cases: a mutable class argument is an error; a struct holding one is an error; a deeply
  immutable class, an actor handle and plain values are accepted. Done: the check is at the actor send in
  `NOIRGen` (one site, every handler call); suite cases `actor-not-shareable`,
  `actor-not-shareable-struct`, `actor-shareable-args`. Two fixtures sent a `Box` with a `var` field it
  never wrote (`gc_actor_small_args`, `gc_dense_fields`); the field is `let` now. Construction checked too (case
  `actor-construct-not-shareable`). An actor field's default is now checked against the field's type, so
  `var xs: Array<Worker> = []` compiles (it was "cannot infer the element type of an empty array literal").
  `benchmarks/pipeline_actor` and `benchmarks/fanout_actor` sent their actors' array in every message; the
  pipeline's stages now hold their successor (`Option<Stage>`), and the fan-out's hub builds and keeps its
  workers. Messages stay the same size or lose a word, and the pipeline's time is unchanged (303 ns an item
  old, 309 new, both built without the check).
- **261.2** Confirm 106 is obsolete (the mailbox model replaced the mutex) and close it, or record what
  remains. Done: obsolete, closed.
- **261.3** Measure the send path against Go channels and goroutines: the message allocation per send,
  the indirect thunk call, and the mailbox's enqueue and drain. Candidates once measured: messages
  allocated fiber-locally or pooled when they do not outlive the drain, and a direct call for a handler
  known at the send site. Done; see Results.
- **261.4** Messages from a runtime pool, scanned as roots (the design below). Re-measure
  `pipeline_actor`, `fanout_actor` and `pingpong_actor` against Go at 1–8 carriers.
  - **261.4.1** Design: options and decision below. Done.
  - **261.4.2** Runtime: the pool (size classes, per-carrier free lists, the global pool, large messages),
    the slab walk adding message fields to the root slots, the free-list rebuild and slab release under
    stop-the-world; the mailbox queue on raw links with no remember calls. Done; minors scan only the
    young lists (below), added after 261.4.5's first backlog measurement.
  - **261.4.3** Codegen: the send allocates from the pool and stores without barriers; the thunk reads a
    raw message, frees it, then calls the handler; the drain loop and `nomuSchedMailboxPop` carry a raw
    message; the mailbox's and message's maps drop the raw links. Done; the pool writes the header, which
    the send passes it.
  - **261.4.4** The heap verifier, leak checker and `gc_record` report on the pool; tests: queued messages
    holding young references across minors and defrag, every size class and a large message, a producer
    and consumer on different carriers (the pool stays bounded), the stress legs. Done: the verifier and
    the leak checker see messages through the root walk; the report gives `heap.peakMessagePoolBytes`;
    suite group `actor-pool` (`tests/fixtures/actor_pool_matrix/{classes,pipeline}`, every pipeline × GC
    leg), cases `actor-pool-bounded` (17 MiB on 4 carriers, 34 without the hand-back to the global pool)
    and `actor-pool-carriers` (2 and 4 carriers, stress collections with the verifier). Each was checked
    against a runtime with the fault it targets: no message walk, no hand-back, minors skipping the young
    lists, compaction dropping live entries.
  - **261.4.5** Measure: the three actor benchmarks against Go; a backlog of 1M queued messages beside
    heavy allocation elsewhere (the cost of rescanning them at every minor). Done; see Results.
- **261.5** Find why `pipeline_actor` went from 180 ns an item (235.6, the table in
  [254](254-scheduler-performance.md)) to about 305 at one carrier, with the same source. The other
  scheduler rows moved by 5% or less. Bisect over the commits since 235.6. Since 261.4 the pipeline runs at
  96, so this matters only if the cause (most likely in the collector or the write barrier, which the
  messages paid) also slows code that is not actors; check that first on binary-trees and Richards. Done;
  see Results.

## Design — 261.4 message storage

### Options

Measured cost of a pipeline message today: about 35 ns, of which about 18 ns is the collector (queued messages
fill the nursery, survive minors and are promoted), about 10 ns the barrier (up to three `rtRememberStore`
calls a message), and about 6 ns the send, queue, drain and thunk call.

- **A. Mailbox-owned chunk buffers**, as a Go channel's buffer. A send reserves a slot in the mailbox's chunk
  and copies its arguments in; no allocation, header or link per message (24 bytes less a message);
  contiguous drains. Every mailbox holding mail holds at least one chunk (1M actors with a message each,
  4 GiB at 4 KiB chunks) unless chunks start small and grow; the send needs a new multi-producer slot
  reservation. About 6–8 ns a message.
- **B. Messages from a runtime pool, scanned as roots.** Today's layout and queue, with messages from
  per-carrier raw slabs and freed after the thunk reads them. Messages never touch the nursery and their
  links are raw, so no barrier. Every collection scans the live messages' fields as roots: a backlog that
  stays queued under heavy allocation elsewhere is rescanned at every minor, where today it is copied once.
  About 6–8 ns a message.
- **C. A cheaper barrier only:** an inline log-bit test, no stub, the mailbox remembered once a cycle. The
  collector's share stays. About 25 ns a message. Belongs to [262](262-collector-gaps.md).2 either way.

**Decided: B.** The same expected cost as A with no per-mailbox floor, and it keeps the queue and message
layout that work today. The backlog rescan was the known weak spot: measured at 26 ms a minor for 1M queued
messages, so minors scan only the messages sent since the last collection (the young lists below).

### The pool

- **Size classes** of 16 bytes from 32 to 512 bytes (31 classes). A handler's class is fixed at compile
  time from its message size. A message over 512 bytes takes a block of its own from the raw allocator, on
  a global list of large messages under a lock (rare: over 60 words of arguments).
- **Slabs** of 16 KiB per class, from the raw allocator, each on a global slab list (appended under a
  lock, when a carrier's and the global pool's lists are both empty). A slab's header records its class.
- **A free slot's header word is zero**; a live slot's holds its message type id. The free list links
  through the `next` word (offset 8).
- **Per-carrier free lists**, one head per class in the carrier record. Allocation and free are gc-leaf
  (no safepoint, no park), so the carrier cannot change under them and they need no atomics. A free goes
  to the freeing carrier's list, whichever carrier allocated the slot, so there is no remote free.
- **The global pool** keeps imbalance bounded: a carrier whose list for a class passes 64 slots moves 32
  to the global pool; a carrier with an empty list takes 32 from it before cutting a new slab. The pool is
  a per-class stack of 32-slot batches under a lock taken once a batch.

### Send, drain and free

- The send pops a slot (`rtMsgAlloc(size, header)`, which writes the header), writes the thunk, `self` and
  arguments with plain stores (raw memory, so no barrier), and pushes it on the mailbox. No safepoint lies
  between the pop and the push, so a collection never sees a half-written slot.
- The mailbox queue is unchanged except that `mb_head`, `mb_tail` and `next` are raw pointers into slabs:
  its three `rtRememberStore` calls go, and the mailbox's and message's maps drop those offsets.
- The thunk reads `self` and the arguments into its frame, frees the slot, and calls the handler. A
  message is live only while it waits, and a handler's own sends reuse the slot it just freed, warm in
  cache.

### The collector

- **Roots.** At each collection, under stop-the-world, the collector walks every slab and every large
  message and adds the address of each managed field of each live slot (header non-zero) to the root
  slots that `nomuSchedWalkSlots` fills, using the slot's type id and `rtOffsetsList` (so shaped and enum
  fields work as on the heap). The minor, the defrag major, the verifier and derived-pointer fixing then
  treat them as any root: young referents are promoted, moved referents rewritten in place.
- **Young lists.** A message never changes once sent, and the collection after its send promotes everything
  it references; every collection leaves the nursery empty. So a minor needs only the messages sent since
  the last collection: each carrier lists the slots it sends in, and a minor walks those lists and every
  large message, where a major walks every slab. Each collection unlists the slots and empties the lists. A
  slot is on at most one list: a listed slot's header carries a mark (a bit above the type id while live,
  -2 for free), and a send that finds the slot already listed does not list it again, so a slot freed and
  reused at once stays one entry. A full list drops its freed slots before it grows (a program that never
  collects would grow it without end); a carrier dropping a slot and another sending in it race on the
  header, settled by a compare-and-swap against the send's exchange.
- **Rebuild and release.** While walking, the collector rebuilds each class's free lists: every carrier's
  list is emptied into the global pool, and after a major a slab with no live slot beyond a reserve of
  one slab per class is returned to the raw allocator.
- **Lifetime.** A queued message keeps its actor (`self`) and arguments alive, as the mailbox chain did.
- **Accounting.** Pool bytes are outside the managed heap, so they do not drive collections; `gc_record`
  reports them beside the heap.

### Carries over

LXR keeps young evacuation, so queued messages on the managed heap would cost it the same way; the pool and
its root scan apply unchanged.

## Results

### 261.3 — the send path against Go

`tools/pingpong.py`, best of 7, ns per hop, item or job; Go with GOMAXPROCS as carriers. Apple M3 Max.

| benchmark | 1 | 2 | 4 | 8 | Go 1 | Go 2 | Go 4 | Go 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `pingpong_actor` (Go: `mailbox`) | 16.9 | 17.1 | 17.2 | 17.6 | 86.4 | 97.0 | 108.6 | 110.2 |
| `fanout_actor`, no work | 58.5 | 49.8 | 71.9 | 120.6 | 39.5 | 64.0 | 68.6 | 84.7 |
| `pipeline_actor`, no work | 312.4 | 254.4 | 205.0 | 263.6 | 174.5 | 128.0 | 104.9 | 96.0 |

Under the non-generational plan (`gc_immix`), the three run at 20.3, 87.7 and 459.1 at one carrier.

Findings:

- **The send itself is cheap.** A ping-pong keeps one message in flight, which dies young: 17 ns a hop,
  5–6× faster than Go's goroutines over buffered channels. Allocation, enqueue, the indirect thunk call
  and the drain all fit in that.
- **Queued messages cost the collector.** The fan-out and the pipeline queue thousands of messages at once
  (the pipeline's hub sends 20,000 before any is drained). Those messages live through minors and are
  promoted, and each send links a young message onto an old mailbox, which takes the write barrier's slow
  path. Over 300 no-work pipeline rounds at one carrier: collection 1,483 of 2,783 ms (1,019 cycles,
  1.5 GB promoted); in a profile, collector and barrier 77% of samples (`rtRememberStore` alone 32%),
  the send and drain about 6 ns a message. Without the nursery the queued messages go through full
  collections, which is slower still. Go's buffered channel copies into a buffer it allocated once.
- **The thunk call and a direct call are not worth building now.** They sit inside the 17 ns hop. Message
  storage is 261.4.
- **`pipeline_actor` regressed** since 235.6 (180 → 312 at one carrier); 261.5.

### 261.4 — messages from the pool

`tools/pingpong.py`, best of 7, ns per hop, job or item; Go with GOMAXPROCS as carriers.

| benchmark | 1 | 2 | 4 | 8 | Go 1 | Go 2 | Go 4 | Go 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `pingpong_actor` (Go: `mailbox`) | 14.0 | 14.0 | 14.1 | 14.1 | 89.5 | 98.9 | 107.7 | 108.5 |
| `fanout_actor`, no work | 29.6 | 36.8 | 48.2 | 107.3 | 39.7 | 67.2 | 72.4 | 85.5 |
| `pipeline_actor`, no work | 95.8 | 159.9 | 74.4 | 259.6 | 177.4 | 123.7 | 99.1 | 111.6 |

Before the pool (261.3): 16.9 / 58.5 / 312.4 at one carrier. Repeated runs vary by about ±30% at 2 and 8
carriers (the pipeline at 2 carriers ran 90–160).

- **Ahead of Go at one carrier on all three**, and at 4 carriers on the fan-out and the pipeline. 300
  no-work pipeline rounds at one carrier: 2,783 ms → 567 ms, no collections (1,019 before), the pool at most
  1.6 MB.
- **8 carriers are where they were** (pipeline 264 before, 226–292 now; Go 108). A profile there shows the
  send and pop atomics and the handler's first reads of each message, cache lines passing between cores; the
  pool's own calls are about 10%. Slots rounded to cache lines changed nothing. This is
  [254](254-scheduler-performance.md)'s cross-carrier cost.
- **A backlog.** 1M messages queued while the program allocates 400,000 small arrays: 91 ms (80 with no
  backlog; 207 minors); before the young lists, 5,454 ms, every minor rescanning the backlog. The pool held
  45 MB for the 1M messages.
- **Found on the way:** `RawPtr.null.advanced(by:)` let LLVM compile `rtMsgFree` to a trap
  ([263](263-raw-pointers-from-null.md)), and that trap's crash report repeated until the process was
  killed ([264](264-crash-report-repeats.md)).

### 261.5 — the pipeline's slowdown after 235.6

Compilers built at the commits since 235.6's table, each running its own commit's `pipeline_actor` (best of
7, ns an item at 1 / 4 carriers): the commit holding 235.6's table 203 / 234, the next (heap sizing,
[230](230-heap-sizing.md)) 448 / 448, HEAD before 261.4 about 305.

The first commit's run collected nothing: the heap before 230 never collected a program this small. Under
230's sizing the same run takes 10 minors (18 ms of pauses, 16 MB promoted): queued messages are promoted,
and each send then links onto a promoted message through the write barrier's slow path, which is most of
the difference. 235.6's 180 was measured with no collections, so the send path did not slow; the difference
is what collecting queued messages cost, which 261.4 removed (96 an item, no collections). For other programs
230's earlier collections are its intended trade of time for footprint, which
[262](262-collector-gaps.md).4 (heap sizing that weighs trace work) tunes.

## Refs

`runtime/msgpool.nomu` (the message pool), `design/internals/concurrency.md` (shareability, actor messages), `frontend/sema/sources/gen/Shareability.swift`,
`frontend/sema/sources/gen/NOIRGen.swift` (the `task` checks), `llvmgen/LLVMGenActor.swift`,
[106](106-actor-fiber-aware-mutex.md), [105](105-concurrency-hardening.md) (property tests for shareability
at task boundaries), [254](254-scheduler-performance.md).
