# GC Model Upgrade — the `(region, shape)` root model

**Status:** design in progress — the spine (`(region, shape)` records + one shape language + one scanner) is
drafted and the case coverage checks out on paper; the **P0 soundness questions are resolved into a testable
contract** (invariants I11/I12 + the `T-*` obligations; see *Open questions*, P0), P1.1 is de-risked (erased
generics; a confirmed two-edit fix) and P1.2 is resolved (an ordering rule + an A/B recording decision with
its SROA cost characterized), and the open work is the 176.3a/.3b build against that contract.
This doc synthesizes and is meant to become the governing model that
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

Priority: **P0 = soundness, commit-gating** (the model's failure mode is silent relocation corruption, so
these are settled with a testable contract before building) — now resolved into the contract below; P1 =
architecture-affecting; P2 = performance / pipeline / extensibility.

### P0 — soundness (resolved into a contract)

Status: the P0 investigation (task 176.3) is complete. Each item below is resolved into (a) a finding
grounded in the current code, (b) an `In` invariant checked by `verifySSAIR`, and (c) a `Tn` forced-GC
obligation. Two new invariants land in [`ssair.md`](ssair.md): **I11** (region recording + zero-init +
volatile reload) and **I12** (no interior pointer across a safepoint). The failure mode is silent, so the
`Tn` differentials are the gate; the `In` checks catch the structural precondition at compile time. The
invariants define the contract the 176.3a/.3b build must satisfy; the `verifySSAIR` checks and the `Tn`
scripts are themselves build work.

**P0.1 — per-field volatile placement. Resolved: whole-region volatile reload is the correctness baseline;
per-field volatile is a later optimization under the same invariant.**

Finding. The forwarding hazard the Stage 4 spike found is that a deopt operand leaves the pointed-to slot
un-clobbered, so LLVM forwards a pre-safepoint load of a managed word across the statepoint and the mutator
reads a stale pointer instead of the collector's writeback. A `volatile` load blocks the forward. A bare
`String` home is already correct by construction: `val(_:)` in `SSAIRToLLVM.swift` is the one read path for a
homed value and always loads `word0` volatile, so there is a single emission site and nothing per-field to
misplace. A value-aggregate slot (176.3) reads through scattered `fieldAddr`+`load`, which is where per-field
placement would bite. The resolution keeps one shape-driven emission rule: a load from `gep(region, off)` is
`volatile` iff `off` is a managed or shaped offset of the region's shape and the region is recorded at a
dominating safepoint. Stage 3b's conservative form — one `volatile` reload of the whole aggregate per
safepoint crossing — is mechanical (keyed only on the region being live-out of a safepoint, read from the
shape) and carries no per-field decision. Reloading only the managed offsets is the P2.1 optimization and must
preserve the invariant.

Invariant **I11a (volatile reload).** No SSA value derived from a managed or shaped offset of a recorded
region is used across a safepoint the region spans without an intervening reload of that offset; the reload is
the only post-safepoint read path and lowers to a `volatile` load. `verifySSAIR` checks the SSAIR-level
precondition — every region live across a safepoint is recorded with its shape, and every post-safepoint read
of a recorded region's managed/shaped offset is a reload def rather than a forwarded earlier load. The
`volatile` flag is a codegen attribute below SSAIR, so the single-emission-site discipline plus the `Tn`
differential is the backstop for the flag itself.

Obligation **T-vol.** A region with two managed fields read at several points after a forced collection reads
both back relocated, byte-identical to the `-c nogc` baseline; a deliberately non-volatile reload (debug
toggle) diverges, proving the differential has teeth.

**P0.2 — partial-initialization window. Resolved: zero-init dominates the first recording safepoint, and the
all-zero pattern decodes to "no managed pointer."**

Finding. `setUpShapedHomes` zero-initializes every home with a null store at the entry-block end, before the
entry poll and the body, so the home dominates every use and starts as the empty string. The entry poll is
the first safepoint; the zero-init precedes it in the same block, so the allocation-to-zero-init window is
safepoint-free. The all-zero pattern decodes safely: String's `small` tag is 0, so a zeroed slot yields no
managed offsets (Stage 5 zero-scan safety); a kind-0 managed offset reads as a null pointer, and both walkers
skip a null root before visiting it (`sroot.isNull == false` in the self-hosted walk, the matching guard in
the C walk). The mid-construction case is the sharp one: `Pair(s: concat(...), n: 7)` runs `concat` (a
safepoint) before the `s` field is stored, so the collector can scan a half-built `Pair`. Zero-init makes that
safe — the unwritten `s` field reads tag 0 and contributes no offset.

