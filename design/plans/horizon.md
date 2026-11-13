# Near-horizon — the active epics

Each goal is an **epic** drawn as a dependency tree: the **end goal is the root**, and each node's children
are its open prerequisites. Work **leaves-first** — a leaf is ready to start, `◀ next` marks the next
action, and the root is what it all adds up to. Siblings are independent of each other; a coupling that is
not a hard prerequisite is noted inline. Identity numbers point into [`tasks.md`](tasks.md), which carries the
detail and status; this doc carries only the goals and their order. Everything not on an epic here is
parallel/cheap work tracked in `tasks.md`.

Two epics are live. **Epic A (self-hosted GC + runtime) is the active priority.** The runtime is the Nomu
scheduler and collector over the asm floor (context switch and fiber init). The **modules build-out** sits beneath the benchmark, which needs
programs large enough to be meaningful and the perf-affecting module capabilities real: build graph granularity
for dev-productivity, then the perf-relevant capabilities (cross-module generics residuals, cross-module
inlining). The benchmark against Go and Swift sits above that, when the language is complete, with fiber
stacks (104) and heap sizing (230) ready before any collector is measured.
Epic B (strings) has only independent follow-ons left.

---

## Epic A — Self-hosted GC + runtime

**End goal:** a hand-rolled [LXR](tasks/127-lxr-collector.md) collector running inside a runtime — GC and
scheduler — written in Nomu itself ([128](tasks/128-self-hosting-runtime.md)): no Rust/MMTk/C, a tiny
binary whose runtime inlines into user code through the same backend. The differentiator behind "faster
and smaller than Go and Swift."

**Order rule:** self-hosting is a *location* change (MMTk/Rust → Nomu); LXR is an *algorithm* change
(GenImmix → RC-hybrid). Hold the algorithm constant while moving location, then hold location constant
while changing the algorithm — so the two unknowns never multiply. The location change is done on GenImmix:
no C remains under the runtime. (223's blocker 6, the asm floor moving into the runtime's object, serves only
[192](tasks/192-bazel-friendliness.md), off this chain.)

```
127  LXR — RC-primary reclamation, on Immix backing; then the GenImmix–LXR comparison   ◀ end goal
└── benchmark against Go and Swift, on GenImmix (when the language is complete)
    ├── 246  raw pointers into managed memory held across safepoints — done (246.2 recorded with their base)
    ├── 104  fiber stack strategy — done: Go-style copying stacks; growth 2.5–3× faster than Go's
    │   └── 250  fiber and task surface — done (`fiber`, `task`, `select`, dumps and leaks, a 128-byte record); `task` in compiled-once generic bodies is 251.2.4, the switch follow-ups 254.4
    │       ├── 102  channels — done
    │       └── 251  generic classes in compiled-once bodies — done but 251.2.4 (closures, fibers; `task` there waits on it)
    ├── 194  GC frame metadata — decided: extended statepoints (epic: 239–244, 247)
    │   └── 247  frame table — F2, built at link time
    ├── 235  scheduler run queues — per-carrier queues in place of one lock — done (235.1–235.6)
    ├── 254  scheduler performance — the gaps 235 left: wake churn, the one-carrier cost, fan-in across carriers
    │   │    250 and 104, which it waited on, are done; 254.5 from 104.5
    │   ├── 236  fiber preemption — take a carrier back from a computing fiber
    │   │        couples with 104 (the entry check)
    │   └── 237  handoff primitives — a direct switch, handoffs marked by the compiler (needs design; syntax or API to agree)
    ├── 245  loop strip mining — polls out of the loops the optimizer sees (29% on array loops)
    ├── 230  heap sizing — a heap that grows, a clean out-of-memory      (before any GC is measured)  ◀ next
    ├── 182  cross-module inlining & inlinable stdlib                    (perf-accuracy)
    │        complements 179 (value-level GC classification)
    ├── 253  finish generics — owns 171's residuals and 251's remainder, with 170 and 118 to design  (perf-accuracy)
    └── 217  build graph granularity — sliced keys, scheduler (staged jobs deferred)  (dev-productivity)
```

**Where we are:** [104](tasks/104-fiber-stack-strategy.md) (fiber stacks) and [250](tasks/250-fiber-task-surface.md)
(the fiber and task surface) are done. 104.5 measured stacks against Go: growth is now 2.5 to 3 times faster, a
spawn costs the same on one carrier, and the gaps it found in the scheduler (fibers left queued on a busy
carrier, spawn cost on several carriers) went to [254](tasks/254-scheduler-performance.md). Its policies
(growth, starting sizes, shrinking, pool sizes) wait in [258](tasks/258-runtime-policy-tuning.md) for real
programs to tune against, and its libc-or-own choices in [259](tasks/259-libc-or-own-per-routine.md).
[230](tasks/230-heap-sizing.md) (heap sizing) is next, the other prerequisite before any collector is
measured. [235](tasks/235-scheduler-run-queues.md) (per-carrier run queues, actors on the run queues with
lock-free mailboxes) is done; its leftovers are [254](tasks/254-scheduler-performance.md), which comes after 236
and 237 because they change the paths it tunes.

