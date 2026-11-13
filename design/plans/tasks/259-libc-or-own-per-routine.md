# Libc or our own, per routine

**Avenue:** Risk · **Type/Lifecycle:** `perf · runtime · parked` · **Size:** M · **Status:** parked ·
**Source:** 104.5.5, which wrote Nomu's own memory loops and left the comparison with embedded tuned routines
for later.

## Why

[104](104-fiber-stack-strategy.md)'s libc rule ("Libc or Nomu's own, per routine: decided by performance")
picks, per routine and per platform, whichever implementation is faster on workloads. libc runs only on the
carrier's stack, behind a switch of about 0.5 ns a call. 104 settled the routines the stacks needed; this
task holds the choices left open.

## Un-park trigger

When the libc-dependent routines are taken up as a group: a port that needs them anew
([218](218-linux-support.md)), or a benchmark where one of them shows.

## Items

- **259.1 Arm's optimized-routines against ours.** Today `memcpy`/`memmove` and `memset` run Nomu's own
  64-byte loops to 4096 bytes and switch to libSystem past that; `memcmp` runs Nomu's own 32-byte vector loop
  at every size (`rtasm_arm64.s`, 104.5.5). Measure Arm's optimized-routines (MIT, or Apache-2.0 with the LLVM
  exception) against both with `practice/memsize`'s sweep and `mem_routines`, `frames_strings`, `binary_tree`.
  Expected: about equal to ours below 4 KiB; possibly ahead past it, where its `memset` zeroes with `DC ZVA`
  and its copy aligns the destination, which would let large sizes skip the switch. Embedding brings a
  third-party license into the repository; deciding that is part of this item.
- **259.2 `DC ZVA` in our fill.** The cheaper half of 259.1's large-size gain: zero whole cache lines in our
  own `memset` loop, and measure where it overtakes libSystem's at 64 KiB and up (libSystem fills about twice
  as fast as our loop there today).
- **259.3 Other architectures.** The memory routines are arm64 assembly. An x86-64 port
  ([218](218-linux-support.md)) needs its own versions or libc's behind the switch, chosen by the same rule.

- **259.4 The clock** (from 104.5.6). `Runtime.ticks()` and `Runtime.monotonicNanos()` call
  `mach_absolute_time` and `clock_gettime_nsec_np` through the platform layer's stubs. A direct counter read
  (`cntvct_el0`) costs about 0.25 ns inline, but it is unordered: [254](254-scheduler-performance.md) 254.3
  found it reading up to 5 µs behind a value another thread published, which broke the run-queue slot's
  aging; a direct call of `mach_absolute_time` restored it. Measure each on `sleepers_fiber`, the timer paths
  and 254's slot aging, with the ordering a reader needs (`isb`, or `cntvctss_el0` where present). 254.1 and
  254.3 want the result.

## Relations

- [104](104-fiber-stack-strategy.md): the libc rule, the platform layer and the stack switch.
- [227](227-double-formatting-in-nomu.md): number formatting and parsing, the other routines the rule
  expects Nomu to own.
- [218](218-linux-support.md): on Linux, system calls can be made without libc, as Go does.
