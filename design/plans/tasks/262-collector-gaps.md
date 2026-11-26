# Collector gaps — binary-trees and Richards against Go

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `runtime · gc · codegen` · **Size:** L ·
**Status:** 262.5.7 active (a parallel minor; 262.5.7 done: parallel minors on the parked carriers, recruited once a minor's work passes 4096 objects, the team sized by the last minor's copies (binary-trees depth 21: wall 2996 → 2617 ms, longest minor 35 → 7.5 ms; at 8 carriers CPU within 10% of one worker); 262.5.3 next); 262.5.6 done (the header explains the live set; the nursery inside the limit: peak 447 → 385 MiB at depth 21; free blocks returned at majors: mean footprint −21%); 262.7 done (no slowdown since 260; the baseline below); 262.3 done (no stubs: binary-trees
4% faster); 262.1 done (offsets read in place: binary-trees 10% faster); 262.4 closed (heap limit stays in bytes); 262.5.1 done (no unmark walk: binary-trees 10% faster, `immix` 29%); 262.5.2 done (pass folded into the scan, under 1%); 262.2.1–262.2.3 done (262.2.1: Richards 3% faster;
262.2.3: binary-trees 6% faster); 262.2.4 done (the barrier's check, not an optimizer fence, is Richards' 22%); 262.2.5–262.2.6 open (elision across blocks and stops) ·
**Source:** the enum layout work ([260](260-enum-layout.md)), which removed the enum decoding that had hid
these costs, and measured binary-trees, Richards and the enum benchmarks against Go.

## Today

After 260, binary-trees at depth 21 runs in 3.89 s and 445 MB against Go's 5.27 s and 205 MB (12.2 s on
one core); depth 19 in 0.89 s and 110 MB. Richards (`practice/gen/richards`, its Go twin
`practice/go/richards`) runs 1000 iterations in 592 ms under the default generational plan, 482 ms under
`gc_immix`, and 477 ms in Go. Apple M3 Max, release builds. Nomu is ahead on time where the collector is
cheap and behind on memory; the gaps below are where the collector, its policies and the write barrier
spend time or memory Go does not.

**Baseline before 262.3** (after 264, best of 7, load average about 3.7): binary-trees depth 19 0.98 s, 110 MB;
depth 21 4.28 s, 441 MB. Richards 702–713 ms generational, 582–590 ms `gc_immix`, Go 507 ms (477 before). Against
Go, Richards went from 1.24× to 1.41× generational and 1.01× to 1.15× `gc_immix` since 260. 262.7 found no
slowdown between the toolchains: the gap is this machine's state, and these figures are the baseline. Actors at 1 / 2 / 4 / 8 carriers, ns an item: pingpong_actor 13.7 / 13.6 / 13.6 / 13.6,
fan-out 28 / 35 / 49 / 103, pipeline 92 / 157 / 81 / 245; Go fan-out 39 / 63 / 70 / 86, pipeline 174 / 120 / 104
/ 101. Stubs: weak external `_nomu` symbols / calls through a stub are 236 / 425 in `pingpong_actor`, 233 / 438
in binary-trees, 234 / 475 in Richards.

## Gaps

Each is marked by whether it carries over to LXR ([127](127-lxr-collector.md)), which reclaims by reference
counting on the same Immix heap, or belongs to GenImmix. Nomu holds several collectors indefinitely, LXR is
the endgame only if it proves fastest here, and GenImmix is to be as fast as it can be meanwhile, so its own
gaps are work here as much as the shared ones.

- **The offset list for objects with no conditional field** (carries over). Closed by 262.1: such an object
  reads its type's map in place, and every walk reads offsets with no call per offset.
- **The write barrier on store-heavy code** (carries over in shape: LXR's field-logging barrier has the same
  fast path to keep cheap). Richards runs 592 ms under the generational plan and 482 under `gc_immix` with
  no collection at all: the barrier, a heap-range check and a log-bit load on every store into an object,
  is the difference. Go's barrier is a flag test outside marking. Eliding the barrier for stores into
  objects known young, or a cheaper fast path, would close it.
- **Heap sizing by bytes** (carries over: LXR sizes its heap too). Kept by 262.4; see there. After each major the limit becomes live +
  (live + stacks) × r (`NOMU_GC_PERCENT`), while a cycle's cost follows live objects, so a denser layout
  collects more often at the same percent: one tree kept live under `gc_immix` takes 80 cycles with spare
  bits against 59 with the moved tag, at the same cost per cycle (260.7.4). A limit that also weighs the
  trace work, or a target share of time in the collector, would let a smaller layout keep its time.
- **Stubs on runtime calls** (carries over). Closed by 262.3: executables export nothing, so no call goes
  through a stub.
