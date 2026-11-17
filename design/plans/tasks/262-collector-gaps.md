# Collector gaps — binary-trees and Richards against Go

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `runtime · gc · codegen` · **Size:** L ·
**Status:** 262.7 next, with [257](257-toolchain-version-manager.md)'s snapshots; issues defined, each measured;
none started ·
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
Go, Richards went from 1.24× to 1.41× generational and 1.01× to 1.15× `gc_immix` since 260, so the slowdown is
more than the machine. Actors at 1 / 2 / 4 / 8 carriers, ns an item: pingpong_actor 13.7 / 13.6 / 13.6 / 13.6,
fan-out 28 / 35 / 49 / 103, pipeline 92 / 157 / 81 / 245; Go fan-out 39 / 63 / 70 / 86, pipeline 174 / 120 / 104
/ 101. Stubs: weak external `_nomu` symbols / calls through a stub are 236 / 425 in `pingpong_actor`, 233 / 438
in binary-trees, 234 / 475 in Richards.

## Gaps

Each is marked by whether it carries over to LXR ([127](127-lxr-collector.md)), which replaces GenImmix's
reclamation with reference counting on the same Immix heap, or belongs to GenImmix and would be replaced.

- **The offset list for objects with no conditional field** (carries over: LXR's decrements and backup
  trace walk object fields the same way). Every object visit lists its offsets (`rtOffsetsInto`) and reads
  them back by index (`rtOffsetListed`), two calls through stubs: 22% of the collector's samples in
  binary-trees, though `TreeNode`'s two offsets are fixed (260.8). Such an object could read its type's map
  directly, keeping the list for objects with enum or shaped fields.
- **The write barrier on store-heavy code** (carries over in shape: LXR's field-logging barrier has the same
  fast path to keep cheap). Richards runs 592 ms under the generational plan and 482 under `gc_immix` with
  no collection at all: the barrier, a heap-range check and a log-bit load on every store into an object,
  is the difference. Go's barrier is a flag test outside marking. Eliding the barrier for stores into
  objects known young, or a cheaper fast path, would close it.
- **Heap sizing by bytes** (carries over: LXR sizes its heap too). After each major the limit becomes live +
  (live + stacks) × r (`NOMU_GC_PERCENT`), while a cycle's cost follows live objects, so a denser layout
  collects more often at the same percent: one tree kept live under `gc_immix` takes 80 cycles with spare
  bits against 59 with the moved tag, at the same cost per cycle (260.7.4). A limit that also weighs the
  trace work, or a target share of time in the collector, would let a smaller layout keep its time.
- **Stubs on runtime calls** (carries over). Runtime functions are exported weak symbols, so each call goes
  through a stub; hidden visibility saved 2–4%. The stubs show in binary-trees' profile beside
  `rtOffsetListed`, `rtOffsetsInto`, `rtMinorForward` and `rtMinorScanObj`.
- **Nursery promotion** (GenImmix). Minors promote everything they find live: 983 MB at depth 21 (2.6 GB
  before 260), nearly all of it garbage soon after, which costs the copying and drives the majors. An array
  of 2M enums shows it too: 10 minors promote 70 MB of boxes the next round leaves dead, whenever the large
  arrays leave room for minors at all (260.7.4). Options: a variable nursery, aging, or a parallel minor
  (in-place promotion is the route the Immix line mostly left, for fragmentation).
- **Large objects deciding between majors and minors** (GenImmix). Objects over 32 KiB go to the
  large-object space and count toward mature space, so a program allocating large arrays runs majors where
  a slightly smaller array size runs minors that copy: the array benchmark's build took 311 ms with 16 MB
  arrays and 173 ms with 32 MB ones (260.7.4).
- **The unmark walk** (GenImmix). A second full trace in every major (about 1.2 s at depth 21 before 260);
  flipping mark states, or a side mark table cleared in bulk, removes it, with log bits set in the trace.
- **The minor's second pass** (GenImmix). Clearing mark bits and setting log bits over the promoted objects
  after copying (0.27 s at depth 21 before 260) could happen at copy time.
- **The collector on the program's thread** (carries over: LXR's backup trace is concurrent by design).
  Go marks on its spare cores, which is most of its lead on all cores; parallel marking in the pause, or
  concurrent marking.

## Work

Order: 262.7, then 262.3, 262.1, 262.2.

- **262.7** The slowdown since 260. Snapshot the compiler at `e994115` (where the baseline above was
  recorded) and at the current commit with 257, build Richards and binary-trees with each, and run them
  side by side. If the slowdown holds, find its cause in `7fa8407` (261, 263 and 264 together).
- **262.1** The offset list's fast path for objects with no conditional field; re-measure binary-trees.
- **262.2** The write barrier's fast path, and elision for stores into objects known young; re-measure
  Richards.
- **262.3** Hidden visibility for runtime calls. What makes the stubs: runtime and prelude functions are
  weak-ODR definitions (`weakOriginFiles` in `SSAIRToLLVM.swift`, so per-object copies fold at link, from
  100.3.7) and exported, so the dynamic loader binds them through `__stubs`. In `pingpong_actor`'s binary 156
  runtime functions are weak external and 425 call sites go through a stub (`nm -m`, `otool -tV | grep "symbol
  stub for: _nomu"`). First decide between hidden visibility on the weak definitions (folding kept, as the
  frame-split `.frame` bodies already are) and plain definitions now that the runtime is its own module. Other
  weak-ODR users: cross-module generic specializations, foldable GC descriptors and pointer maps,
  `nomu_actor_drain`.
- **262.4** Heap sizing that weighs trace work or targets a share of time in the collector.
- **262.5** The GenImmix-only items (promotion, large objects and minors, the unmark walk, the minor's
  second pass), weighed against how soon LXR replaces them before any is built.
- **262.6** Parallel or concurrent marking, with LXR's design.

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the object ring's collector time and memory.

## Refs

`runtime/descriptors.nomu` (`rtOffsetsInto`, `rtOffsetListed`), `runtime/collect.nomu`, `runtime/immix.nomu`
(heap sizing), `llvmgen/LLVMGenRuntime.swift` (`nomuWriteBarrier`, `nomuRememberBarrier`); the benchmarks in
`practice/` (gitignored): `binary_trees`, `gen/richards`, `go/richards`, `gen/enum260/*`.
