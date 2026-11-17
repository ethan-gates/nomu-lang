# Collector gaps — binary-trees and Richards against Go

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `runtime · gc · codegen` · **Size:** L ·
**Status:** paused, 262.5.3 next when it resumes; 262.7 done (no slowdown since 260; the baseline below); 262.3 done (no stubs: binary-trees
4% faster); 262.1 done (offsets read in place: binary-trees 10% faster); 262.4 closed (heap limit stays in bytes); 262.5.1 done (no unmark walk: binary-trees 10% faster, `immix` 29%); 262.5.2 done (pass folded into the scan, under 1%); 262.5.3 next; 262.2 done (262.2.1: Richards 3% faster;
262.2.3: binary-trees 6% faster) ·
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

Order: 262.5 (262.5.3 next), then 262.6.

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
  - **262.5.3** Nursery promotion: a variable nursery, aging, or a parallel minor.
  - **262.5.4** Large objects deciding between majors and minors.
  - **262.5.5** The barrier's log bit in the object header (one load from the object and a bit test, no range
    check), measured against 262.2.1's side table; considered under 262.2.
- **262.6** Parallel or concurrent marking, with LXR's design.

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the object ring's collector time and memory.

## Refs

`runtime/descriptors.nomu` (`rtOffsetsInto`, `rtOffsetListed`), `runtime/collect.nomu`, `runtime/immix.nomu`
(heap sizing), `llvmgen/LLVMGenRuntime.swift` (`nomuWriteBarrier`, `nomuRememberBarrier`); the benchmarks in
`practice/` (gitignored): `binary_trees`, `gen/richards`, `go/richards`, `gen/enum260/*`.
