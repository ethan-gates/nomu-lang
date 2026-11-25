# Runtime policy tuning against real programs

**Avenue:** Risk · **Type/Lifecycle:** `perf · runtime · parked` · **Size:** M · **Status:** parked ·
**Source:** 104.5, whose policy items need workloads that do not exist yet.

## Why

Some runtime choices are policies: a number or a rule picked to balance memory against time. Their right
values depend on what programs do, and microbenchmarks only reward whatever they happen to exercise. Nomu has
no large programs yet, so these stay at simple defaults until there are programs to tune against.

Mechanism costs (what a spawn, a stack move or a check costs) stay with the tasks that own the mechanism,
since microbenchmarks measure them directly.

## Un-park trigger

Programs large and varied enough to tune against: the benchmark against Go and Swift with its programs written,
or the first real Nomu programs. The collector should be the one being benchmarked (GenImmix, or LXR after
[127](127-lxr-collector.md)), since its pauses and major-collection rate move the stack policies.

## Items

- **258.1 Stack growth.** Today a stack doubles when it grows. Measure growths, bytes copied and peak stack
  memory per program; try other factors.
- **258.2 Starting sizes.** Today every fiber starts at the minimum (`NOMU_STACK_START`, 2 KiB). Candidates:
  - one global start size from the average stack use seen at scans, as Go does since 1.19;
  - a size per spawn site, from the sizes its fibers grew to;
  - the minimum, as now.
  The tradeoff is memory held by small fibers against grow-copies in deep ones.
- **258.3 Shrinking.** Today a stack using under a quarter of its size is halved at each major collection
  (104.4). Tune the threshold, the step and when it runs (majors only, or also minors past some age).
- **258.4 Pool sizes.** Today each carrier keeps up to 64 fiber records and 64 stacks per size class (2 to
  64 KiB), moves batches of 32 to and from a shared pool with no cap, and every pool empties at a major
  collection (104.5.4; Go's numbers for dead goroutines). A program that spawns a burst and then idles without
  a major keeps the burst's records and stacks. Tune the caps, the largest pooled class, and whether the shared
  pool should also shrink on a timer.

- **258.5 Heap growth.** [230](230-heap-sizing.md) sets the heap's soft limit to live + (live + stacks) × r
  after each major, r = 1 (`NOMU_GC_PERCENT`). Tune r's default, and try timing-based rules (a collection-time target,
  MemBalancer's square-root rule) against it.
- **258.6 Behaviour near the heap maximum.** In 230 a program near `NOMU_HEAP_MAX` collects ever more often
  until a major frees nothing, then fails. Candidates:
  - fail early when collection overhead stays high, as the JVM's overhead limit does (98% of time collecting,
    under 2% recovered);
  - a soft limit below the maximum that the policy collects harder to stay under, with a cap on collection
    CPU past which the heap exceeds it, as Go's `GOMEMLIMIT` does.

- **258.7 The slot's steal age.** A searcher takes the fiber in another carrier's slot once that carrier has gone
  `NOMU_SLOT_STEAL_NS` without a switch (`rtSlotAged`, [237](237-handoff-primitives.md).4); 3 µs, Go's. A direct
  handoff parks within tens of ns, so 1 µs is the candidate: on 237.4's runs it took `producer_fiber`'s stranded wait
  from 8 / 12–14 to 7 / 10–12 µs (p50 / p99) and `stream_channel`'s CPU on 8 carriers from 831 to 435 ms, with
  ping-pong unchanged. What it would cost is unmeasured: a readier that works 1–3 µs after readying, then parks,
  would lose the fiber to another carrier, splitting the pair across cores. Measure on a workload of that shape
  (work of 0.5 to 5 µs between readying and parking) and on server workloads once networking
  ([255](255-networking.md)) exists, where such readiers are common.

Other runtime policies join this task when their owners reach the point of tuning on workloads.

## Relations

- [104](104-fiber-stack-strategy.md) owns the stack mechanisms these policies drive.
- [254](254-scheduler-performance.md): starting sizes change what a spawn costs.
- [265](265-compiler-dev-loop.md)'s A/B runner compares policy variants.