Invariant **I11b (zero-init before observation).** Every recorded region is zero-initialized on all paths from
its allocation before the first safepoint it is live across, and every shape's all-zero bit pattern decodes to
"no managed pointer" (empty tag-0 case for kind 2; null pointer for kind 0, which the walkers skip).
`verifySSAIR` checks that a zero-init def of each recorded region dominates every safepoint the region is live
across.

Obligation **T-init.** A `Pair { s: String; n: Int }` whose `String` field is produced by a call (a safepoint
mid-construction) survives a forced collection at that safepoint and reads back correct, byte-identical to
`-c nogc`.

**P0.3 — idempotent relocation under dual rooting. Resolved: both collectors forward; recorded as a relied-on
collector property.**

Finding. A dual-root case exists today: a `String` field of a heap `class` is rooted through the object's
`nshaped` scan, and the same `String` loaded into a homed local is rooted through the local's slot record —
one buffer, two roots at one safepoint. Relocation must run once. Both collectors guarantee this with a
forwarding pointer: MMTk Immix evacuation uses forwarding bits; the self-hosted collector's `rtEvacuate` sets
the forwarded bit and `rtForwardDuringTrace` returns the forwarding pointer for an already-moved object
(`runtime.nomu`). The second visitor reads the forwarding pointer and rewrites its root to the moved address.
This is a collector property with nothing for `verifySSAIR` to check; recorded here as relied-on: every
managed root, however reached, relocates idempotently through the forwarding pointer.

Obligation **T-dual.** A heap-`class` `String` field and a homed local holding the same `String`, both live
across a forced evacuation, relocate the one buffer once; the `*-evac` and `*-self` fingerprints match and the
buffer address advances exactly once.

**P0.4 — interior / derived pointers across a safepoint. Resolved: forbidden and compiler-enforced.**

Finding. The shape language roots base pointers at offsets and cannot express an interior pointer (a `RawPtr`
into the middle of a buffer, from `elementPtr`/`elementAddr`). An interior pointer that spans a safepoint
while its base relocates dangles. Today the rule is discipline — "use within a safepoint-free region." The
compiler can enforce it: classify the derived-pointer-producing ops whose base is managed or shaped, then use
the existing shaped-liveness to assert none of their results is live across a safepoint. A violation is a
compile error.

Invariant **I12 (no interior pointer across a safepoint).** No value that is an interior or derived pointer
into a managed or shaped base is live across a safepoint; code needing the pointer after a call reloads the
rooted, relocated base and re-derives it. `verifySSAIR` classifies `elementPtr`/`elementAddr`/`fieldAddr`
results over a managed/shaped base and checks liveness across every safepoint inst. Cost: a hot element loop
with a header poll re-derives the interior pointer each iteration from the rooted base; keeping the base
register-resident across the poll is the 179 concern. Couples to P1.3 — `Substring` is therefore
`(base pointer, integer offset)` so the stored pointer is always a base.

Obligation **T-interior.** The compiler rejects a program that holds an `elementPtr` result live across a poll
(a negative test); an allowed pattern that re-derives after the safepoint is stable across a forced
collection, byte-identical to `-c nogc`.

Residual (build-time audit). Ordinary indexed access (`arr[i]`) lowers to `elementAddr`+`load` in the same
block with no safepoint between (`FunctionLowerer.swift`), so I12 does not touch it. The interior pointers
that *are* held are the `RawPtr` / `ManagedBuffer.elementPtr` intrinsics, which escape to Nomu code and today
rely on the safepoint-free-region discipline. Enabling I12 constrains exactly that surface, so the stdlib /
`core.nomu` uses of those intrinsics must be audited (and any that legitimately cross a safepoint must root
the base and re-derive) before I12 turns on. This is the one P0 item whose enforcement can reject
currently-accepted code.

**P0.5 — two-collector lockstep. Resolved: shape decode is a single shared implementation; the residual risk
is the duplicated per-reference action and deopt-range parsing.**

