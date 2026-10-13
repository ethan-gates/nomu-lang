# Near-horizon — the active epics

Each goal is an **epic** drawn as a dependency stack: the **end goal sits at the top**, and each item
below it is a prerequisite of the one above. Work **bottom-up** — the bottom item is the next action, the
top is what it all adds up to. Identity numbers point into [`tasks.md`](tasks.md), which carries the
detail and status; this doc carries only the goals and their order. Everything not on an epic here is
parallel/cheap work tracked in `tasks.md`.

Two epics are live. The strings epic (B) has landed its core — the byte-level `String` and its shaped-GC
substrate are built and green — so its remaining items are independent follow-ons. **Epic A (self-hosted
GC + runtime) is the active priority:** its whole lower stack is built — the self-hosted scheduler, the
Immix and GenImmix collectors, modules, and the test harness — so the nearest action is the perf-benchmark
run-up against MMTk (paired with 158/159) that gates retiring MMTk and starting LXR.

---

## Epic A — Self-hosted GC + runtime

**End goal:** a hand-rolled [LXR](tasks/127-lxr-collector.md) collector running inside a runtime — GC and
scheduler — written in Nomu itself ([128](tasks/128-self-hosting-runtime.md)): no Rust/MMTk/C, a tiny
binary whose runtime inlines into user code through the same backend. The differentiator behind "faster
and smaller than Go and Swift."

**Order rule:** self-hosting is a *location* change (MMTk/Rust → Nomu); LXR is an *algorithm* change
(GenImmix → RC-hybrid). Hold the algorithm constant while moving location, then hold location constant
while changing the algorithm — so the two unknowns never multiply.

```
   127    LXR — RC-primary reclamation, on Immix backing              ◀ end goal
    ▲ requires
   —      retire MMTk (kept live as the baseline until here)
   158/159 GC packaging + observability (needs-design; the benchmark run-up)
   150.*  perf-benchmark GenImmix vs MMTk                             ◀ next
   ─────────────── everything below is built + green ───────────────
   150.4  GenImmix — nursery + write barrier + remembered set         ✔
   128.3  full-runtime STW root-scanning over the self-hosted carriers ✔
   128.1/.2 scheduler self-host + bootstrap asm floor (NOMU_SCHED=nomu) ✔
   150.3  Immix — evacuation + pointer fixup                          ✔
   100    modules — separate compilation + witness baseline (100.5 dial left) ✔
   155    test harness — the feedback loop for everything above        ✔
   149    runtime-subset mechanism (slice 1)                           ✔
```

MMTk/GenImmix exists as the reference implementation each rung diffs against, which is what makes the
incremental self-host tractable — and why MMTk stays live until the benchmark confirms the self-hosted
collector before retirement. Two self-hosting-infra items branch off the modules rung and don't sit on
the LXR chain: [174](tasks/174-prelude-as-packages.md) (prelude-as-packages — its three prerequisites are
done, so it is the goal they were gating; couples with [149](tasks/149-runtime-subset.md) runtime-subset
by module membership) and the **packaging sub-stack** off [173](tasks/173-package-model-driver-cli.md)
(package model + the single-binary `nomu` driver — `compile`/`build`/`run`/`test`/`query`, **built**). Its
cross-package concerns landed in [187](tasks/187-multi-package-builds.md) — **multi-package builds within one
workspace, built and green** (graph spans packages, workspace-relative mangling identity, the package
dependency DAG, and the full `products`/`package`-tier/`public`⟺product visibility boundary). The
external-workspace continuation is deferred to its own rungs: [188](tasks/188-multi-local-workspace-builds.md)
(cross-workspace linkage by local path — sidesteps dependency management) then
[189](tasks/189-multi-remote-workspace-builds.md) (registries + version/dependency resolution + lockfile —
the last rung).

---

## Epic B — Production-grade strings

**End goal:** a real stdlib [`String`](tasks/121-string-utf8-model.md) — UTF-8, value semantics,
small-string optimization, zero-copy literals — retiring the leaking C-primitive builtin. A hand-rolled
16-byte bit-stealing struct with 15-byte SSO and a moving heap buffer.

```
   121    String — the bit-stealing stdlib type; retires the builtin   ✔ done (121.1 + 121.2 SSO)
    ▲ requires
   176    shaped GC roots — value-conditional scanning + relocation takeover   ✔ done (176.1–176.3)
```

**Core landed + green.** 176 delivered the value-conditional scanning the bit-stealing word needs, and
121 built the byte-level `String` on top: a Nomu value type off the C floor, with SSO and a moving heap
buffer. The same shaped-root mechanism also cleared the addrspace-across-calls wall for interprocedural
stack promotion ([148 §148.1](tasks/148-ssair-optimizer-tier.md)), so 176 paid off beyond strings.

**Follow-ons** — each its own task, none blocking, pull as a consumer lands:

- [123](tasks/123-copy-on-write.md) — compiler-inferred copy-on-write (a `StringBuilder` mutation path +
  value-semantics COW elision); the general value-semantics effort the first mutation path motivates.
- [185](tasks/185-substring.md) — zero-copy `Substring` span (GC-backed, design decided).
- [184](tasks/184-string-unicode-views.md) — Unicode views (scalar / grapheme / normalization); couples
  with [117 `for … in`](tasks/117-for-in-iteration.md).
- [183](tasks/183-precondition-bounds-checks.md) — `precondition` primitive + bounds-check insertion, the
  checked form of `String.byte(at:)`.
- [120](tasks/120-stdlib-core.md) — `String`↔`Array<UInt8>` interop.
- [163](tasks/163-manifest-yaml.md) — the hand-written manifest/YAML parser that motivated the epic.
