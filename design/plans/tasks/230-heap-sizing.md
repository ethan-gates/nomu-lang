# Heap sizing — a heap that grows, and a clean out-of-memory

**Avenue:** Risk · **Type/Lifecycle:** `runtime · gc` · **Size:** M · **Status:** done (230.1–230.9); the benchmark gap against Go is investigated outside this task (Leads, below) ·
**Source:** binary-trees against Go: Nomu crashes at the standard depth 21 and slows sharply at depth 20.

## Today

The heap is one Immix space of a fixed size: `rtHeapBlocks = 8192` blocks of 32 KiB, 256 MiB
(`startup.nomu`). Its side tables are sized from the same constant, and the write barrier's heap range and
log-bit base are startup constants derived from it. Nothing reads a size from the build or the environment,
and nothing grows the space.

Two consequences, both seen in binary-trees (`practice/`, not committed):

- **Out of memory crashes.** When a full collection leaves no free block, `rtImmixRefill` returns false,
  `rtTlabAlloc` returns null, and generated code stores through it: the process dies on `SIGSEGV` (exit 139)
  with no message. Depth 21 does this at a 294 MB peak; its live data does not fit in 256 MiB.
- **A cliff near the limit.** With live data close to the heap size, each collection frees little and the
  next one comes soon. Depth 19 runs in 0.98 s (Go 1.13 s); depth 20 in 17.7 s (Go 2.50 s), at 249 MiB
  resident, against the 256 MiB heap.

## What

A heap whose size follows the live data, so a program fails only when the machine is out of memory, and a
clear fatal error when it does.

## Design questions

