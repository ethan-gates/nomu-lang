# Collector gaps — binary-trees and Richards against Go

**Avenue:** Risk (perf, footprint) · **Type/Lifecycle:** `runtime · gc · codegen` · **Size:** L ·
**Status:** issues defined, each measured; none started ·
**Source:** the enum layout work ([260](260-enum-layout.md)), which removed the enum decoding that had hid
these costs, and measured binary-trees, Richards and the enum benchmarks against Go.

## Today

After 260, binary-trees at depth 21 runs in 3.89 s and 445 MB against Go's 5.27 s and 205 MB (12.2 s on
one core); depth 19 in 0.89 s and 110 MB. Richards (`practice/gen/richards`, its Go twin
`practice/go/richards`) runs 1000 iterations in 592 ms under the default generational plan, 482 ms under
`gc_immix`, and 477 ms in Go. Apple M3 Max, release builds. Nomu is ahead on time where the collector is
cheap and behind on memory; the gaps below are where the collector, its policies and the write barrier
spend time or memory Go does not.

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

- **262.1** The offset list's fast path for objects with no conditional field; re-measure binary-trees.
- **262.2** The write barrier's fast path, and elision for stores into objects known young; re-measure
  Richards.
- **262.3** Hidden visibility for runtime calls.
- **262.4** Heap sizing that weighs trace work or targets a share of time in the collector.
- **262.5** The GenImmix-only items (promotion, large objects and minors, the unmark walk, the minor's
  second pass), weighed against how soon LXR replaces them before any is built.
- **262.6** Parallel or concurrent marking, with LXR's design.

## Refs

`runtime/descriptors.nomu` (`rtOffsetsInto`, `rtOffsetListed`), `runtime/collect.nomu`, `runtime/immix.nomu`
(heap sizing), `llvmgen/LLVMGenRuntime.swift` (`nomuWriteBarrier`, `nomuRememberBarrier`); the benchmarks in
`practice/` (gitignored): `binary_trees`, `gen/richards`, `go/richards`, `gen/enum260/*`.
