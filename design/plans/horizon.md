# Near-horizon — the active epics

Each goal is an **epic** drawn as a dependency tree: the **end goal is the root**, and each node's children
are its open prerequisites. Work **leaves-first** — a leaf is ready to start, `◀ next` marks the next
action, and the root is what it all adds up to. Siblings are independent of each other; a coupling that is
not a hard prerequisite is noted inline. Identity numbers point into [`tasks.md`](tasks.md), which carries the
detail and status; this doc carries only the goals and their order. Everything not on an epic here is
parallel/cheap work tracked in `tasks.md`.

Two epics are live. **Epic A (self-hosted GC + runtime) is the active priority.** The runtime is the Nomu
scheduler and collector over a small C floor. The **modules build-out** sits beneath the benchmark, which needs
programs large enough to be meaningful and the perf-affecting module capabilities real: build graph granularity
for dev-productivity, then the perf-relevant capabilities (cross-module generics residuals, cross-module
inlining). The benchmark against Go and Swift sits above that, when the language is complete, with the GC
packaging (158) and fiber stacks (104) ready before any collector is measured.
Epic B (strings) has only independent follow-ons left.

---

## Epic A — Self-hosted GC + runtime

**End goal:** a hand-rolled [LXR](tasks/127-lxr-collector.md) collector running inside a runtime — GC and
scheduler — written in Nomu itself ([128](tasks/128-self-hosting-runtime.md)): no Rust/MMTk/C, a tiny
binary whose runtime inlines into user code through the same backend. The differentiator behind "faster
and smaller than Go and Swift."

**Order rule:** self-hosting is a *location* change (MMTk/Rust → Nomu); LXR is an *algorithm* change
(GenImmix → RC-hybrid). Hold the algorithm constant while moving location, then hold location constant
while changing the algorithm — so the two unknowns never multiply. The C floor's retirement (223) is the location change that
remains, done on GenImmix before LXR: LXR is then built and compared on a runtime with no C under it, and
new runtime work stops choosing between growing the C and adding edges to it.

```
127  LXR — RC-primary reclamation, on Immix backing; then the GenImmix–LXR comparison   ◀ end goal
└── benchmark against Go and Swift, on GenImmix (when the language is complete)
    ├── 223  retire the C floor, from the floor up                         ◀ next
    │   ├── 224  globals — module-private top-level `let` (223.1 needs 224.1–224.3)
    │   ├── 226  collector work buffers that overflow silently — made growable  (built)
    │   └── 159.6  GC observability's `full` level — fast-path allocation counters  (after 226)
    ├── 158  GC packaging — self-contained plans behind one trigger protocol  (223.5 with it)
    ├── 104  fiber stack strategy — guard page, lazy commit, growth       (before any GC is measured)
    │   └── 219  runtime fault handling — one signal handler, reporters
    ├── 182  cross-module inlining & inlinable stdlib                    (perf-accuracy)
    │        complements 179 (value-level GC classification)
    ├── 171  modules cleanup — cross-module generics residuals           (perf-accuracy)
    │        interacts with 170 (method-level generics), 118 (associated types)
    └── 217  build graph granularity — sliced keys, scheduler (staged jobs deferred)  (dev-productivity)
```

**Order of the next run:** [223](tasks/223-retire-the-c-floor.md) next, from the floor up: 223.1 (the floor: the `Runtime` namespace, globals, the carrier-local slot, raw memory) and 223.2 (carrier state and the allocation fast path in Nomu), then [226](tasks/226-collector-buffer-overflow.md) (the collector's root, remembered-set and mark buffers drop or overrun past a fixed size; a correctness fix). 223 continues as far as it goes before anything else: 223.3 (the forwarders, emitted by codegen), 223.4 (GC metadata), 223.5 short of the coordinator threads (`main`, line input and its poller), and 223.6 (the remainder). Then 159.6 (the `full` level: allocation counted on the fast path, for survival and allocation rates). [158](tasks/158-gc-packaging.md) follows, debugged with [159](tasks/159-gc-observability.md)'s collector report; 223.5 moves the coordinator threads with it. [104](tasks/104-fiber-stack-strategy.md) (fiber stacks: overflow detection, lazy commit, growth) and its
prerequisite [219](tasks/219-runtime-fault-handling.md) (fault handling) come before any collector is
measured, so the benchmarks run on large, fiber-heavy programs. 158 is what remains of the GC ladder
([150](tasks/150-selfhosted-gc-ladder.md)). [217](tasks/217-build-graph-granularity.md)'s
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
- **Perf-accuracy** — [171](tasks/171-modules-cleanup.md) (cross-module generics residuals) and
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