**Order of the next run:** [234](tasks/234-scheduler-wake-and-pool.md) (the scheduler's wakes, found by 104's
baseline) is done; [194](tasks/194-gc-frame-metadata.md) is decided (extended statepoints: LLVM's stack
maps kept, possibly-stack pointers tracked, a link-time frame table, [247](tasks/247-frame-table.md)); [246](tasks/246-raw-pointers-into-managed-memory.md).1 fixed `String.eq`/`lt` and 246.2 closed the class (raw
pointers recorded with their base); [104](tasks/104-fiber-stack-strategy.md) is done (fiber stacks: small stacks copied on growth, as Go's;
overflow past the limit reports through [219](tasks/219-runtime-fault-handling.md)); next
[230](tasks/230-heap-sizing.md) (heap sizing: growth and a clean out-of-memory), all before any collector is
measured, so the benchmarks run on large, fiber-heavy programs. [236](tasks/236-fiber-preemption.md) (preemption) and
[237](tasks/237-handoff-primitives.md) (handoff primitives), found by 234's workloads, then
[254](tasks/254-scheduler-performance.md) (235's leftovers), come before the benchmark against Go and Swift;
236 couples with 104's entry check. 230 is what lets a benchmark's live data
exceed 256 MiB: binary-trees at the standard depth 21 crashes today. [217](tasks/217-build-graph-granularity.md)'s
remaining design (the slice's closure, the header format and hash, per-declaration keys on direct dependencies)
is paused. Off this chain: [204](tasks/204-yaml-parser-upgrades.md) (YAML parser upgrades),
[205](tasks/205-config-upgrades.md) (configuration upgrades), and 176.4 (the escape-promotion placement route)
with [148](tasks/148-ssair-optimizer-tier.md) / [179](tasks/179-value-level-gc-classification.md).

**What the benchmark needs from the language.** The goal is a language complete enough to benchmark against
Go and Swift, with results that reflect the language, compiler, scheduling and memory as designed, and not
gaps in them. Collecting legs on the Nomu collector (allocation stress, small nurseries) and
the collection counts the suite reads from the collector report carry the GC cross-check. **The modules build-out sits on the LXR chain** because its
purpose is a meaningful benchmark. It gates the benchmark two
ways:

- **Dev-productivity** — [217](tasks/217-build-graph-granularity.md) (keys over what a compile reads, a
  scheduler). It makes building and iterating large programs bearable.
- **Perf-accuracy** — [171](tasks/171-modules-cleanup.md) (cross-module generics residuals, now tracked by [253](tasks/253-finish-generics.md)) and
  [182](tasks/182-cross-module-inlining.md) (cross-module inlining + inlinable stdlib). They change
  performance enough that a benchmark taken before them would mislead.

Remote-workspace builds, [189](tasks/189-multi-remote-workspace-builds.md) (registries, version resolution,
lockfile), stay off the chain as the last packaging rung; the benchmark does not need them.

---

## Epic B — Production-grade strings

**End goal:** a real stdlib [`String`](tasks/121-string-utf8-model.md) — UTF-8, value semantics,
small-string optimization, zero-copy literals — retiring the leaking C-primitive builtin. A hand-rolled
16-byte bit-stealing struct with 15-byte SSO and a moving heap buffer.

What remains extends 121's `String`; none of it blocks anything else:

```
String follow-ons
├── 185  Substring — zero-copy span (design decided)
│        couples with 184, 183, 117
├── 184  Unicode views — scalar / grapheme / normalization
│        couples with 117; serves 163
├── 183  precondition + bounds-check insertion — the checked String.byte(at:)
│        complements 117
├── 117  for … in iteration
│   └── 120  stdlib core — iterator/sequence interface, String↔Array<UInt8> interop
│       └── 115  error handling — the Result-returning I/O half of 120
├── 123  copy-on-write — StringBuilder mutation path + COW elision
└── 163  manifest/YAML parser (the motivating consumer)
```

Task docs: [185](tasks/185-substring.md), [184](tasks/184-string-unicode-views.md),
[183](tasks/183-precondition-bounds-checks.md), [117](tasks/117-for-in-iteration.md),
[120](tasks/120-stdlib-core.md), [115](tasks/115-error-handling.md), [123](tasks/123-copy-on-write.md),
[163](tasks/163-manifest-yaml.md).
