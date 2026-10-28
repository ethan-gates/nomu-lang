# Near-horizon — the active epics

Each goal is an **epic** drawn as a dependency tree: the **end goal is the root**, and each node's children
are its open prerequisites. Work **leaves-first** — a leaf is ready to start, `◀ next` marks the next
action, and the root is what it all adds up to. Siblings are independent of each other; a coupling that is
not a hard prerequisite is noted inline. Identity numbers point into [`tasks.md`](tasks.md), which carries the
detail and status; this doc carries only the goals and their order. Everything not on an epic here is
parallel/cheap work tracked in `tasks.md`.

Two epics are live. **Epic A (self-hosted GC + runtime) is the active priority.** MMTk and the C scheduler
are retired ([197](tasks/197-retire-mmtk-and-c-scheduler.md)): one runtime, the Nomu scheduler and collector.
The GC-correctness run ([176](tasks/176-shaped-gc-roots.md) 176.5) and the link-time GC frame index
([195](tasks/195-link-time-gc-frame-index.md)) are done; next is the **modules build-out** beneath the benchmark, which needs programs large enough to be meaningful and the
perf-affecting module capabilities real: dev-productivity first (explicit module builds, then the build
cache), then the perf-relevant capabilities (cross-module generics residuals, cross-module inlining). The
benchmark against Go and Swift (with 158/159) sits above that, when the language is complete.
Epic B (strings) has only independent follow-ons left.

---

## Epic A — Self-hosted GC + runtime

**End goal:** a hand-rolled [LXR](tasks/127-lxr-collector.md) collector running inside a runtime — GC and
scheduler — written in Nomu itself ([128](tasks/128-self-hosting-runtime.md)): no Rust/MMTk/C, a tiny
binary whose runtime inlines into user code through the same backend. The differentiator behind "faster
and smaller than Go and Swift."

**Order rule:** self-hosting is a *location* change (MMTk/Rust → Nomu); LXR is an *algorithm* change
(GenImmix → RC-hybrid). Hold the algorithm constant while moving location, then hold location constant
while changing the algorithm — so the two unknowns never multiply. The location change is complete: 197
retired MMTk, the Rust binding and the C scheduler, leaving the Nomu scheduler and collector over a small C
floor (`runtime.c`). LXR is the algorithm change that remains.

```
127  LXR — RC-primary reclamation, on Immix backing                         ◀ end goal
└── benchmark against Go and Swift (when the language is complete)
    └── 150  self-hosted GC ladder — GenImmix correctness-complete on the one runtime (197)
        ├── 158  GC packaging — self-contained plans behind one trigger protocol
        ├── 159  GC observability — collection tracing, stats, pause timing  ◀ next
        ├── 182  cross-module inlining & inlinable stdlib                    (perf-accuracy)
        │        complements 179 (value-level GC classification)
        ├── 171  modules cleanup — cross-module generics residuals           (perf-accuracy)
        │        interacts with 170 (method-level generics), 118 (associated types)
        ├── 203  symbol encoding — one injective mangling for every family   (correctness)  (done)
        └── 172  incremental build cache — content-addressed compiles and links (dev-productivity)  (done)
            ├── 206  compiler identity — commit plus uncommitted changes, baked in          (done)
            ├── 208  job keys — over everything a compile reads                            (done)
            ├── 209  content-addressed store — one store for every cached artifact         (done)
            ├── 207  build determinism — byte-identical outputs                            (done)
            ├── 210  workspace lock and build/ layout                                       (done)
            ├── 211  several root modules per build                                       (done)
            ├── 212  build-cache observability — what was cached and why                  (done)
            ├── 214  link caching — a cached link for an unchanged binary                  (done)
            └── 198  build configuration — modes, per-workspace settings, the cache-key input  (done)
```

**Order of the next run:** 172 and its prerequisites (206–212, 214) are done; next is 159 (198 and 203 are done). 172's keys are transitive and whole-file; narrowing them to what a compile reads, with interface and object actions and a scheduler, is [217](tasks/217-build-graph-granularity.md), after [202](tasks/202-one-inference-phase.md) (one lowering per module), off this chain. 190 (explicit module builds) and 200 (the
YAML parser, which 198's configuration files needed) are done; 200's open items are
[204](tasks/204-yaml-parser-upgrades.md), off this chain. 198 went ahead of 203 by choice; 203 is 190's
last correctness finding (a weak-symbol collision silently links the wrong definition) and follows it. 198 carries only what 172 needs; the rest of
the configuration story is [205](tasks/205-config-upgrades.md), off this chain. 198 precedes 172,
whose key takes the configuration's canonical form. GC correctness came before the modules work
(soundness is Nomu's first priority, `vision.md`). Retiring MMTk and the C scheduler (197) was moved ahead of
the rest of 176.5, so 176.5 was finished and tested against one runtime; 176.5 is done (176.5.1–176.5.8), and
195 is done (195.1–195.5), and 190 closed on them. 176.4 (the escape-promotion placement route) stays with
[148](tasks/148-ssair-optimizer-tier.md) / [179](tasks/179-value-level-gc-classification.md), off this chain.

**Off the chain, after 127:** [128.5](tasks/128-self-hosting-runtime.md) retires the C floor (`runtime.c`,
`core.c`) that remains under the Nomu runtime, the last step to the end goal's "no C". It is a location
change, so it follows LXR by the Order rule. Its blockers include FFI-like calls, C-ABI thread entries,
safepoint-free functions and runtime globals, some of which need language surface agreed first. A candidate
for its own task.

**What the benchmark needs from the language.** The goal is a language complete enough to benchmark against
Go and Swift, with results that reflect the language, compiler, scheduling and memory as designed, and not
gaps in them. MMTk retirement was decided without a GenImmix-vs-MMTk benchmark: it would only have measured
distance, and keeping a second runtime doubled every GC change ([197](tasks/197-retire-mmtk-and-c-scheduler.md)).

MMTk/GenImmix was the reference implementation each self-hosting rung diffed against; with the self-hosted
runtime passing the suite on its own, 197 removed it. Collecting legs on the Nomu collector (allocation
stress, small nurseries) and [159](tasks/159-gc-observability.md)'s correctness matrix carry the cross-check. **The modules build-out sits on the LXR chain** because its
purpose is a meaningful benchmark. It gates the benchmark two
ways:

- **Dev-productivity** — [190](tasks/190-explicit-module-builds.md) (explicit module builds: one planned
  graph, each module compiled once; done), then [172](tasks/172-incremental-build-cache.md) (the content-addressed
  module-granular cache, keyed on 190's jobs). These make building and iterating large programs bearable.
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

The end goal is met (121's `String` is built). What remains extends it; none of it blocks anything else:

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
