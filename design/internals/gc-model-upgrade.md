# GC Model Upgrade — the `(region, shape)` root model

**Status:** design in progress — the spine (`(region, shape)` records + one shape language + one scanner) is
drafted and the case coverage checks out on paper; **soundness questions are open and gate commitment**
(see *Open questions*, P0). This doc synthesizes and is meant to become the governing model that
[`shaped-roots.md`](shaped-roots.md) (task 176), [`179`](../plans/tasks/179-value-level-gc-classification.md),
and the String work ([`121`](../plans/tasks/121-string-utf8-model.md)) are re-derived from. Grounds in
[`memory-model.md`](memory-model.md) §3/§6, [`selfhosted-gc.md`](selfhosted-gc.md) §9 (the root walk),
[`backend.md`](backend.md) §22 (the RS4GC pipeline), and the invariant set in [`ssair.md`](ssair.md) (I10).

## Why this doc exists

The GC root machinery grew case by case: `addrspace(1)` + RS4GC for ordinary pointers, object descriptors
for heap fields, a shaped-deopt bolt-on for `String`'s conditional word. Each new type shape (a `String`
field in a value struct, an `enum` with a `String` payload) has been exposing a fresh gap and inviting a
fresh point mechanism. This doc steps back to a single model so each capability is built once, general.

Four requirements drive it; they are treated as **invariants the GC must satisfy**, not goals:

1. **Full type composability.** Any combination of `struct`/`enum`/`class`/`actor`/closure/tuple holding any
   of the others as fields or payloads is correct, with no per-type compiler change.
2. **Minimal compiler magic.** Capabilities live behind a general mechanism that types *declare into*, not
   hardcoded per type. The shaped-value facility should eventually be stdlib-expressible. 180's
   `ManagedBuffer` (a real type, magic confined to a descriptor + intrinsics) is the template.
3. **Performance.** Scalar/stack promotion, register-resident pointers across calls, and the current LLVM
   optimization pipeline remain effective. The model must enable these, never block them.
4. **Generality.** Every capability is defined over the model's primitives, never specific to the feature
   being built.

## The model

> At each safepoint, every live root is a **`(memory region, shape)`** pair. A **shape** is the structural
> GC descriptor of a type — which byte offsets hold managed pointers, possibly keyed on a discriminant —
> computed by one generator and read by one scanner. The stack frame is a set of such regions, scanned by
> the same scanner that scans a heap object.

Three pieces, most of which already exist in part:

