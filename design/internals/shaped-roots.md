# Shaped GC roots — design

**Status:** design in progress — the spine is settled and the cost model accepted; stages 1–2 locked, the
Stage 4 recording mechanism (deopt operands) validated by an LLVM spike. Build task:
[`176`](../plans/tasks/176-shaped-gc-roots.md)
(this is its design home). Consumers: the bit-stealing `String`
([`121`](../plans/tasks/121-string-utf8-model.md)) and interprocedural stack promotion
([`148 §148.1`](../plans/tasks/148-ssair-optimizer-tier.md)). Sits on the GC substrate in
[`backend.md`](backend.md) ("GC backend substrate") and [`memory-model.md`](memory-model.md) §6.

## Problem

The moving collector finds roots entirely through LLVM statepoints keyed on `addrspace(1)`. `mem2reg`/`sroa`
run before `rewrite-statepoints-for-gc` precisely so that no managed pointer is left in memory; the rewrite
tracks only SSA-value GC pointers. A root is therefore a stackmap `(reg, offset)` slot the walker reads and
the collector rewrites in place; after the call the code reloads from the slot.

Two things that model cannot express:

- **A managed pointer whose managed-ness is per-value and dynamic.** `String`'s `word1` is a buffer pointer
  in the `heap` case and inline UTF-8 bytes in `small`. Typing it `addrspace(1)` would relocate the bytes
  case; typing it `i64` would leave the `heap` pointer untraced and unrelocated.
- **A managed value the compiler wants placed in a frame slot, not the heap.** An escape-promoted object
  crossing a non-inlined call hits the addrspace-across-calls wall ([`148 §148.1`](../plans/tasks/148-ssair-optimizer-tier.md)).

Both want **rooting and placement decoupled from `addrspace(1)`**.

## Spine (settled)

A shaped value live across a safepoint is **pinned to a frame slot**; the slot is **recorded with a
shape-id**; both stack walkers **scan it conditionally** — read the discriminant, then trace/relocate the
managed offsets of the live case. Relocation reuses today's model: the collector overwrites the slot, the
code reloads from it.

The store/load across safepoints is the **accepted cost**. It is the same regime LLVM's default statepoint
lowering already puts every live-across-call root into (spill to a stack slot, reload after). Keeping roots
in registers across safepoints is a separate, measurement-gated optimization tracked in
[`177`](../plans/tasks/177-register-resident-gc-roots.md); 176 ships on the stack-slot form regardless.

## Stage 1 — the shape descriptor

Today's descriptor (`gcDescType` in `LLVMGenGCMaps.swift`) is
`{ i32 size, i32 stride, i32 kind, i32 nptr, i32 ptrmap_off, i32 pad }`; `kind` 0 = fixed, 1 = array, and
`ptrmap_off` points at a flat list of managed byte-offsets. Add **`kind` 2 = shaped**, whose map is
discriminant-keyed rather than flat:

```
tag_off    : byte offset of the discriminant within the value
tag_shift  : how to extract the tag value from the word there
ncases     : number of discriminant values that carry managed pointers
per case   : tag_value → { managed byte-offsets }
```