Finding — the strongest of the five. The shape *decode* is one C implementation both collectors call. The
self-hosted tracer's `RawPtr.gcLiveCount` / `gcLiveOffsetAt` / `gcShapeDescForOrdinal` lower to calls to the
very functions the C walker uses — `nomu_gc_live_offsets` and `nomu_shape_desc_for_ordinal`
(`SSAIRToLLVM.swift` intrinsic lowering). The kind-2 tag read, the case selection, and the object-field fold
exist once; a new shape kind added to `nomu_gc_live_offsets` reaches both collectors. Two things stay
per-collector: the per-reference *action* (mark, trace, relocate, write back) across the self-hosted tracer's
~10 phase functions and the MMTk scan sites, each iterating the offsets the shared enumerator returns; and the
deopt-range parse of the root walk, written twice (`nomu_gc_walk_context` in C, `rtWalkShadow` in
`runtime.nomu`). Those two are where a new shape can diverge. The contract narrows to: (a) shape decode stays
single-source — a new kind extends `nomu_gc_live_offsets` only; (b) every new shape adds a fingerprint-oracle
leg that exercises the per-reference action and the root-walk parse in both collectors. `verifySSAIR` has no
role here; it is a runtime-equivalence property.

Obligation **T-lockstep.** For each shape (struct-with-`String`, enum-with-`String`, and the nested case), a
value held live across a forced collection produces byte-identical `mark-verify`, `*-evac`, and `*-self`
fingerprints across the C and self-hosted collectors.

### P1 — architecture-affecting

- **P1.1 — runtime shape-ids for erased generics. De-risked; the feared unknown is moot, the real gap is
  bounded and a fix is confirmed.** The question as posed — can RS4GC thread a *non-constant* deopt operand,
  can the walker read a dynamic shape-id — does not arise, because erased generics never use the
  deopt/stackmap channel. A non-POD erased `T` buffer is rooted on a **per-fiber shadow stack** (`{prev,
  buffer, vwt}` nodes, task 100.4.3.6, built and green), and `rtWalkShadow` reads a **runtime** descriptor-id
  from the VWT (`type_id`, byte 8) and runs it through the shared enumerator (`RawPtr.gcLiveCount` /
  `gcLiveOffsetAt` → `nomu_gc_live_offsets`). A runtime descriptor-id resolved through the one enumerator is
  already the shipping mechanism; the walk reads a dynamic shape, so the capability P1.1 feared is built.

  The actual gap was narrow and three-part: the value-layout machinery dropped *shaped* content because three
  sites read through the shaped-discarding `collectManagedOffsets` overload — the consumer registration
  decision (`SSAIRToLLVM.emitErasedExternalCall`), the VWT POD flag (`LLVMGenValueWitness`), and the
  value-layout descriptor (`LLVMGenGCMaps.valueDescId`). So a `String` inside an erased `T` was never
  registered and its descriptor omitted the shaped word. **Spike + fix (confirmed):** fixture
  `module_generic_string` (an erased `hold<T>` called at `T = String`, a heap-tagged `String` held across a
  forced moving STW) reports `fixed 0 roots` unfixed and `fixed 1 roots` fixed; the fix carries shaped entries
  through the registration decision and `valueDescId` (two edits, no runtime / walker / stackmap-format
  change — the existing `kind 0` + `nshaped` fold the shared enumerator already recurses does the work). All
  33 `module-generic*` fixtures stay green. The root-count teeth is the deterministic oracle; stdout alone
  masks the defect, since an unrooted buffer reads correct until its block is reused.

  **The POD flag conflates two concerns** and is the one design decision to record: `vwtFlagPOD` means both
  "copy is a memcpy" (true for `String`) and "no GC scan needed" (false for `String`). The fix leaves the flag
  POD (copy stays a sound memcpy) and roots off the shaped-carrying collect instead. If a future non-POD copy
  thunk keys GC scanning off this flag, the flag must split into a memcpy bit and a needs-scan bit
  (`backend.md` §4 reserves the remaining bits). **Remaining:** an erased `T` carrying a *conditional* nested
  enum (`Wrap<Opt<String>>`, deferred shadow-stack edge (b), task 171 §171.3) rides 176.3b's nested `kind 2`
  descriptor once it lands — the walk already reads the tag through the shared enumerator, so no new erased
  mechanism is needed; confirm that coupling when 176.3b is built.
