# LXR collector (footprint endgame)

**Avenue:** Risk (the footprint endgame) · **Type/Lifecycle:** `perf · evaluate` · **Size:** XL ·
**Status:** final rung of the self-hosted GC ladder — after 150's GenImmix ·
**Source:** `memory-model.md` §3 (LXR RC-hybrid endgame)

## What

An *owned* RC-hybrid reimplementation behind the same `VMBinding` and reusing the
`__nomu_write_barrier` seam, beside today's GenImmix. The footprint endgame — a moving
collector at near-live-set footprint is the performance thesis; LXR pushes footprint further via
reference counting hybridized with tracing.

## Sequencing

**The final rung of the self-hosted GC ladder** ([150](150-selfhosted-gc-ladder.md)), reached once
self-hosted GenImmix is solid. It is the algorithm change (GenImmix → RC-hybrid) that happens *inside*
the Nomu runtime after the self-hosting location change is done — the fold with self-hosting is decided
(it is part of it), and the prior "gated on a benchmark-scale stdlib" gate is dropped. LXR uses Immix as
its backing, so the region/line machinery built for the non-generational Immix rung carries in; the new
work is the reclamation policy (RC-primary + backup tracing).

**The ladder doubles as the decision.** Real footprint/throughput numbers for self-hosted Immix and
GenImmix tell us whether LXR's extra complexity earns its keep. LXR stays the intended endgame; the
comparison confirms it. An earlier plan targeted LXR after the debugger against mainline GenImmix as the
shipped collector — superseded: GenImmix is now a rung in the self-hosted ladder, and LXR follows it in
Nomu.

## Several collectors, one default

LXR is the intended endgame on the condition that it proves fastest for Nomu. It was designed and
productionized on the JVM, and Nomu's compiler, runtime and object model differ, so it may not work out here.
Until it does, the goal is GenImmix as fast as it can be ([262](262-collector-gaps.md)).

Nomu holds several collectors indefinitely, selectable through `gc.plan`: they are compared on larger programs
that do real work, and that comparison keeps running. It picks the default; it does not retire the others.
Holding them must be zero-cost: no binary size or run time cost to a program that does not select
one. Today a plan not selected still costs binary size, because unused functions with safepoints survive dead stripping
([158.7](158-gc-packaging.md), [229](229-dead-strip-safepoint-code.md)).

## Dependencies

- **Follows:** [150 self-hosted GC ladder](150-selfhosted-gc-ladder.md) through its GenImmix rung.
- **Rests on:** [125 unsafe raw memory](125-unsafe-raw-memory.md) + [149 runtime-subset](149-runtime-subset.md)
  (shared with the whole self-hosted runtime) and a clean `VMBinding` + the `__nomu_write_barrier` hook.

## To explore: types that cannot form cycles

Reference counting reclaims everything but cycles, which LXR leaves to its backup trace. A type whose instances
can never be part of a cycle could tell the collector so, as Koka's inductive immutable data does (Perceus,
MSR-TR-2020-42, §2.7.4) and as Bacon and Rajan's cycle collector uses for "green" objects that never become
cycle candidates.

- **The rule, inferred by the compiler:** value types and primitives are acyclic. A class is acyclic when its
  reference fields are all `let`, each field's type is acyclic, and its initializer does not hand out `self`
  before construction ends: closing a cycle needs some object to point to one created after it, which takes a
  mutation. Recursive immutable types (a list, a tree) are acyclic. An array buffer is acyclic when its element
  type cannot reach it. Generics are conditional (`Box<T>` is acyclic when `T` is). This is nearly the
  structural derivation of shareable deeply-immutable classes (`concurrency.md` §5), so the check can share
  its code.
- **Where it lives:** one bit in the type descriptor (`runtime/descriptors.nomu`, beside `kind` at offset 8). It
  is a property of the type, the collector already reads the descriptor for each object it scans, and the
  header's spare bits are for per-object state (the mark and log bits).
- **Open:** what it buys LXR. With trial deletion the win is known; with LXR's backup trace it might let the trace
  skip acyclic subgraphs or run less often. Check against the LXR paper before adding the bit.

**Re-measure:** once this lands, re-run the dense-layout benchmark against Go (`practice/gen/dense/run.py`, `practice/go/dense`; [196](196-dense-value-layout.md) 196.9) for the object ring's collector time and memory.

## Refs

`memory-model.md` §3 (object model / `VMBinding`); `backend.md`
(barrier seam); [self-hosting](128-self-hosting-runtime.md).
