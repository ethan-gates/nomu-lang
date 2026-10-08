# Shaped GC roots — design

**Status:** design in progress — the spine is settled and the cost model accepted; stages 1–2 locked, the
Stage 4 recording mechanism (deopt operands) validated by an LLVM spike, Stage 5's structure settled (the
shared enumerator). Stages 1–5 are **built and green for a bare `String`** (local, and as a `class`/`actor`
field). The `String` layout coupling is resolved (tag in `word1`'s top byte, clean `word0` pointer, leaf
`heap` buffer — see the open questions). **Remaining: Stage 3b — frame-root placement for value aggregates
(task 176.3)**, the generalization from a bare shaped value to *any value aggregate holding shaped content*
(a `struct` with a `String` field, an `enum` with a `String` payload). This is a correctness gap today
(demonstrated below), and [121 String](../plans/tasks/121-string-utf8-model.md) rests on it.
Build task: [`176`](../plans/tasks/176-shaped-gc-roots.md)
(this is its design home). The shaped-root mechanism here is the first cut of the unified `(region, shape)`
root model in [`gc-model-upgrade.md`](gc-model-upgrade.md) — read that for the governing model and the
open soundness questions it must satisfy. Consumers: the bit-stealing `String`
([`121`](../plans/tasks/121-string-utf8-model.md)) and interprocedural stack promotion
([`148 §148.1`](../plans/tasks/148-ssair-optimizer-tier.md)). Sits on the GC substrate in
[`backend.md`](backend.md) ("GC backend substrate") and [`memory-model.md`](memory-model.md) §6.

## Problem

The moving collector finds roots entirely through LLVM statepoints keyed on `addrspace(1)`. `mem2reg`/`sroa`
run before `rewrite-statepoints-for-gc` precisely so that no managed pointer is left in memory; the rewrite
tracks only SSA-value GC pointers. A root is therefore a stackmap `(reg, offset)` slot the walker reads and
the collector rewrites in place; after the call the code reloads from the slot.

Two things that model cannot express:

- **A managed pointer whose managed-ness is per-value and dynamic.** `String`'s `word0` is a buffer pointer
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

For `String` (16 bytes, tag in `word1`'s top byte — byte 15) this collapses to its minimal form: **offset 0
(`word0`) is a managed pointer iff tag == `heap`.** The pointer word is clean and untagged, so no masking is
needed on relocate. `small` contributes nothing; `immortal` contributes nothing either — its buffer lives in
immortal space, never collected or moved, so the tracer skips it. The `heap` buffer (`StringStorage`) is a
GC leaf (`nptr = 0`), so the trace relocates and marks it with no recursion. One conditional offset, one tag
test.

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

## Stage 3 — codegen (firmed — Model 1: alloca-as-home)

**Storage model.** A shaped value live across a safepoint lives in a 16-byte **address-taken alloca** — its
home. Value ops (`byte(at:)`, compare, slice, tag read) read/write the two words through it, and LLVM's
backend register-promotes those accesses within safepoint-free regions. The deopt bundle at each statepoint
references the alloca (Stage 4), keeping it memory-resident and reporting its frame slot after regalloc. The
alternative — keep the value SSA and hand-place a spill/reload around each safepoint — was rejected: Model 1
is what the spike exercised, and it leans on LLVM for the register promotion rather than placing spills by
hand.

Rules:

- **Materialization is safepoint-gated.** A shaped value that never spans a safepoint stays a pure SSA
  `(i64, i64)` pair — no alloca, no record, fully register-promoted. The alloca appears only when the value
  is live across at least one safepoint (the Stage 2 invariant).
- **`word0` volatile, `word1` ordinary.** The first post-safepoint read of the relocatable word (`word0`,
  the buffer pointer, read in the `heap` case) is a `volatile` load — a deopt operand does not mark the
  alloca clobbered, so a plain load is forwarded from the pre-call value and the collector's writeback is
  missed (Stage 4 result). After that first read it is a normal SSA value, register-fast until the next
  safepoint. `word1` (tag/count) is never written by the collector, so its reads are ordinary and forward
  across safepoints.
- **Multi-safepoint live range.** One deopt record per statepoint the value spans; one `word0` volatile
  reload per safepoint, at the first post-safepoint use. The single-safepoint pattern, repeated.
- **Composition with the object-field form (Stage 1 site 2).** A `String` field inside a `class`/`actor` is
  scanned via that object's pointer-map `(field offset, shape-id)` — the object-scan path, not the slot
  path. Loading the field into a shaped local that spans a safepoint puts the local on the slot path;
  storing back is an ordinary store. The two forms stay distinct and compose through plain load/store, and
  both read the one `kind 2` descriptor.

`word0` is an `i64` in the stack alloca (addrspace(0)), so RS4GC ignores it; the deopt/shape record is what
makes the collector find and relocate it. This is the intended `String` exception to the `addrspace(1)` root
model.

## Stage 3b — frame-root placement for value aggregates (task 176.3)

Stage 3 homes a value whose *whole* type is shaped — a bare `String`. A value **aggregate** that merely
*contains* shaped content — `struct Pair { s: String; n: Int }`, `enum Option<String>` — held as a local
across a safepoint is not covered by it (the aggregate's type is not `.string`, so `isShapedType` is false
and it is never homed), nor by the object-field path of Stage 1 site 2 (that scans a *heap object's* fields;
a value aggregate local is not a heap object). The shaped sub-value's `word0` is a bare `i64` inside the
aggregate, invisible to RS4GC, so its buffer is not relocated.

**This is a correctness gap in the current compiler.** Demonstrated: a `Pair { s: String; n: Int }` and an
`Option<String>` held live across an evacuating collection read back garbage (the field/payload `word0` is
stale), diverging from the `-c nogc` baseline. The two cases are the regression oracles for this stage.

**It must be structural — a compiler law.** Adding a `String` stored property to any `struct`/`enum` may
never require a per-type compiler change; a language where it does is not a language. So "contains shaped
content" is a **recursive structural property** computed from a type's stored properties (the heap-object
descriptor path already obeys this — that is why `class Holder { var s: String }` works with no per-type
code), never a maintained list of types. Stage 3b extends the *value-local* path to the same law.