- **Reserve big or grow — decided: one large reservation at startup, sized at run time.** The heap and its
  side tables are reserved once as one range; the heap's size is a soft limit inside it (blocks the
  allocator may use), and growth raises the limit. Untouched pages cost address space only, so resident
  memory follows the blocks in use (and, with [225](225-return-memory-to-the-os.md), falls when they are
  freed).
  - *Why.* The inline barrier tests the heap range and indexes the log-bit table by absolute address on
    every reference store into an object. One range keeps that at today's cost: the reservation's size only
    changes the startup values `rtHeapLo`, `rtHeapHi` and `rtLogbitBase`. The alternatives cost more: a
    reservation that grows by remapping moves the heap, and chunks mapped on demand (Go's arenas) add a
    dependent load before every barrier. HotSpot (card table), MMTk/LXR (side metadata) and .NET (regions)
    use the same layout. A later move to chunks would touch only the barrier, the runtime's address-to-index
    helpers and the slow path's range test.
  - *Configurable at run time.* An environment variable sets the reservation, and so the largest heap.
    Unset, a default sized from the machine applies, halving on a failed `mmap` (`ulimit -v`, small address
    spaces). An explicit size that cannot be reserved is a fatal error naming the size. The variable is
    `NOMU_HEAP_MAX`, in bytes with an optional suffix (`512MiB`, `64GiB`). The default is the larger of a
    fixed floor (64 GiB) and 4× physical RAM: the floor keeps small machines alike, and the RAM multiple
    covers large ones, since a heap past 4× RAM cannot run anyway. Reading RAM is a new runtime call
    (`sysctlbyname("hw.memsize")` on darwin, `sysconf` on Linux).
  - *Consequences.* Every reader of `numBlocks` that means "the heap's size" moves to the soft limit: the
    nursery reserve, the defrag copy reserve and budget, `nomuGcSpaceAvail` (the out-of-memory and
    mature-floor tests), and the report's block count. No pass reads or writes past the high-water mark
    (`freeCursor`); on darwin a read makes a page resident (225, "Reads count"). `rtClearLogTable`, which
    clears the whole log-bit table, is the one pass that breaks this today. Anything the barrier must see
    lives inside the range.
  - *Platform follow-ups, with [218](218-linux-support.md).* Linux: `MAP_NORESERVE` under the default
    overcommit, `PROT_NONE` plus `mprotect` as the limit grows under strict overcommit, and a decision on
    transparent huge pages (`MADV_NOHUGEPAGE`, or huge pages on purpose).
- **The growth policy — decided: a fixed ratio, Go's `GOGC` shape, r = 1.** After each major the soft limit
  sets mature space's limit to L = live + (live + stacks) × r (stacks from 230.9), clamped between the minimum heap and the reservation; the
  nursery sits on top of L (see the nursery below). Majors run when mature space reaches L (or the mature
  floor is crossed); minors are unchanged.
  - *Why.* Collection work per allocated byte stays near 1/r whatever the heap's size, and heap sizes depend
    only on the program's allocations, so runs reproduce, which the benchmark needs. Timing-based policies
    (a collection-time target as in HotSpot; MemBalancer's square-root rule, which MMTk offers) adapt better
    but vary run to run. The policy is one function called after a major, so
    [258](258-runtime-policy-tuning.md) can replace it.
  - *Footprint.* The heap peaks near 2× live data plus the nursery, as Go's does at `GOGC=100`; r = 1 keeps
    the benchmark against Go like for like. A smaller r (`NOMU_GC_PERCENT`) trades collection time for
    memory. 225 brings resident size back toward live data between majors, and LXR
    ([127](127-lxr-collector.md)) is the route to a footprint near live data.
  - *Live* is the blocks in use after the major, fragmentation included, since a fragmented block costs a
    whole block of resident memory.
  - *Large objects count*, in block units, toward both the trigger and the live figure. Today they count
    toward nothing, so a program allocating mostly large arrays never runs a major and never frees them.
  - *The limit falls* after a major that finds less live data; resident memory follows once 225 returns
    pages.
- **The starting heap — decided: 4 MiB, fixed, Go's starting target.** It is the minimum L: the limit
  before the first major and the floor L never drops below. A small program's heap stays a few MiB.
  Growing from it is cheap: the extra majors on the way to a large heap trace a doubling series, about one
  final-size major in all. Each major also has fixed costs (stopping carriers, scanning every fiber's
  stack, sweeping), so 230.5 measures a program with many fibers and little live data; if those costs are
  high, the minimum rises or scales with r as Go's does.
- **User-facing settings — decided: environment variables only.** `NOMU_HEAP_MAX` (above) and
  `NOMU_GC_PERCENT`, r × 100, default 100, with Go's `GOGC` meaning. They match the existing `NOMU_*`
  variables and change without a rebuild; a `gc.*` build setting for a program's own default can come later
  if one is needed.
  - *Near the maximum,* a program collects ever more often until a major frees nothing, then fails (today's
    rule, one level up). The default maximum is far above normal use, so this matters mainly under a small
    `NOMU_HEAP_MAX`. Failing early on high collection overhead (the JVM's rule) and a soft limit below the
    maximum (Go's `GOMEMLIMIT`) are [258](258-runtime-policy-tuning.md).6.
- **Out of memory — decided: fatal, reported in 219's crash format, exit status 2.** Four causes:
  - *The heap at `NOMU_HEAP_MAX`:* L cannot grow and a major leaves no room. Raised in the allocator
    (`rtTlabAlloc` on a failed refill) before returning to generated code, which today stores through the
    null and dies on `SIGSEGV` with no message.
  - *A large-object `malloc` failing:* `__nomu_raw_alloc` prints "out of memory" and exits 1 today; it moves
    to the same report and status.
  - *The reservation failing at startup:* an explicit `NOMU_HEAP_MAX` that cannot be reserved (above).
  - *The OS refusing pages:* the Linux OOM killer's `SIGKILL` cannot be caught; documented. A failed
    `mprotect` under strict overcommit is reported, with 218.

  The report uses [219](219-runtime-fault-handling.md)'s `nomu-crash:` lines and adds the heap's figures:
  the maximum and its source (`NOMU_HEAP_MAX` or the default from RAM), the current L, live data after the
  last major, the failed request's size, and a line suggesting a larger `NOMU_HEAP_MAX`. Status 2 matches
  Go's fatal errors and `fault.nomu`'s `SIGQUIT` exit. Recovery (the JVM's `OutOfMemoryError`) is unreliable,
  since the handler and other fibers need memory, and would need error handling
  ([115](115-error-handling.md)).
  - *L binds the program only.* The collector's copies (a minor's promotions, a defrag's evacuation) may go
    past L, up to the reservation, so a collection runs out of room only when the reservation does. At
    `NOMU_HEAP_MAX`, a minor checks for room before copying and runs a major in its place; today a failed
    promotion stores null into a live object.
- **The nursery — decided: L/4, clamped to 4–64 MiB, on top of L.** The reserve is recomputed after each
  major (the descriptor's field at +128); the bounds are placeholders for 230.5 to measure and 258 to tune.
  `NOMU_NURSERY_RESERVE` and `NOMU_MATURE_FLOOR` stay as overrides.
  - *Why clamped.* A plain fraction gives a small heap a tiny nursery (frequent minors, objects promoted
    before they die) and a large heap a huge one (2 GiB at L = 8 GiB). The 64 MiB top keeps today's nursery
    for programs that fill the current heap. Adaptive sizing (a survival or pause target, as G1 does) varies
    run to run.
  - *Why on top of L.* The ratio then keeps its meaning (mature space grows by r × live between majors) and
    the nursery's size does not change how often majors run. The heap's total is L plus the nursery.
  - *The mature floor* becomes room for one nursery of survivors plus a small fragmentation margin, measured
    as L minus mature blocks in use. It keeps majors on schedule; with the collector free to pass L (out of
    memory, above), it no longer guards promotion. Today's floor, twice the nursery against the free blocks of the whole
    heap, turns every minor into a major once the heap is more than half full; under the ratio rule, with
    live data near L/2 after a major, it would do so from the start.

## Work

- **230.1** Out of memory on today's fixed heap — done. `rtOutOfMemory` (`runtime/fault.nomu`) writes
  `fatal error: out of memory` and the crash format's lines (the cause, the request, the heap's size and
  blocks in use, the backtrace from the allocator, every fiber under `NOMU_TRACEBACK=all`) and exits 2. The
  allocator calls it when a collection leaves no room (`rtTlabAlloc`), and `__nomu_raw_alloc` when
  `posix_memalign` fails, which covers large objects and the runtime's own memory. Suite cases
  `out-of-memory-heap` (live data past 256 MiB, 1 and 4 carriers) and `out-of-memory-large` (a 64 TiB large
  object). The report's live data after the last major arrives with 230.4, which measures it.
- **230.2** The design, decided in this doc.
- **230.3** The reservation and the soft limit, with L held at today's 8192 blocks — done.
  - *Reservation.* `rtHeapNew` (`runtime/startup.nomu`) reserves `NOMU_HEAP_MAX` (decimal bytes, suffix B,
    KiB, MiB, GiB or TiB, at least 4 MiB; an unreadable value is a fatal error, a refused one out of memory)
    or the larger of 64 GiB and 4× physical RAM, halving on refusal. `Runtime.reserveZeroed` now returns null
    on refusal, and `rtReserve` reports out of memory for the side tables and stress-mode stacks; Linux maps
    with `MAP_NORESERVE`. New intrinsic `Runtime.physicalMemory()` (`sysctlbyname("hw.memsize")`; `sysconf`
    on Linux), with a libc stub for each.
  - *Soft limit.* Descriptor +160 holds L, min(8192 blocks, the reservation). The block pool, the pressure
    gauge (`nomuGcSpaceAvail`), the defrag budget, the nursery reserve and the report's snapshot read L;
    every address test reads the reservation.
  - *Bounded passes.* `rtClearLogTable`, `rtClearAllLines`, `rtCountMarkedLines` and `rtLineMarkCheck`
    stop at `freeCursor`. The suite records each run's peak resident memory (`max_resident_mib`); the
    `heap-reservation-untouched` case (dozens of majors over a small live set) stays under 128 MiB, and with
    the old whole-table clear it reached 4.1 GB. The rules are in `runtime/README.md`.
  - *Report.* The heap line gives L, blocks in use and the maximum with its source; at the maximum it adds
    the `NOMU_HEAP_MAX` hint.
  - *Cases.* `out-of-memory-heap-max` (16 MiB), `heap-max-unreadable`, `heap-max-too-small`,
    `heap-max-refused`, `heap-reservation-untouched`.
  - Measured: this machine (64 GiB RAM) reserves 256 GiB by default; the garbage fixture peaks at 2.5 MB
    resident.
- **230.4** Growth — done. Heap sizing lives in `runtime/immix.nomu` ("Heap sizing").
  - *Limit.* `rtHeapResize`, after every major, records the live blocks (descriptor +176: blocks in use and
    large objects, fragmentation included) and sets L = live × (1 + `NOMU_GC_PERCENT`/100) through
    `rtHeapSetLimit`, which also sets the nursery (L/4 within 128–2048 blocks) and keeps the two inside the
    reservation. The heap starts at 4 MiB.
  - *Triggers.* `rtGenCollect` runs a major once mature space (`rtMatureBlocks`) reaches L, or while fewer
    than `NOMU_MATURE_FLOOR` blocks remain below it, or when the reservation's free blocks could not hold the
    nursery; otherwise a minor. The mutator draws blocks up to L plus the nursery (`rtHeapCap`); the
    collector's copies up to the reservation.
  - *Large objects.* `losBytes` (descriptor +168) counts them: added at allocation, recounted from the
    survivors at the large-object sweep. One that would take mature space past L runs a major first (trigger
    6, "large objects"); at the maximum, one that still does not fit is out of memory.
  - *Report.* The heap line adds the live data after the last major. The recorder's trigger 2 is renamed
    "mature full".
  - *A bug the small heap exposed, fixed.* After a major, the mutator used to refill from recyclable blocks'
    holes. Those holes come from the major's line marks, which nothing updates for the objects placed in
    them, so after the next minor reset the allocator's scan, the same holes were handed out again over live
    objects. (The objects there also read as logged, so the barrier would have missed their nursery
    pointers.) The old 256 MiB heap almost never ran a major in the stress-minor legs, which hid it; with a
    4 MiB start, `actor_msg_queued` hung on every stress-minor run (a mailbox lost a message) and
    `sched_mixed_load` crashed about one run in ten. Under the generational plan the mutator now takes clean
    blocks only (`rtNextAllocBlock`'s `recyclable`); the `immix` plan keeps reusing holes. The overlap, rather
    than the barrier, was confirmed by 159.8's verifier, which with the fix reverted fails at the first minor
    after the first major on an object in a recyclable block lying on unmarked lines.
  - *Cases.* `heap-grows-past-256mib` (336 MiB live, full tier), `heap-large-objects-collected` (250 MiB of
    64 KiB arrays under 96 MiB resident, with majors from trigger 6), `gc-percent-unreadable`;
    `out-of-memory-heap` now runs at `heap_max: 64MiB`. Updated for the new policy: `gc-record-minor` (one
    major among the minors, now that mature space starts at 4 MiB), `gen-major` (floor 112, the old intent
    under the new floor), `immix-sweep` (built with the `immix` plan, whose hole reuse it tests).
  - The link check for unchecked frames found the report too deep below `__nomu_raw_alloc`; the report now
    runs on the carrier's stack through `nomu_oom_on_carrier` (`rtasm_arm64.s`).
- **230.5** Measure — done. Apple M3 Max (16 cores, 64 GiB), Go 1.27.2, release builds, best of 3, peak
  resident memory from `/usr/bin/time -l`. Programs in `practice/` (not committed): `binary_trees` and its Go
  twin through `bench.sh`, and `fibers_majors` with its Go twin `go/fibers_majors`. GC splits come from
  `gc.record: limited` reports.
  - *binary-trees.* Depth 21 now runs (it crashed at 256 MiB), and depth 20 fell from 17.7 s to 3.4 s.

    | depth | Nomu 4 carriers | Nomu 1 carrier | Go default | Go `GOMAXPROCS=1` |
    |---|---|---|---|---|
    | 19 | 1.36 s, 186 MiB | 1.51 s, 188 MiB | 1.10 s, 66 MiB | 2.46 s, 78 MiB |
    | 20 | 3.42 s, 357 MiB | 3.46 s, 357 MiB | 2.49 s, 138 MiB | 5.84 s, 209 MiB |
    | 21 | 7.27 s, 745 MiB | 7.30 s, 745 MiB | 4.96 s, 201 MiB | 11.65 s, 287 MiB |

    At depth 21 the collector takes 4.5 s and the program 2.8 s. Minors copy 2.56 GB into mature space
    (1.77 s of scanning). Majors take 2.5 s, half of it in the unmark walk, a second trace of the live set.
  - *Object size.* A `TreeNode` is 40 bytes (header, and two `Option<TreeNode>` of tag and pointer); Go's
    node is 16. Live data and the heap are about 2.5× Go's for that reason alone. Depth 21's stretch tree
    (2^23 nodes, ~320 MiB) sets L near 690 MiB, and the high-water mark (22,214 blocks) stays resident until
    [225](225-return-memory-to-the-os.md). Recyclable blocks stay at 4 or fewer, so hole reuse (230.6) has
    little footprint to win here.
  - *The nursery is too small for binary-trees.* Under L/4 depth 19 runs most of its time with a 20 MiB
    nursery, and its depth 16–18 trees (5–20 MiB, all live until checked) are promoted. A fixed nursery
    (`NOMU_NURSERY_RESERVE`, blocks):

    | nursery | depth 19 | depth 21 | `fibers_majors`, 0 fibers |
    |---|---|---|---|
    | default (L/4, 4–64 MiB) | 1.41 s, 183 MiB | 7.21 s, 745 MiB | 0.22 s, 20 MiB |
    | 4 MiB | 2.53 s, 127 MiB | 15.50 s, 472 MiB | 0.22 s, 17 MiB |
    | 16 MiB | 1.55 s, 191 MiB | 10.52 s, 476 MiB | 0.11 s, 29 MiB |
    | 64 MiB | 0.85 s, 226 MiB | 6.74 s, 764 MiB | 0.08 s, 78 MiB |
    | 128 MiB | 0.79 s, 248 MiB | 4.89 s, 728 MiB | 0.08 s, 142 MiB |
    | 256 MiB | 0.73 s, 371 MiB | 3.85 s, 883 MiB | 0.08 s, 267 MiB |

    A 64 MiB nursery beats Go at depth 19, and 256 MiB beats it at depth 21, at a higher footprint.
  - *The fixed cost of a major.* `fibers_majors` parks N fibers on a channel while main churns 30M objects
    through a 100k-entry ring (about 3 MiB live; 38 majors and 76 minors at every N):

    | parked fibers | median major | median minor | Nomu | Go (GCs run) |
    |---|---|---|---|---|
    | 0 | 1.5 ms | 1.2 ms | 0.22 s | 0.17 s (111) |
    | 1,000 | 2.6 ms | 1.3 ms | 0.27 s | 0.17 s (78) |
    | 10,000 | 16 ms | 2.1 ms | 0.86 s | 0.18 s (25) |
    | 100,000 | 160 ms | 18 ms | 7.66 s | 0.28 s (6) |

    Three causes. (1) The mark, unmark and unmark-and-unlog walks each allocate a zeroed 32 KiB work stack
    per root slot (`rtImmixEvacMark`, `rtImmixUnmark`, `rtGenUnmarkAndUnlog`); `__bzero` is most of the
    collector's profile. With the initial stack cut to 64 entries as an experiment, the major at 100k fibers
    fell to 36.5 ms and the run to 2.93 s. (2) The root walk visits every fiber's stack at every collection,
    about 160 ns a fiber, minors included. (3) Go counts goroutine stacks toward its heap goal, so it
    collects less as goroutines grow; Nomu's L ignores stacks.
  - *The 4 MiB start holds.* A 16 MiB minimum, as an experiment, left `fibers_majors` (0 fibers) at 0.22 s
    and depth 19 at 1.48 s; it helped at 10k fibers only by running fewer of the costly majors that (1) and
    (2) explain.
  - *Minor large-object scan.* The ring's 800 KB array is a large object rescanned whole at every minor,
    about 0.7 ms each.
- **230.7** One work stack per collection — done. The mark, evacuate, unmark and unmark-and-unlog walks
  take the collector's work stack (`rtGcWork`, `runtime/collect.nomu`) and hand it back with any growth;
  each collection frees it at its end. It used to be a zeroed 32 KiB buffer per root slot (230.5, cause 1).
  `fibers_majors` at 100k fibers: median major 160 ms → 18.6 ms, run 7.66 s → 2.18 s; at 10k, 16 ms → 2.5
  ms. What remains is mostly the root walk (Leads). Full tier 1819 passed.
- **230.8** The nursery rule — decided: L/4 within 4–64 MiB stays. 230.5 shows it too small for
  binary-trees, whose young trees are tens of MiB, but a rule fitted to one benchmark is overfitting; the
  benchmark gap is investigated outside 230 (Leads). The alternatives considered, for 258 if a real program
  needs them: a larger fraction and cap (L/2 up to 256 MiB), a nursery that grows when a minor promotes a
  large share of it, or a fixed 64 MiB nursery.
- **230.9** Fiber stacks count toward L — done. The root walk sums the used part of each fiber's stack
  (`rtStackScanBytes`, `runtime/stackwalk.nomu`), and after a major L = live + (live + stacks) × r, Go's
  rule since 1.18: stack scanning is collection work, so the heap grows to pay for it. Used bytes, as Go
  counts, since those are what the collector scans. `fibers_majors` majors at 0 / 1k / 10k / 100k fibers:
  38 / 29 / 15 / 1 (38 at every count before); 100k fibers runs in 0.62 s (2.18 s after 230.7; Go 0.28 s)
  at 281 MiB (Go 367 MiB); 10k unchanged at 0.34 s, its majors become minors. Case
  `heap-counts-fiber-stacks` (50,000 parked fibers: at most 5 majors, where the same churn without them runs
  10). Full tier 1820 passed.
- **230.6** Promotions fill recyclable holes — done. The minor's copy allocator takes recyclable blocks
  before clean ones (`rtNextRecyclable`, `runtime/immix.nomu`), keeps its place from one minor to the next
  (only a major's `rtResetAllocator` resets it), and marks each promoted object's lines in the unmark-and-
  unlog pass. Each hole, and the tail of each block a minor partly filled, is taken once per major cycle, as
  Immix's allocator does; the verifier's rule (a reachable object in a recyclable block lies on marked
  lines) holds between majors. The mutator still takes clean blocks only.
  - *The larger effect is the tails.* Each minor used to start a fresh block and leave the last one's tail
    empty, so mature space grew by at least a block per minor however little it promoted. Promotions are now
    packed: binary-trees depth 21 peaks at 551 MiB (745 before) in the same 7.2 s; depth 19 runs 8 majors
    (11) in 1.27 s (1.36), at 206 MiB (186: its third major lands where more is live, so L grows further);
    `fibers_majors` unchanged.
  - *Cases retuned,* their fixtures promoting too little to reach the limit now: `gen-major` (floor 125, 3
    majors spread through the run), `gc-record-minor` (floor 120). The verifier ran clean over binary-trees,
    `fibers_majors` and the 230.9 fixture. Full tier 1820 passed, three rounds (`--repeat 3`).

## Leads for the benchmark gap

Not part of 230. The binary-trees gap against Go is followed up in [260](260-enum-layout.md) (enum layout,
then 260.10 for the gaps outside it). Two further leads from `fibers_majors`, each still to be designed:

- a root walk that skips fibers whose stacks have not run since the last collection (160 ns a fiber per
  collection);
- card marking for large arrays, so a minor scans only their written parts.

## Refs

`rtHeapBlocks`, `rtSpace` (`src/stdlib/runtime/startup.nomu`), `rtImmixRefill`, `rtSelfhostOom`,
`rtTlabAlloc` (`src/stdlib/runtime/carrier.nomu`); [225 return memory to the OS](225-return-memory-to-the-os.md),
[219 fault handling](219-runtime-fault-handling.md), [127 LXR](127-lxr-collector.md).