- **One shape language.** The structural descriptor: `kind 0` flat managed-offset list, `kind 1`
  variable-length buffer, `kind 2` discriminant-conditional (read a tag, select a case's offsets), with
  recursion into fields/payloads. Computed by one generator (`collectManagedOffsets` + the kind-2 emit),
  made *total* over the type algebra. Missing today: enum payloads, tuples, closures-as-fields, and nested
  `kind 2`.
- **One scanner.** Given `(region-base, shape-id)`, find and relocate every managed pointer in the region.
  This is the shaped-roots Stage 5 shared enumerator; the move is to drive **frame-region scanning** through
  it too, so a slot is scanned identically to a heap object.
- **Two record sources, one consumer.** Both land in `__llvm_stackmaps`, read by the one walker
  (`selfhosted-gc.md` §9, and the MMTk C walker):
  - **RS4GC** auto-emits records for register/spill-resident `addrspace(1)` SSA pointers; the shape is the
    trivial "this word is a pointer." Kept as the fast path for register-resident pointers.
  - **The compiler** emits `(region, shape-id)` records (via the deopt-operand channel the shaped path
    already uses) for everything materialized to memory: value-aggregate slots and shaped homes.

### Every case is an instance

| managed content | region | shape | status today |
|---|---|---|---|
| unconditional ptr, SSA (class ref) | its reg / spill slot | "word is a pointer" | ✓ RS4GC |
| unconditional ptr, heap field | the object | type descriptor | ✓ object scan |
| unconditional ptr, value-aggregate slot | the slot | aggregate descriptor | ✗ (refs forbidden in value types) |
| shaped word, SSA (bare `String`) | its home slot | `kind 2` | ✓ shaped-deopt |
| shaped word, heap field | the object | descriptor + `kind 2` entry | ✓ (`gc_string_field`) |
| shaped word, value-aggregate slot (`Pair`) | the slot | aggregate descriptor + `kind 2` field | ✗ (demonstrated broken across evac) |

### I10 becomes the routing rule

[I10](ssair.md) forbids a pointer-bearing first-class aggregate (FCA) from being a live SSA value across a
`gc.statepoint` (the LLVM statepoint limitation). Under this model that stops being a special constraint and
becomes the rule that routes between the two record sources: anything that would be such an FCA is instead
**materialized to a region and recorded with its shape**. Register-resident single pointers take the RS4GC
path; aggregates and conditional words take the region-record path. Scalar promotion still decomposes a
promotable aggregate into per-field SSA (riding RS4GC); the region-record path is the fallback for the
non-promotable and the shaped residue.

## Relationship to existing mechanisms and tasks

- **RS4GC / `addrspace(1)`** — the register fast path (record source A). Unchanged.
- **Object descriptors** (`memory-model.md` §6, `LLVMGenGCMaps`) — already the shape language for heap
  objects; the model extends the same descriptors to frame regions.
- **[176 shaped GC roots](../plans/tasks/176-shaped-gc-roots.md)** — the first cut of record source B and the
  shared scanner. 176.3 (frame-root placement) generalizes "region" from a `String` home to any slot. This
  model is 176 generalized from `String` to all `(region, shape)`.
- **[179 value-level GC classification](../plans/tasks/179-value-level-gc-classification.md)** — an
  *optimization* on record source A: widen what RS4GC roots so a conditional word can ride the register fast
  path and so promotion survives across calls, shrinking source B. Complementary; the model is correct
  without it (at a perf floor — see P1 below).
- **[180 managed buffer](../plans/tasks/180-managed-buffer.md) / `ManagedBuffer`** — the template for
  requirements 2 and 4: a real type whose magic is a descriptor + intrinsics.
- **The value-type-cannot-hold-a-reference restriction** lifts for free once source B covers slots (row 3
  above).

## Open questions / risks

Priority: **P0 = soundness, investigate first and commit-gating** (the model's failure mode is silent
relocation corruption, so these are settled with a testable contract before building); P1 =
architecture-affecting; P2 = performance / pipeline / extensibility.

### P0 — soundness (investigate first)

The model's correctness rests on a **volatile-reload + in-place-writeback contract**, and scaling from "one
`String` home" to "arbitrary regions and shapes" multiplies the places that contract must hold, each failure
silent and nondeterministic. Each item below should become an `In` invariant (checked by `verifySSAIR`) and a
`Tn` forced-GC obligation (differential script), not prose.

- **P0.1 — per-field volatile placement.** For a region with several managed fields read at many points,
  every post-safepoint managed read must be a `volatile` reload and every non-managed read should not. One
  wrong placement forwards a stale (pre-relocation) pointer. Investigate: can this be a mechanical rule over
  the shape (every load of a managed/shaped offset in a safepoint-reachable region is volatile), and is it
  verifiable?
- **P0.2 — partial-initialization window.** The "a zeroed/partially-live region scans safely" guarantee
  requires every materialized region to be zero-initialized before the first safepoint that can observe it,
  including mid-construction aggregates. Investigate: is there a safepoint-free guarantee from slot
  allocation to first zero-init, and does every shape's all-zero bit pattern decode to "no managed pointer"?
- **P0.3 — idempotent relocation under dual rooting.** The same object can be reachable from an
  RS4GC-tracked SSA pointer and a region record at the same safepoint; relocation must be idempotent
  (forwarding pointer). Confirm both collectors guarantee this and record it as a relied-on property.
- **P0.4 — interior / derived pointers must never silently span a safepoint.** The shape language roots
  *base* pointers at offsets; it does not express an interior pointer (a `RawPtr` into the middle of a
  buffer). Today the discipline is "use within a safepoint-free region." Investigate: can the compiler
  *enforce* that an un-rooted interior pointer never crosses a safepoint (a checkable invariant), rather than
  trusting discipline — and what does that enforcement cost? (Couples to P1.3 / `Substring`.)
- **P0.5 — two-collector lockstep as a contract.** Every shape-language feature must be implemented
  identically in MMTk (`gcbinding/lib.rs` + the C walker) and the self-hosted tracer's ~10 phase functions.
  The shared-enumerator decision is what contains this; confirm it holds for frame regions and nested shapes,
  and that the mark-verify / `*-evac` / `*-self` fingerprint oracles cover every new shape.

### P1 — architecture-affecting

- **P1.1 — runtime shape-ids for erased generics.** A monomorphized type has a constant shape-id; an erased
  generic (`Box<T>` via the VWT, `backend.md` §4) only knows its shape at runtime from the value-witness
  table. The Stage-4 spike recorded a *constant* shape-id in the deopt bundle. Does RS4GC thread a
  *non-constant* deopt operand, and can the walker read a dynamic shape-id? If not, shaped content inside
  erased generics has no root path. De-risk early — it is load-bearing for generic collections of shaped
  things.
- **P1.2 — region-recording vs. promotion ordering.** A slot whose address is recorded in a deopt bundle is
  pinned to memory (cannot be scalar-promoted). Recording slots conservatively would defeat promotion for the
  hot aggregates we care about. The model must record only the non-promotable residue and let promotion
  decompose the rest to per-field SSA first. Define the ordering (promote first, record the residue) as part
  of the model.
- **P1.3 — interior pointers / `Substring` representation.** A slice or `Substring` holding a pointer into a
  buffer is a derived pointer. Either the shape language grows a derived-entry kind (base at offset X), or
  slices are constrained to `(base pointer, integer offset)` so the stored pointer is always a base. Decide
  before building `Substring` (the String work heads toward it).
- **P1.4 — the RC / LXR endgame.** The project endgame is an LXR-style RC-hybrid moving collector
  ([127](../plans/tasks/127-lxr-collector.md)). The `(region, shape)` root model **transfers to LXR
  unchanged**: LXR uses *deferred* reference counting, so it enumerates stack/register roots at each
  collection exactly as a tracing collector does (a missed root is a premature free, the same failure class),
  and its Immix backup trace + evacuation reuse the same descriptor scanning and relocation fixup. The
  LXR-specific deltas land outside the root model: (a) a **coalescing-RC write barrier** (log an object's old
  referents so RC deltas can be computed — Levanoni–Petrank "unlogged bit" style), more demanding than the
  current generational barrier and with **different elision rules** (I7 is generational-specific); we already
  model the barrier as an explicit op with its own elision pass, and the self-hosted collector carries a
  log-bit barrier, so this is a swap of body + rules, not a new concept; (b) **RC accounting** is a *separate
  soundness axis* orthogonal to root liveness — every reference create/destroy must be accounted or counts
  drift into premature frees or leaks (silent); it is 127's job, not the root model's; (c) header room for the
  **refcount**, which [180](../plans/tasks/180-managed-buffer.md) already reserved for 127. **The one thing to
  confirm against the LXR paper (Zhao, Blackburn, McKinley):** that its evacuation is stop-the-world /
  safepoint-synchronized (bounded pause, which the "relocate in place + volatile reload" contract assumes). If
  any relocation runs concurrently with mutator reads, roots need a **read barrier** instead of a
  post-safepoint reload — a different contract, and the only part of this model that LXR could invalidate.

### P2 — performance / pipeline / extensibility

- **P2.1 — volatile reloads do not CSE or hoist.** A hot loop with a header poll crosses a safepoint each
  iteration, paying a fresh volatile buffer-pointer reload per iteration. Within a safepoint-free region the
  value is normal SSA. Mitigations: per-field (not whole-region) volatile; poll elision; 179 to keep the
  pointer register-resident.
- **P2.2 — shaped-live-across-safepoint always spills, absent 179.** The model forces a conditional-pointer
  value live across a safepoint into a memory home; it never stays register-resident across a call the way an
  ordinary pointer does. This is the perf argument for 179.
- **P2.3 — O2-pipeline validation beyond the spike.** The deopt-bundle + volatile contract was proven under a
  minimal pipeline. The real `default<O2>` adds inlining, argument promotion, call-slot opt. Confirm deopt
  bundles survive inlining a callee with its own homes/safepoints, and that no pass lifts a recorded slot or
  forwards a volatile. Each failure is silent — stress-spike it.
- **P2.4 — shape-language extensibility (entry kinds).** Weak references, ephemerons, and finalizers need a
  slot the collector nulls/updates without keeping alive — a different entry kind, not a strong pointer at an
  offset. If these are expected, the shape language should admit entry kinds (strong / derived / weak) from
  the start rather than be repainted later.
- **P2.5 — stackmap size.** Recording every materialized region at every safepoint scales the stackmap as
  (regions × safepoints), a footprint cost relevant to the footprint endgame. Precise liveness (P1.2) and
  poll elision mitigate.

## Next steps

Resolve P0 first, as a written contract (the `In`/`Tn` invariants above), since the whole failure mode is
silence. Then P1.1 and P1.2, which can change the architecture. The regression oracles already exist in
embryo: the `Pair { s: String; n: Int }` and `Option<String>` forced/evac divergences (see `shaped-roots.md`
Stage 3b) are the first `Tn` obligations for the slot case; extend the mark-verify / `*-evac` / `*-self` legs
to cover each new shape.