- **P1.2 — region-recording vs. promotion ordering. Investigated with an LLVM SROA spike; resolved into an
  ordering rule, a characterized cost, and a measurement-gated optimization.** The spike ran
  `opt -passes='function(mem2reg,sroa,instcombine,gvn),rewrite-statepoints-for-gc'` (LLVM 22) over a
  `Pair { s: String; n: Int }` modeled as a 24-byte slot (`word0` buffer ptr, `word1` tag/len, `n`), the
  shaped sub-field recorded through a `"deopt"` operand:
  - **Recording a pointer into the aggregate slot** (Stage 3b's `gep(slot, off)` per shaped sub-field) pins
    the whole aggregate — the 24-byte alloca survives with all three setup stores live, including the store to
    the non-shaped `n` the collector never reads. SROA cannot split an alloca whose interior pointer is
    captured by a deopt operand (1 alloca, 3 stores).
  - **No recording** (baseline) lets SROA split the aggregate and strip it to the single live slice (the
    volatile-loaded `word0`); the `word1` and `n` stores vanish (8-byte alloca, 1 store).
  - **Homing the shaped sub-field in its own alloca** and recording that (not a GEP into the aggregate) pins
    exactly the 16-byte shaped value — whose `word1` tag the collector must read anyway — and leaves the
    sibling scalar `n` a pure SSA value (16-byte alloca, 2 stores). This matches the baseline's efficiency for
    non-shaped fields; the one extra store over baseline (the tag) is the irreducible shaped-value overhead.
  - **GVN forwards non-shaped field *reads* across the safepoint even under slot recording** — the `n` load
    resolves to the stored SSA value with no reload, because the volatile sits only on the managed word. So
    the read cost is register-resident regardless of the recording choice; the residual cost of recording into
    the slot is the pinned frame + the dead setup stores (a P2.5 stackmap/frame-size cost), not reload traffic.

  Ordering rule (the model). Recording is the egress's last step, and every promotion pass runs before it (the
  midend EA tier, then LLVM SROA), so "promote first, record the residue" holds by construction. The residue
  to record is the shaped sub-value(s); the rest of the aggregate stays promotable storage.

  Decision for the 176.3 build. **Option A — record the aggregate slot's *base* with the aggregate's shape
  ordinal:** simplest, reuses the existing slot, reads forward via GVN; pins the whole aggregate (frame slot +
  dead non-shaped stores, but only while the aggregate is live across a safepoint). The recorded pointer must
  be the bare alloca base, since a stackmap spike shows a non-zero `gep(slot, off)` records as `Indirect` and
  is dropped by the walkers — the sub-field offset lives in the shape descriptor (`shaped-roots.md` Stage 3b).
  **Option B — home each live shaped sub-field in its own alloca and record that base:** keeps the rest of
  the aggregate SROA-promotable, pins only the 16-byte shaped value, and its home base is also `Direct`; needs
  a copy-out / copy-back of the shaped word around each safepoint for a mutated slot. Recommendation: ship
  **Option A** for 176.3a/.3b — correct, simplest, and field reads are already register-resident — and treat
  Option B as a measurement-gated
  optimization, since the aggregate is pinned only across a safepoint (the minority), the residual cost is
  bounded dead stores + frame size, and Option B's copy-out/back carries its own traffic. This mirrors 176
  shipping the stack-slot form and deferring register-residency ([177](../plans/tasks/177-register-resident-gc-roots.md))
  to measurement.

  Related gap (deferred with Option B). The scalar-promotion pass (`ScalarPromotion.swift`, `isFieldPromotable`)
  already *excludes* `String`/aggregate/existential/closure fields, so a loop-carried object with a shaped
  field stays heap today — the pass bails rather than decomposing. Lifting it is the same Option-B
  decomposition at object granularity, deferred together.
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

P0 is resolved into the contract above (invariants I11/I12 + the `T-*` obligations), P1.1 is de-risked
(the erased-generic runtime-shape-id capability is built; the shaped gap is a confirmed two-edit fix staged in
`valueDescId` + the erased registration decision, with the `module_generic_string` spike as its oracle), and
P1.2 is resolved into an ordering rule + an A/B recording decision (Option A for the first cut, Option B
measurement-gated), with its LLVM SROA cost characterized. The open work is the 176.3a/.3b build against the
contract. The regression
oracles already exist in embryo: the `Pair { s: String; n: Int }` and `Option<String>` forced/evac
divergences (see `shaped-roots.md` Stage 3b) are the first `Tn` obligations for the slot case (T-init and the
`.3b` lockstep leg); extend the mark-verify / `*-evac` / `*-self` legs to cover each new shape.