- **Nursery promotion** (GenImmix). Minors promote everything they find live: 983 MB at depth 21 (2.6 GB
  before 260), nearly all of it garbage soon after, which costs the copying and drives the majors. An array
  of 2M enums shows it too: 10 minors promote 70 MB of boxes the next round leaves dead, whenever the large
  arrays leave room for minors at all (260.7.4). Options: a variable nursery, aging, or a parallel minor
  (in-place promotion is the route the Immix line mostly left, for fragmentation).
- **Large objects deciding between majors and minors** (GenImmix). Objects over 32 KiB go to the
  large-object space and count toward mature space, so a program allocating large arrays runs majors where
  a slightly smaller array size runs minors that copy: the array benchmark's build took 311 ms with 16 MB
  arrays and 173 ms with 32 MB ones (260.7.4).
- **The unmark walk** (GenImmix). Closed by 262.5.1. A second full trace in every major (about 1.2 s at depth 21 before 260);
  flipping mark states, or a side mark table cleared in bulk, removes it, with log bits set in the trace.
- **The minor's second pass** (GenImmix). Closed by 262.5.2. Clearing mark bits and setting log bits over the promoted objects
  after copying (0.27 s at depth 21 before 260) could happen at copy time.
- **The collector on the program's thread** (carries over: LXR's backup trace is concurrent by design).
  Go marks on its spare cores, which is most of its lead on all cores; parallel marking in the pause, or
  concurrent marking.

## Work

**Measuring a collector's cost.** A plan's cost is its total CPU time less what the program would cost with no
collector at all, which no run shows. The lower-bound-overhead method (Cai, *Garbage Collection Across the
Stack*, ANU 2026, ch. 3; Cai et al., ISPASS 2022) estimates it: run each workload under several plans and heap
sizes, subtract from each run the time plainly the collector's (its pauses and its own threads), and take the
smallest result as the program's cost. Each plan's cost is then its total less that, a lower bound that
includes its barriers and allocation paths. `gc_immix` with no collection, used as Richards' control in 262.2,
is one such run. Compare total CPU, not pause times.

Order: 262.5.3 and the rest of 262.5 (262.5.7 done), then 262.6. 262.2.5 and 262.2.6 are open beside them.

- **262.7** The slowdown since 260. **Done: none.** The toolchains at `e994115` (where 592 ms was recorded)
  and at `a61bc20` (261, 263 and 264 in), snapshotted with [257](257-toolchain-version-manager.md) and run
  interleaved, best of 9 (binary-trees depth 21 best of 5), load average about 4:
  Richards 706 / 706 ms generational, 593 / 589 `gc_immix` (Go 513); binary-trees depth 19 978 / 981 ms,
  depth 21 4326 / 4379 ms. The figures above are the baseline; the recorded 592 and 3.89 s came from a
  quieter machine, and Nomu's Richards is about twice as sensitive to the load as Go's.