**Scope is bounded by the value-type rule.** A value type may not store a reference field (the frontend
rejects `struct Pair { var node: SomeClass }` — "use a class"). So the only managed content a value-aggregate
local can carry is **shaped** (a `String`, directly or nested in a value field/payload). There are no
ordinary `addrspace(1)` fields in a value aggregate, so homing the whole aggregate to a frame slot hides
nothing from RS4GC — the Stage 3 "alloca-as-home" model extends directly, with no RS4GC interaction to
reconcile.

### Representation note (corrected after build)

A value-aggregate `let`/`var` local is **not an SSA aggregate value** — ssairgen materializes it to a
`stackAlloc` slot (`%slot = alloca %struct.Pair`), with field reads lowered as `fieldAddr` + `load`. So the
Stage 3 "SSA value homed into an alloca" model does not apply to it: the aggregate is *already* memory-
resident in its own slot, and it is excluded from the SSA-homing set as an address op. The fix is therefore
true **frame-root placement of the existing slot**, not homing a new one:

- **Record the slot as a shaped root.** At each safepoint the slot is live across, emit a deopt shaped-root
  record `(ordinal, gep(slot, off))` per shaped sub-field — the same record as a homed value, pointing at
  the stackAlloc slot. Needs a **slot-liveness** notion (which shaped-containing slots are read after which
  safepoints); a zero-initialized slot scans safely (Stage 5 zero-value safety) so conservative recording of
  a live slot is sound.
- **Volatile `word0` on field reads.** A `fieldAddr`+`load` of a shaped sub-field after a safepoint must read
  `word0` `volatile`, so the collector's in-place writeback into the slot is observed (the Stage 4 forwarding
  hazard, now on the field-load path rather than the homed-value reload).

(The SSA-homing generalization above still applies to a genuinely-SSA shaped aggregate — a struct returned by
value and consumed across a call without being slotted — and a bare `String` local stays the Stage 3 case.
The common value-local is the stackAlloc-slot path.)

### Mechanism (SSA-value form)

A shaped value that *is* an SSA value (a bare `String`, or an SSA aggregate) live across a safepoint is homed
to a frame-slot alloca of its own LLVM type (the Stage 3 model, generalized off `strTy` to the aggregate
type). What is recorded and how the slot is reloaded splits by whether the shaped content sits at a **fixed**
or a **discriminant-conditional** offset:

- **Structs (fixed offsets) — reuses the existing mechanism, no collector change.** `collectManagedOffsets`
  already yields the aggregate's shaped sub-fields as `(byte offset, shape-id)` pairs (it recurses struct
  fields; a `String` field contributes `(off, stringShapeId)`). Codegen records **one shaped-root deopt pair
  per shaped sub-field**, `(shape-ordinal, gep(slot, off))` — the same `(shape-id, slot-Direct)` pair Stage 4
  records, pointing at the sub-field rather than the slot base. The walkers already "run the enumerator on
  each recorded slot base" (Stage 5 root path), so a sub-field base is scanned exactly as a bare `String`
  with zero collector, stackmap-format, or descriptor change. A bare `String` is the degenerate case: one
  shaped sub-field at offset 0 — Stage 3 is subsumed, not special-cased.

- **Enums (discriminant-conditional offsets) — needs a descriptor + collector extension.** An `enum`'s
  shaped payload is present only in some cases, and a *non-shaped* case's data can alias the payload slot with
  an arbitrary bit pattern, so unconditionally scanning the payload offset is unsound (a stray value whose
  `word1` top nibble reads as `heap` would be treated as a buffer pointer). The collector must read the enum
  tag first and scan the payload's shaped sub-value only in the cases that hold one. This is expressed by the
  existing `kind 2` descriptor made **nested**: a case entry may be a `(offset, sub-shape-id)` shaped entry
  (the String sub-shape) rather than only a flat managed offset — the discriminant-keyed form the descriptor
  was designed around, now two levels (enum tag → the payload String → the String's own tag). Requires:
  `collectManagedOffsets` to handle enum payloads (it currently skips enums — "payloads carry no references
  today"), producing per-case shaped entries over the `{ i64 tag, [P x i64] payload }` layout; the shared
  enumerator (both collectors) to recurse a nested shaped sub-entry; and codegen to record the enum value's
  `(enum-shape-id, slot)` as one shaped root.

### Reload

On use after a safepoint the homed aggregate is reloaded from its slot with a **`volatile` load of the whole
aggregate** (not a plain load — Stage 4: a plain load is forwarded from the pre-call value and misses the
collector's writeback). The collector has written each relocated `word0` back into the slot, so one volatile
aggregate load observes every update; `word1`/scalar words are reloaded too (harmless — the collector never
writes them). This generalizes Stage 3's split `word0`-volatile / `word1`-ordinary reconstruction to an
arbitrary layout; the finer split is a later optimization, not a correctness requirement.

### Staging

- **176.3a — structs (fixed offsets).** Codegen only: generalize the homing predicate to "type transitively
  contains shaped content" (recursive, structural — never a type list), home the aggregate, emit one shaped
  deopt pair per shaped sub-field via `collectManagedOffsets`, volatile-reload the aggregate. No collector,
  stackmap-format, or descriptor change. Oracle: the `Pair { s: String; n: Int }` forced/evac test.
- **176.3b — enums (conditional offsets).** Extend `collectManagedOffsets` to enum payloads, the `kind 2`
  descriptor to nested per-case shaped entries, and the shared enumerator in both collectors to recurse them;
  record the enum value as one shaped root. Oracle: the `Option<String>` forced/evac test. Both collectors in
  lockstep (the standard mark-verify / `*-evac` / `*-self` legs).

Both stages uphold the law: the predicate and the offsets are derived structurally from stored properties, so
any `struct`/`enum` with a `String` (anywhere, nested) is correct with no per-type compiler change.

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
   plain `load` of `word0` after the call is forwarded from the pre-call value (`ret %init`) — the
   collector's in-place writeback would be missed. A **`volatile` load** of the relocatable word after the
   safepoint blocks the forwarding and composes with the statepoint rewrite (an inline-asm memory clobber
   does **not** — the rewrite tries to statepoint-convert the asm call and the module fails verification).

### Consequences for the parser and codegen

- The runtime stackmap parser (`runtime.c`) currently skips 3 meta constants assuming `NumDeopt = 0` and
  reads the rest as gc pointers. It must instead **read `NumDeopt` and carve the deopt range** as shaped
  records (shape-id Constant + `Direct` slot location), leaving the `gc-live` pairs as today's roots.
- Codegen emits the relocatable-word reload after a safepoint as a **`volatile` load** (Stage 3).

## Stage 5 — collector consumption

Both collectors consume the shape descriptor: the MMTk-binding path (`gcbinding/lib.rs` + the C stack
walker in `runtime.c`) and the self-hosted collector (`runtime.nomu`). The self-hosted tracer runs the
pointer-map loop in **ten phase functions** — `rtObjHash`, `rtMarkVerify`, `rtMarkVerifyImmix`,
`rtLineMarkCheck`, `rtImmixMark`, `rtImmixUnmark`, `rtGenUnmarkAndUnlog`, `rtImmixEvacMark`,
`rtMinorScanObj`, `rtWalkShadow` — each with its own per-reference action, and the MMTk side has its own
scan sites. Scattering a `kind` 2 branch across all of them is the main lockstep hazard.

**Decision — centralize the tag-decode behind a shared enumerator.** The `kind` 2 conditional depends on
the value's data (the tag), so it lives behind the accessor layer both collectors already share. One
enumerator resolves *the live managed word offsets of a value at `base`* across kind 0 (flat), kind 1
(array element), and kind 2 (read tag at `base + tag_off`, select the case's offsets), including the
`(field offset, shape-id)` recursion for a shaped field inside an object. The ten phase-loops keep their
own per-reference action and iterate the resolved offsets, so the conditional logic exists in exactly one
place per collector. The enumerator must keep the common kind-0 path at its current cost — a runtime perf
obligation tracked as [`178.1`](../plans/tasks/178-runtime-gc-performance.md) (no added indirection or
per-word branch on the path every ordinary object and root takes; the tag-decode is paid only by shaped
values).

**Root path.** `nomu_gc_walk_context` (C/libunwind) and `rtWalkFrom` / `rtWalkShadow` (self-hosted) read
`NumDeopt` and interpret the deopt locations as `(shape-id constant, slot Direct)` pairs — every shaped
root is two operands, shape-id then slot — and run the enumerator on each slot base. This covers the
current-stack, parked-fiber, and stopped-carrier walks, which all funnel through those functions.

**176.1 / 176.2 split.** The read-only phases (`rtImmixMark`, mark-verify, `rtMinorScanObj`, the MMTk
trace) take `kind` 2 first — trace only. `rtImmixEvacMark` and the MMTk evac copy path add
relocate-and-write-back of the conditional word, reusing each phase's existing per-reference relocate
primitive; the mutator's `volatile` reload (Stage 3) then observes it.

**Zero-value scan safety.** The tag is designed so `0 = small, length 0` (empty string), so a zeroed or
not-yet-assigned slot scans as no managed offsets — a partially-live frame is always safe.

**Lockstep oracle.** The mark-verify and `*-evac` legs hold a `String` in each case
(`small` / `immortal` / `heap`) live across a forced collection, as a local and as a `class`/`actor`
field; the self-hosted and MMTk fingerprints must match.

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
- **Immortal buffer — resolved.** Immortal buffers are never traced or moved (immortal-space membership;
  `nomu_gc_alloc_immortal` exists). And a `String` is a GC leaf: its `heap` buffer (`StringStorage`) holds
  only bytes, `nptr = 0`, so even in the `heap` case the trace relocates and marks the buffer with no
  child recursion. Still to confirm in build: literals become headered immortal objects.
- **Tag encoding — resolved (with the 121 layout).** The discriminant is the **top nibble of `word1`**
  (Swift-style: 4-bit discriminant in bits 60–63, the inline count in byte 15's low nibble). The collector
  extracts it by loading the i64 at `base + tag_off` and shifting right by `tag_shift`, so the `kind 2`
  descriptor for `String` is `tag_off = 8` (`word1`), `tag_shift = 60`, one case (`heap`, tag value `2`)
  with managed offset `0` (`word0`). Discriminant values `small = 0` (so a zeroed value is the empty
  string — Stage 5 zero-scan safety), `immortal = 1`, `heap = 2`. The managed pointer (`word0`) is clean and
  untagged, so relocate needs no masking. (The descriptor is shift-only, no mask field, because the tag sits
  at the top of the word; a future shaped type with a mid-word tag would add a mask.)
