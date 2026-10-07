# Near-horizon — the active epics

Each goal is an **epic** drawn as a dependency stack: the **end goal sits at the top**, and each item
below it is a prerequisite of the one above. Work **bottom-up** — the bottom item is the next action, the
top is what it all adds up to. Identity numbers point into [`tasks.md`](tasks.md), which carries the
detail and status; this doc carries only the goals and their order. Everything not on an epic here is
parallel/cheap work tracked in `tasks.md`.

Two epics are live. **[176](tasks/176-shaped-gc-roots.md) is the current highest priority** — the bottom
of the strings epic, and the nearest action on either.

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
   127    LXR — RC-primary reclamation, on Immix backing          ◀ end goal
    ▲ requires
   —      retire MMTk (kept live as the baseline until here)
   158/159 GC benchmarking + packaging, both plans live
   100    modules (proven surface; unblocks stdlib + prelude emission)
   155    test harness (the feedback loop for everything above)
   150.4  GenImmix — nursery + write barrier + remembered set
   128.1  scheduler self-host + bootstrap assembly floor
          (interleaved here: GenImmix's STW reads every carrier's safepoint context,
           and the generational barrier co-designs with the mutator path)
   150.3  Immix — evacuation + pointer fixup (150.3.7); 150.3.1–.6 built   ◀ next
```

MMTk/GenImmix already exists as the reference implementation each rung diffs against, which is what makes
the incremental self-host tractable.

---

## Epic B — Production-grade strings

**End goal:** a real stdlib [`String`](tasks/121-string-utf8-model.md) — UTF-8, value semantics,
small-string optimization, zero-copy literals — retiring the leaking C-primitive builtin. A hand-rolled
16-byte bit-stealing struct with 15-byte SSO and a moving heap buffer.

```
   121    String — the bit-stealing stdlib type; retires the builtin   ◀ end goal
    ▲ requires
   176    shaped GC roots — value-conditional scanning + relocation takeover
          (decouples rooting/placement from addrspace(1); the enabler the bit-stealing word needs)  ◀ next
```

The 121.1 immortal+heap interim (where the pointer word is uniformly a managed-or-null buffer pointer)
rides the existing GC and can precede 176; 176 gates the bit-stealing `small`/SSO case. **Unblocks:**
compiler-inferred COW ([123](tasks/123-copy-on-write.md)) and the hand-written manifest/YAML parser
([163](tasks/163-manifest-yaml.md)), which motivated the epic. The same shaped-root mechanism also clears
the addrspace-across-calls wall for interprocedural stack promotion
([148 §148.1](tasks/148-ssair-optimizer-tier.md)), so 176 pays off beyond strings.