- **262.1** The offset list's fast path. **Done.** `rtOffsetsList` points the list (`rtOffs` word 0) at a
  type's static map when the object has no shaped field, copying nothing; an object with shaped fields lists
  its offsets into a buffer in the map's int32 format (a new `Runtime.storeInt32`, loadInt32's counterpart),
  which grows past 256 entries in place of the old overflow fallback. The five walks (evacuating mark, minor
  scan, both unmark walks, the message pool's roots) read `Runtime.loadInt32(offs, at: i * 4)`, and
  `rtOffsetListed` is gone.
  - Snapshots `after-262.3` and `after-262.1`, interleaved, with a control copy of the first, load average
    4–9: binary-trees depth 19 944 → 840 ms (control 949, best of 15), depth 21 4124 → 3710 ms (control 4133,
    best of 7). In a 3 s profile at depth 21 the collector's samples fell from about 600 to 530, with
    `rtOffsetsInto` (114) and `rtOffsetListed` (45) gone.
  - Suite: `gc-wide-shaped` (one object with 320 enum fields, each holding a `Box`) covers the buffer's
    growth; its debug case fails when the list is cut at 256. 2089/2089 full.
- **262.2** The write barrier's fast path, and elision for stores into objects known young; re-measure
  Richards.
  - **262.2.1 A shorter fast path on the same side table. Done.** The barrier's values (the heap's start, the
    reservation's length, the log-bit table) moved from three globals into one block, `rtBarrierRange`
    (`startup.nomu`), read with one paired load and one load; one unsigned compare of the object's offset
    against the length replaces the two bounds, and the offset indexes the table. 18 instructions and four
    loads a store became 13 and three. Suite 2089/2089; with the range check forced to skip, `arr-dense`,
    `arr-gc-evac` and the `enum-layouts` nursery cases fail.
    Snapshots `after-262.1` and `after-262.2c`, interleaved, best of 15, with a control copy of the first,
    load average about 10: Richards 707 → 684 ms generational (control 707; `gc_immix`, no barrier, 590; Go
    511), a fifth of the barrier's cost; binary-trees depth 19 846 → 832 ms.
  - **262.2.2** No barrier for a store of a constant non-object (null, a payload-free enum case). **Tried,
    reverted: no gain.** Skipping the barrier when the stored value folds to a constant took Richards' barrier
    sites from 55 to 36, and its time stayed 690 → 689 ms (control 683). The stores that cost are references
    into long-lived objects. It also held for GenImmix only: LXR's barrier logs the overwritten value.
  - **262.2.3** No barrier for a store into an object known young. **Done.** An SSAIR pass, `BarrierElision`,
    runs last and drops a `writeBarrier` whose object was allocated earlier in the same block with no
    safepoint between; the verifier's I7 accepts exactly those stores and still catches one after a call. Sound
    because every mutator allocation is young: a generational TLAB takes only clean blocks, tagged nursery,
    and a collection an allocation triggers runs before the object exists; with the nursery off no minor reads
    the remembered set. Switch: `opt.barrier_elision` (config `no_barrier_elision`). Covers constructors:
    `TreeNode(left:right:)` evaluates its arguments, allocates, then stores.
    Barrier sites: binary-trees 28 → 7, Richards 55 → 41. Snapshots `after-262.2c` and `after-262.2.3`,
    interleaved, control copy of the first: binary-trees depth 19 831 → 782 ms (control 833, best of 15),
    depth 21 3617 → 3381 ms (control 3620, best of 7); Richards 686 → 692 ms (unchanged: its stores go
    into long-lived objects). Suite 2089/2089; unit tests for the pass and for I7 both ways.
  - Considered, not built here: the log bit in the object's header, a load from the object and a bit test
    (about 3 instructions, no range check). It changes the header, the collector's log-bit handling and its
    concurrency, and differs from LXR's side-table field logging; moved to 262.5.5 as a GenImmix item.
  - **262.2.4** Whether the barrier fences the optimizer. **Done: it does not; the check itself is the cost.**
    Richards pays about 22% for its barrier, where measured write barriers average about 0.9% (Yang, Blackburn,
    Frampton and Hosking, "Barriers reconsidered, friendlier still!", ISMM 2012). The suspicion was that the
    fast path's side-effecting inline asm (176.5.8) and its opaque slow-path call, neither carrying memory
    effects, made every barrier a memory clobber for LLVM. Variants of one compiler, each Richards built fresh,
    run interleaved 15 times (best / median ms; generational unless named):

    | variant | ms |
    |---|---|
    | as built | 598 / 606 |
    | asm and slow path confined to inaccessible memory | 604 / 613 |
    | slow path marked unlikely (branch weights) and its call `cold` | 563–569 / 570–577 |
    | that, the slow path through an asm stub under `preserve_mostcc` | 558–564 / 563–578 |
    | the check kept, an empty asm in place of the call | 574 / 582 |
    | no barrier (sound here only: Richards never collects) | 489 / 492 |
    | `gc_immix` | 489–492 / 493–502 |
    | range block reached without the GOT (hidden visibility) | 596 / 600 |

    - Richards runs no collection (`gc.record`: 0 cycles), so nothing is promoted, no log bit is ever set and
      the slow path never runs. The whole gap to `gc_immix` is the barrier: the generational plan with no
      barrier matches `gc_immix`.
    - The memory effects change nothing. The cost splits into the check, about 85 ms (the variant with an
      empty asm for the call), and the call's presence, about 25 ms: values live across it move into
      callee-saved registers, so each function with a barrier saves more in its prologue. Marking the slow
      path unlikely and cold takes back most of the 25 ms; `preserve_mostcc` adds a few more.
    - The check is 12 instructions and four dependent loads a store: the GOT entry of `rtBarrierRange`, the
      heap's start and span, the table, then the log byte. Hidden visibility drops the GOT load but LLVM then
      rematerializes the address at each use (86 `adrp` against 54), and it is slower.
    - Removing the call alone does not measure the check: with no effect left, LLVM deletes it.

    Kept: the slow path's branch is marked unlikely and its call `cold` (`nomuRememberBarrier`): Richards 600 →
    564 ms best, 605 → 573 median, interleaved 15 times; suite 4220/4220 full. The check's cost is the larger
    lever, through fewer loads; it goes with the header log bit (262.5.5), or a side table at a fixed address
    (MMTk's side metadata).
  - **262.2.5** Young objects tracked across blocks. `BarrierElision` drops a barrier only within one block. A
    data-flow pass over the function (with phis), as the Dart VM's `WriteBarrierElimination` does, keeps an
    object known young until a stop. Every entry and loop header is a stop, so the gain is limited until 262.2.6.
  - **262.2.6** Elision across stops, with the runtime's help (needs design). Dart elides across instructions
    that can collect because its runtime adds each live temporary a collection promotes to the remembered set
    (and, under concurrent marking, to a deferred marking stack), so a later store into it without a barrier is
    still seen; large arrays are left out, since rescanning them costs more than their barriers. Nomu's stack
    maps name every live value at a stop, so a minor collection could remember the promoted objects they hold.
    To design: which frames' values count (Dart takes only the top frame, for stops that do not call), the cost
    of rescanning them, and what LXR's concurrent tracing would need besides.
  - Not numbered: a "returns a fresh object" fact in function summaries, so elision follows a constructor
    call (Zee and Rinard, "Write barrier removal by static analysis", OOPSLA 2002, which also reorders
    allocations so the object pointed to comes first). Waits on how the summaries grow. If objects are ever
    allocated straight into the mature space, 262.2.3's reasoning (every mutator allocation is young) no
    longer holds.
- **262.3** Stubs on runtime calls. **Done.** What made the stubs: runtime and prelude functions are weak-ODR
  definitions (`weakOriginFiles` in `SSAIRToLLVM.swift`, so per-object copies fold at link, from 100.3.7) and
  were exported, so the dynamic loader bound them through `__stubs`. Of hidden visibility on every weak-ODR
  definition, plain definitions for the runtime package, and a link that exports nothing, the link was chosen:
  one flag (`-exported_symbols_list /dev/null` in `linkFlags`), every weak-ODR user covered (specializations,
  descriptors, `nomu_actor_drain`), no codegen change. `-x` is dropped, since an unexported symbol is local and
  `-x` would strip every function name; profiles and `atos` on a crash report name functions. Hidden
  visibility could still let LLVM reach descriptors without the GOT; not measured.
  - Stub calls into `_nomu`: `pingpong_actor` 425 → 0, binary-trees 438 → 0, Richards 475 → 0; binaries about
    4% smaller.
  - Snapshots `before-262.3` and `after-262.3`, interleaved, load average 4–8: binary-trees depth 19 989 →
    949 ms, depth 21 4320 → 4136 ms (best of 5); Richards 711 → 706 ms generational, 589 → 589 `gc_immix`
    (Go 510); at 1 carrier, ns an item: pingpong_actor 13.5 → 13.2, fan-out 28.7 → 26.4, pipeline 90.2 →
    87.2. At 2 to 8 carriers the changes go both ways inside those runs' ±30%.
  - Paired, 30 rounds, each run from a fresh copy, with a control of `before` against a copy of itself; median
    change and 95% bootstrap interval at 1 carrier: binary-trees depth 19 −4.4% [−4.7, −3.5] (control +0.1%
    [−0.3, +0.3]), pingpong_actor −3.1% [−3.5, −2.6] (control +0.1%), fan-out −4.1% [−5.6, −3.0] (control
    −0.3% [−1.8, +1.3]), pipeline −3.1% [−5.6, −1.5] (control −0.9% [−1.8, +1.1]).
  - Suite: 620/620 fast, 2087/2087 full.
- **262.4** Heap sizing that weighs trace work or targets a share of time in the collector. **Closed: the
  limit keeps counting bytes.** Of three policies (objects in the limit: headroom r × (live bytes + k × live
  objects + stacks); a target share of time in the collector, as MemBalancer does; bytes, as Go's GOGC), bytes
  stays. The other two buy time with memory, where Nomu trails Go and the thesis puts its weight, and the
  objects rule would grow binary-trees' heap further. A denser layout gets less memory at the same percent,
  so layouts are compared at matched memory, as 260.7.4 did. A time-share target is the policy to revisit if
  programs doing real work show the collector taking too much time.
- **262.5** The GenImmix-only gaps, each measured before and after:
  - **262.5.1** The unmark walk. **Done.** The collector's mark moved to header bits 34–35, holding 0, 1 or
    2; a per-runtime mark value alternates 1 → 2 at the start of each major (`rtAdvanceMark`), and an object
    is marked when its bits equal it. Survivors keep last cycle's value and new objects 0, so both read
    unmarked and no walk clears marks, as MMTk's Immix rotates its mark state. A side mark bitmap cleared in
    bulk (Go, HotSpot) was the alternative; it leaves large objects needing a header mark anyway. Every major
    driver advances the mark and runs no unmark walk, so the `immix` plan gains too. Under GenImmix the log
    table is wiped before the trace and the trace sets each in-heap survivor unlogged at its final address.
    Bit 32 stays the heap verifier's own mark (`rtTryMark`, `rtImmixUnmark` for its tests); the heap
    verifier's header rule accepts a collector mark of 0–2. The log-bit helpers (`rtLogBit`, `rtSetUnlogged`,
    `rtClearLogged`) now use shifts and masks in place of a doubling loop, which also cut the minor's second
    pass from 396 to 238 ms.
    Collector phases at depth 21 (recording build): majors 1045 → 617 ms (unmark 576 ms gone, trace 462 →
    610 with the log bits), minors' second pass 396 → 238 ms. Snapshots `after-262.2.3` and `after-262.5.1`,
    interleaved, control copy of the first, load average 5–9: GenImmix depth 19 781 → 697 ms (control 778,
    best of 11), depth 21 3426 → 3105 ms (control 3446, best of 5), peak RSS 445 → 441 MB; `immix` depth 19
    2527 → 1795 ms, depth 21 11325 → 8026 ms. Suite 2089/2089, fast tier with `gc_verify` 622/622; major-only
    (`nursery_blocks=-1`) with `gc_verify`, the only failures are the 45 cases that expect minors.
  - **262.5.2** The minor's second pass. **Done.** With 262.5.1's rotating mark a promoted copy keeps this
    cycle's mark (the next major advances past it, and a minor marks only fresh copies), so nothing clears it;
    its size, line marks and log bit are taken in the Cheney scan, which visits each promoted object once, and
    the separate pass (phase 8) is gone. The work moved more than it vanished: in the recording build at depth
    21 minors went 989 → 957 ms (scan 735 → 942, the pass's 238 gone). Snapshots `after-262.5.1` and
    `after-262.5.2`, interleaved, control copy: depth 19 698 → 693 ms (control 700), depth 21 3123 → 3099 ms
    (control 3127), under 1%. Kept for the simpler minor. Suite 2089/2089, fast tier with `gc_verify` 622/622.
    What remains of the minors is the scan itself, the copying 262.5.3 addresses.
  - **262.5.3** Nursery promotion: a larger or adaptive nursery, or aging (explore after 262.5.6 and 262.5.7).
    Binary-trees at depth 21, recording build for the collector columns, best of 3 for wall and RSS:

    | nursery | minors | majors | promoted | collector | wall | RSS |
    |---|---|---|---|---|---|---|
    | 4 MiB | 3476 | 36 | 3575 MiB | 2928 ms | 4.75 s | 280 MiB |
    | 16 MiB | 858 | 20 | 2159 MiB | 1776 ms | 3.70 s | 334 MiB |
    | default (a quarter of L, at most 64 MiB) | 354 | 11 | 983 MiB | 840 ms | 2.82 s | 447 MiB |
    | 128 MiB | 105 | 4 | 528 MiB | 456 ms | 2.47 s | 540 MiB |
    | 256 MiB | 52 | 2 | 266 MiB | 230 ms | 2.26 s | 547 MiB |

    Each minor promotes about 5 MiB, what is live at that moment (mostly the tree being built), so promotion
    and the majors it drives halve with each doubling of the nursery, at a cost in RSS. Aging would keep those
    short-lived survivors out of mature space but copies them all the same.
    The table predates the parallel minor (262.5.7). With it, re-sweep the recruitment count
    (`NOMU_GC_PARALLEL_MIN`, 4096, chosen when a recruit woke every carrier; now a recruit wakes a team sized
    by the work, so recruiting earlier may pay) against the nursery sizes, since both set how large minors
    are.
  - **262.5.4** Large objects deciding between majors and minors.
  - **262.5.6** RSS beyond the live heap (carries over: the Immix block pool is LXR's too). At the default
    nursery binary-trees peaks at 208 MiB in use and 447 MiB resident (Go: 205 MB). The rest is free heap
    blocks: touched once, never returned to the OS (the runtime has no `madvise`). In steady state 3464 of
    5748 touched blocks are free; after the peak major 6657 of 11265 (208 MiB); `vmmap` puts 343 MiB of the
    heap reservation resident against malloc's 38 MiB and stacks under 1 MiB. Returning free blocks does not
    lower the peak, though: after the peak major 4606 blocks are live, L = live × 2 = 9212 and the nursery adds
    2048, 11260 blocks, and the program fills that before the next major (the touched high-water mark is
    11265). The peak is the sizing policy: twice the live set, with the nursery on top.
    - **262.5.6.1** Why the live set is about 1.4× Go's (144 MiB of full blocks at the peak; Go's 205 MB peak
      at the same 100% growth suggests about 100 MB). **Done: the object header.** A tree node is 24 bytes (an
      8-byte header and two references), Go's 16 (its type information lives outside the object). Live at the
      peak: the depth-21 tree (4,194,303 nodes) and the last iteration's depth-20 trees (2,097,151), 96 + 48 =
      144 MiB, the full blocks exactly, so line fragmentation is nil; at 16 bytes the same nodes are 96 MiB,
      about 192 MB at twice the live set, near Go's peak. The header stays (Immix and LXR need each object's
      type at the object); compressed references would close the gap, parked as
      [272](272-compressed-references.md).
    - **262.5.6.2** The nursery inside the heap limit, as Go's heap goal covers everything. **Built**
      (`rtHeapSetLimit`): the allowance live + (live + stacks) × r covers the nursery, mature space gets the rest
      and at least the minimum, and the `immix` plan, with no nursery, is unchanged. Snapshots `nursery-on-top`
      and `nursery-in-limit`, interleaved (binary-trees best of 7, Richards best of 15):

      | workload | on top | in the limit |
      |---|---|---|
      | binary-trees depth 19 | 0.630 s, 112 MiB | 0.640 s, 94 MiB |
      | binary-trees depth 21 | 2.830 s, 447 MiB | 2.930 s, 385 MiB |
      | Richards | 0.545 s | 0.547 s |

      About 15% less peak memory for 2–4% more time on binary-trees (majors 11 → 15 at depth 21); Richards does
      not collect. Against Go's 205 MB at depth 21, 2.2× → 1.9×. Suite 4220/4220 full. Kept: LXR is the endgame, so GenImmix
      takes Go's memory-for-time trade where it is a realistic one, not the fastest setting regardless of
      memory.
    - **262.5.6.3** Return free blocks to the OS at each major. **Done** (`rtHeapReturnFree`, `immix.nomu`).
      After the sweep and the resize, free blocks go back (`Runtime.advise`: `MADV_FREE_REUSABLE` on darwin,
      `MADV_DONTNEED` on Linux) from the bottom of the free list, until the resident blocks are within the
      allowance and a tenth, as Go's scavenger keeps its heap near the goal. The sweep puts returned blocks at the
      bottom (a byte per block, descriptor @184 and @192), so the allocator takes every resident free block first;
      popping a returned one takes its pages back (`MADV_FREE_REUSE`). The report counts them (counter 26).
      Binary-trees at depth 21: after the stretch tree's major the heap returns 3089 blocks and stays at
      96–118 MiB resident through the middle phase. Snapshots `nursery-in-limit` and `return-free`, interleaved,
      sampled every 20 ms with `proc_pid_rusage` (best of 5 wall; mean and peak physical footprint):

      | workload | before | returning |
      |---|---|---|
      | binary-trees depth 21 | 3.03 s, 365 / 385 MiB | 3.01 s, 287 / 382 MiB |
      | binary-trees depth 19 | 0.67 s, 65 / 90 MiB | 0.67 s, 58 / 94 MiB |
      | Richards | 563 / 571 ms | 565 / 569 ms |

      The mean footprint falls 21% at depth 21; peaks and time are unchanged, as expected (262.5.6). RSS does
      not move on darwin: reusable pages stay counted until the system takes them, so footprint is the measure.
      Suite 4220/4220 full.
  - **262.5.7** A parallel minor: the minor's scan and copy on several threads, 552 ms of 840 ms of collector
    time at depth 21. Objects, barriers and the mutator's view stay as they are. Priorities: soundness, then
    pause length, then total CPU. Design in `selfhosted-gc.md` §11.7.
    - **262.5.7.1** The design. **Done.** Workers are the coordinator and the parked carriers. Forwarding
      claims the object by a CAS to a busy header state (bit 33 with mark value 3), then copies and publishes.
      Work is shared through a local stack per worker and a lock-guarded chunk pool. Each worker copies into its
      own blocks, which keeps line marks and promoted objects' log bits free of races; remembered objects'
      unlogs move to a serial pass. Small minors and `NOMU_GC_THREADS=1` stay on one worker.
    - **262.5.7.2** Forwarding by claim, and the depth-first trace, on one worker. **Done.** `rtMinorClaim`
      (`collect.nomu`) CASes a nursery object's header to busy, copies it, writes payload word 0 and stores the
      forwarded header atomically; the winner alone pushes the copy. The minor's roots push onto a work stack
      and the trace pops depth-first, in place of the Cheney queue, which is removed. Snapshot `cheney` against
      the tree, interleaved, load average about 5: binary-trees depth 19 667 → 664 ms best (671 → 673 median, 15
      rounds), depth 21 2980 → 2933 ms (2987 → 2935 median, 7 rounds). Recording builds at depth 21, the same
      277 minors and 857 MiB promoted: the minors' scan 479 → 425 ms, the longest minor 41.7 → 33.1 ms; the
      depth-first order saves more than the CAS costs. Suite 4220/4220 full (3 repeats).
    - **262.5.7.3** A copy cursor per worker. **Done.** The space's single copy cursor became a table of worker
      records (`rtCopyWorker`, `immix.nomu`; space @48), one for the coordinator and one for each carrier, 128
      bytes apart: a copy cursor and the minor's work stack, which is now kept from one minor to the next in
      place of a 512 KiB allocation each minor. `rtNextHole` takes a cursor and takes whole blocks under
      `rtCopyLock`; majors copy on worker 0 and reset every record (freeing the stacks). `rtGenCollect`'s room
      check counts a part-filled block for each worker. Still one worker: binary-trees depth 19 672 → 672 ms,
      depth 21 2952 → 2952 ms (best, against 262.5.7.2's binaries, interleaved). Suite 4220/4220 full (3
      repeats).
    - **262.5.7.4** The chunk pool and termination, the parked carriers as helpers. **Done** (`collect.nomu`:
      `rtMinorJob`, `rtMinorWork`, `rtMinorHelp`, `rtMinorShare`, `rtMinorAwait`). Parked carriers join from
      `rtSchedStwParkCarrier`, woken on stw-gen's futex; roots are claimed in ranges; sharing is on demand (the
      bottom half of a stack when workers are idle and the pool empty); termination is decided under the pool's
      lock. Two races found in review and closed before the first run: a stale "pool empty" read could end the
      trace with a chunk pooled (fixed by deciding under the lock), and the scanner of a shared object rewriting
      a log byte its copier was writing (fixed by setting line marks and log bits at the claim). The global
      offset list became one per worker (`rtOffsetsListIn`). Settings `NOMU_GC_THREADS` (default: carriers + 1)
      and `NOMU_GC_PARALLEL_MIN` (here in nursery blocks; 262.5.7.5 made it the objects handled before recruiting); report counter 6
      (minor workers). Tests: suite value `stress-parallel`, case `gc-parallel-shared` (1, 2, 4, 8 carriers);
      suite 4701/4701 full (3 repeats), and 4701/4701 with `--run-setting gc_parallel_min=0`, with and without
      `gc_verify`. Binary-trees depth 21 at 4 carriers (5 workers), recording build: minors 521 → 146 ms in
      all, the longest 39.0 → 8.0 ms, p90 5.4 → 1.5 ms; wall 2955 → 2658 ms best of 5 against 262.5.7.3's
      binary. On one worker the new path costs: wall 3050 ms, minors' scan 507 ms against 262.5.7.2's 425.
    - **262.5.7.5** When to go parallel, and the one-worker cost. **Done.**
      - Recruit once the work proves large: the nursery-size threshold could not tell (a minor runs when the
        nursery is full), so every minor starts on the coordinator, which recruits the parked carriers
        (`rtMinorRecruit`) after `NOMU_GC_PARALLEL_MIN` roots and objects with work left. Binary-trees depth 21,
        4 carriers, 5 recording runs pooled (about 1390 minors each):

        | recruit after | p50 | p75 | p90 | p99 | max |
        |---|---|---|---|---|---|
        | one worker | 85 µs | 1.26 ms | 5.3 ms | 26 ms | 39 ms |
        | 0 | 102 µs | 0.37 ms | 1.29 ms | 6.4 ms | 10.0 ms |
        | 1024 | 105 µs | 0.38 ms | 1.29 ms | 7.1 ms | 11.2 ms |
        | 4096 | 91 µs | 0.42 ms | 1.44 ms | 6.0 ms | 9.5 ms |
        | 8192 | 89 µs | 0.47 ms | 1.50 ms | 6.0 ms | 9.4 ms |

        Chosen: 4096 (about 50 µs of tracing), the median within 6 µs of one worker.
      - The one-worker cost: LLVM turned the claim's line-marking loop into a `memset` call per object; the
        first and last lines are now two stores, with a loop only between. Promoted counts are kept only when
        the collector records. One-worker minors at depth 21 (recording builds, 5 runs): 262.5.7.2 445 ms,
        262.5.7.4 543 ms, now 489 ms; wall 2950 / 3030 ms against 262.5.7.3. Marking at the pop and the
        sharing check's shape measured no difference; the rest is not found.
      - Result, 4 carriers, one worker against the default (best wall, median CPU, 7–11 rounds interleaved):

        | workload | one worker | parallel |
        |---|---|---|
        | binary-trees depth 21 | 2996 ms, CPU 3039 | 2617 ms, CPU 3113; minors 482 → 154 ms, longest 35.4 → 7.5 |
        | binary-trees depth 19 | 683 ms, CPU 699 | 598 ms, CPU 761 |
        | enum `tree` (`practice/gen/enum260/tree`) | 374 ms, CPU 378 | 289 ms, CPU 445 |
        | enum `live`, `alloc_live`, `fanout_actor`, `pipeline_actor` | unchanged | unchanged |

        Wall falls 11–23% where minors are large; CPU rises 2–18%, the idle helpers' spinning and waking and
        the cost of sharing. Pooled pauses at depth 21: p50 81 → 89 µs, p90 5.1 → 1.3 ms, p99 25 → 5.8 ms.
      - The heap verifier takes 30 s to over 200 s on binary-trees depth 19 depending on threads and load; it
        is correct, only slow.
      - Suite 4701/4701 full (3 repeats), and 4701/4701 with `--run-setting gc_parallel_min=0`.
    - **262.5.7.6** The parallel minor's CPU. **Done.** The extra CPU grew with the carriers (binary-trees
      depth 21 at 8 carriers: user +170 ms, system 92 → 371 ms, 19,000 more context switches; enum tree +78%),
      and wall time was best at 4–5 workers. Counters added (report 7 chunks shared, 8 idle sleeps): about 470
      shares and 180 sleeps a parallel minor at 4 carriers, 810 and 220 at 8. Tried and measured no gain: waking
      one idle worker for each chunk, longer spinning (1000, 10000), spinning on the pool lock before its futex
      (more system time). Growing the team on demand grew it to every carrier and was slightly worse. Kept:
      the team sized by the last minor's copies, one helper for every 64 blocks, at least one
      (`rtMinorRecruit`; workers count blocks under the copy lock); a sharer wakes a sleeper only when one is
      asleep; the chunk count on its own line. Of 8, 16, 32, 64 blocks and every carrier, 64 gave the same wall
      time or better and the least CPU; pauses pooled over 4 recording runs matched every-carrier within noise
      (p90 1.6–2.2 ms, p99 6–7 ms at 4 and 8 carriers). `NOMU_GC_PARALLEL_MIN=0` (the stress setting) takes every
      helper, so the stress tests keep many workers. Median CPU against 262.5.7.5, 7 rounds interleaved, load
      3–7: enum tree at 8 carriers 682 → 436 ms (one worker 395), at 4 477 → 456; binary-trees depth 19 at 8
      981 → 779 (one worker 777), at 4 754 → 707; depth 21 at 8 3524 → 3390 (one worker 3088). Wall within noise
      of 262.5.7.5, and still 10–20% under one worker. Suite 4701/4701 full (3 repeats), and with
      `gc_parallel_min=0` and `gc_verify` everywhere.
    - **262.5.7.7** The one-worker cost left from 262.5.7.4. **Investigated, not found; parked.** One-worker minor
      time at binary-trees depth 21, recording builds, 5 runs each: 262.5.7.2 458 ms, now 495–527. The recording
      build's promoted counts moved from the claim (a load and store on the worker record per copy) to locals at
      the pop, so recording builds compare like for like with 262.5.7.2's (kept; suite 4701/4701 full, 3
      repeats, and with `gc_parallel_min=0` and `gc_verify` everywhere). Ruled out, each within noise:
      the claim's CAS and release store (plain stores while the coordinator is alone: 506 against 495, reverted);
      the line marks and log bit at the claim (marks at the pop); the per-worker offset list (the global one);
      the trace loop's sharing and recruit checks (removed). Summed samples over 5 runs put the gap in
      `rtMinorClaim` (about 120 samples net of the work it took over from the old loop) and `rtMinorScanObj` (about
      90), with machine code nearly the same as 262.5.7.2's. Left: 262.5.7.3's worker records (the copy cursor
      and work stack moved, blocks taken under a lock), checked then by wall time only, and code layout. A
      bisect needs the 262.5.7.2 and 262.5.7.3 sources rebuilt as snapshots. About 1.5% of binary-trees' run
      time, paid only by minors too small to recruit helpers.
  - **262.5.8** A background scavenger (carries over: the block pool is shared). 262.5.6 returns memory inside
    the major's pause; Go returns it from a paced background scavenger instead (about 1% of a core, RSS kept
    near the heap goal), which keeps the cost out of pauses and returns only blocks idle a while, so less is
    returned and faulted back soon after. It costs synchronization with carriers taking blocks, coordination
    with the collector's walks, pacing and a lifecycle; the monitor thread could carry it, as Go's `sysmon`
    wakes its scavenger. Evaluate once 262.5.6 shows what returning costs in the pause and in faults.
  - **262.5.5** The barrier's log bit in the object header (one load from the object and a bit test, no range
    check), measured against 262.2.1's side table; considered under 262.2.
- **262.6** Parallel or concurrent marking, with LXR's design.

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the object ring's collector time and memory.

## Refs

`runtime/descriptors.nomu` (`rtOffsetsInto`, `rtOffsetListed`), `runtime/collect.nomu`, `runtime/immix.nomu`
(heap sizing), `llvmgen/LLVMGenRuntime.swift` (`nomuWriteBarrier`, `nomuRememberBarrier`); the benchmarks in
`practice/` (gitignored): `binary_trees`, `gen/richards`, `go/richards`, `gen/enum260/*`.