For `String` (16 bytes, tag in `word0`'s top byte) this collapses to its minimal form: **offset 8 is a
managed pointer iff tag == `heap`.** `small` contributes nothing; `immortal` contributes nothing either —
its buffer lives in immortal space, never collected or moved, so the tracer skips it. One conditional
offset, one tag test.

This is the **per-discriminant pointer map keyed on the discriminant** from the original enum-enabler
framing, now a general shape descriptor a hand-rolled struct points at rather than something welded to enum
lowering. The same `kind` 2 descriptor also closes the latent `Option<SomeClass>` / `Result<Buffer, E>`
hole: a language sum-type-over-references points at it the same way.

**Three consumption sites, one descriptor:**

1. **Shaped root in a frame slot** — the stackmap record carries a shape-id; the walker applies the tag
   test to the slot and conditionally relocates the offset. (Recording mechanism in Stage 4.)
2. **Shaped value as a field of a heap object** — `String` in a `class`/`actor`. The object's pointer map
   carries `(field offset, shape-id)` so the tracer recurses into the conditional sub-shape at that offset.
   `collectManagedOffsets` grows a conditional entry kind, and the object-scan loop grows a branch.
3. **Both collectors** read it identically — the C scanner/walker (`runtime.c`) and the self-hosted tracer
   (`runtime.nomu`, the `while i < nptr` loops): read tag, select the case's offsets. This is the lockstep
   obligation.

## Stage 2 — SSAIR marking + placement invariant

A shaped value type carries its shape-id. One new placement invariant governs it:

> **A shaped value live across a safepoint is memory-resident and recorded as a shaped root there.**

Analogous to the existing I5 ("a managed field becomes a statepoint-tracked root"), and verifiable the same
way: at every statepoint a live shaped value spans, it must appear in that statepoint's shaped-root set.
Between safepoints the value stays register-fast; only safepoint crossings force it to the slot.

## Stage 3 — codegen (sketch; firmed after the spike)

- Lower a shaped local as an **address-taken alloca** (16 bytes for `String`), kept off the `addrspace(1)`
  / SSA root path. Value ops (`byte(at:)`, compare, slice) read the words from the alloca, register-promoted
  within safepoint-free regions.
- At each statepoint the value is live across, attach the slot + shape-id via the recording mechanism
  (Stage 4), so LLVM keeps the alloca memory-resident and reports its frame location after regalloc.
- **The post-safepoint reload of a relocatable word must be non-forwardable** (a `volatile` load, or an
  equivalent barrier). A deopt operand does not mark its pointed-to memory as clobbered, so a plain load of
  `word1` after the call is forwarded from the pre-call value and the collector's writeback is missed
  (Stage 4 result). Only the relocatable word (`word1`, read in the `heap` case) needs this; `word0` (the
  tag) is never written by the collector, so its reads stay ordinary. The volatile read lands once at the
  first post-safepoint use and is a normal SSA value afterward, so register-fast access resumes until the
  next safepoint.

## Stage 4 — recording mechanism (deopt operands — validated)

The slot's frame offset is known only after regalloc, so the record must come through LLVM's own machinery.
Candidates were:

- **Deopt operands on the statepoint** (chosen) — pass the alloca address + a constant shape-id in the
  call's `"deopt"` operand bundle; `rewrite-statepoints-for-gc` threads them into the `gc.statepoint`, and
  they land in `__llvm_stackmaps`.
- **`llvm.gcroot` with metadata** — purpose-built pinned-slot + descriptor, but it belongs to the older
  GC-strategy path and `statepoint-example` ignores it. High risk they do not compose.
- **Custom post-statepoint pass + parallel section** — most control, most work, duplicates stackmap plumbing.

### Spike result (LLVM, `rewrite-statepoints-for-gc`)

A hand-written `.ll` with a `gc "statepoint-example"` function, an `alloca [16 x i8]`, and a call carrying
`[ "deopt"(i32 7, ptr %s) ]` was run through `function(mem2reg,sroa,instcombine,gvn),rewrite-statepoints-for-gc`.
Findings:

1. **Recording works.** The deopt bundle threads verbatim into `llvm.experimental.gc.statepoint`. The
   emitted stackmap record carries `NumDeopt = 2`, then the two deopt locations: a **`Constant` `7`** (the
   shape-id, inline in the location's offset field) and a **`Direct[SP+16]`** location — the frame address
   of the 16-byte slot. An ordinary `addrspace(1)` root recorded alongside appears as an `Indirect[SP+…]`
   base/derived pair in `gc-live`. So the collector gets the slot's frame address and the shape-id directly.
2. **The alloca stays memory-resident.** Because its address escapes into the deopt bundle, `mem2reg`/`sroa`
   do not promote it — it keeps a real frame slot.
3. **A plain reload is unsound.** A deopt operand does *not* mark its pointed-to memory as clobbered, so a
   plain `load` of `word1` after the call is forwarded from the pre-call value (`ret %init`) — the
   collector's in-place writeback would be missed. A **`volatile` load** of the relocatable word after the
   safepoint blocks the forwarding and composes with the statepoint rewrite (an inline-asm memory clobber
   does **not** — the rewrite tries to statepoint-convert the asm call and the module fails verification).

### Consequences for the parser and codegen

- The runtime stackmap parser (`runtime.c`) currently skips 3 meta constants assuming `NumDeopt = 0` and
  reads the rest as gc pointers. It must instead **read `NumDeopt` and carve the deopt range** as shaped
  records (shape-id Constant + `Direct` slot location), leaving the `gc-live` pairs as today's roots.
- Codegen emits the relocatable-word reload after a safepoint as a **`volatile` load** (Stage 3).

## Stage 5 — collector consumption

- **Conditional trace (176.1)** — read-only. Both scanners learn the `kind` 2 branch (read tag, loop the
  live case's offsets) for objects, the `(offset, shape-id)` recursion for shaped fields, and the shaped-slot
  handling in the root walk. Enough for a shaped value whose target does not move.
- **Conditional relocate + writeback (176.2)** — the walker overwrites the managed offset in the slot with
  the forwarded address in the pointer cases; the mutator's post-call reload observes it.
- Both the C walker (`nomu_gc_walk_context`, libunwind) and the self-hosted `rtWalkFrom` carry the same
  logic; the GC-stress / `*-evac` suite legs are the lockstep check.

## Stage 6 — invariants + tests

- **New I-invariant** (Stage 2): a shaped value live across a safepoint is recorded as a shaped root.
  Enforced by `verifySSAIR`.
- **`Tn` forced-GC obligations:** a `String` in each case (`small` / `immortal` / `heap`), held live across a
  forced collection, both as a local and as a `class`/`actor` field, survives and (for `heap`) relocates
  correctly.
- **Both-collector lockstep:** the `kind` 2 descriptor read identically by the C and Nomu tracers — a
  fingerprint/oracle diff, as the existing mark-verify legs do.

## Scope

**176.1 covers root slots and shaped fields together** — a `String` in a `class`/`actor` is a given, so
Stage 1 site 2 (object-field recursion) is in the first cut, not deferred.

## Open questions

- **Deopt-operand recording** — confirmed by the spike (Stage 4), including the `volatile`-reload obligation.
- **Immortal buffer** — relies on immortal-space membership so the tracer can skip it (`nomu_gc_alloc_immortal`
  exists); confirm the tracer never needs to visit it and that literals become headered immortal objects.
- **Tag encoding** — reading `word0`'s top byte as a byte at offset 7 vs an `i64` shift; pick alongside the
  `String` layout in 121.
