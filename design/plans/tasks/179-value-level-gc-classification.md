# Value-level GC-pointer classification — GC residency off `addrspace`

**Avenue:** Risk (the moving-collector precision substrate) · **Type/Lifecycle:**
`gc · codegen · midend · llvm` · **Size:** XL · **Status:** direction chosen (option A of four
evaluated); **build not committed** — gated on a payoff measurement (move 1) and an RS4GC-fork spike
(move 2) below · **Source:** the addrspace-across-calls stack-promotion wall in
[148 §148.1](148-ssair-optimizer-tier.md) plus the `addrspace(1)`-biconditional that also blocks
[176](176-shaped-gc-roots.md) / [121](121-string-utf8-model.md); emerged from reframing the shaped-roots
problem as an LLVM pointer-classification problem rather than a per-feature one.
**Design home:** this task doc for now; promote to `../../internals/` if it clears the gates.

## What

Decouple GC-managedness from the LLVM `addrspace(1)` *type*. Today the compiler enforces
`addrspace(1) ⇔ GC-managed` as a biconditional, welded into `RewriteStatepointsForGC` (RS4GC) through
`GCStrategy::isGCManagedPointer(const Type*)` — the statepoint-example strategy returns
`addrspace == 1`. Everything downstream (base-pointer analysis, liveness, `gc.relocate` insertion) keys
off that one **type-keyed** predicate.

An ABI slot has one static LLVM type, so if that type's address space decides managedness, a value that
is a managed reference in only some dynamic cases has no type it can cross a function boundary in. Under
opaque pointers the address space is the *only* attribute a `ptr` type carries, so a different **type**
signal does not exist — the signal must move off the type and onto the value.

Option A does that:

- **Repurpose the address space.** `addrspace(1)` stops meaning "GC-managed" and means
  **"may be a managed reference — do not launder."** Keep `ni:1` in the datalayout, so the
  integer-laundering ban (no `ptrtoint`/`inttoptr` round-trip that would hide a pointer from the
  collector) is unchanged. That ban is genuinely coarse — per-address-space by nature — so it stays on
  the address space, which is the one job the address space is actually suited to. Genuinely unmanaged
  pointers (C interop, raw arithmetic) stay integral `addrspace(0)` and keep their integer tricks.
- **Move classification to a value-level signal.** Whether a value is a live root the collector roots
  and relocates here is answered by a **precomputed managed-value set** fed to a forked RS4GC predicate
  `isGCManagedValue(Value*)` = set-membership **or** structurally-derived-from-a-set-member.
- **Build the set in a pre-pass**, run after `mem2reg`/`sroa` and immediately before RS4GC (so it
  classifies the value graph RS4GC actually sees). Seeds come from durable anchors that survive the
  earlier passes — allocator-call returns (recognized by symbol), managed arg/return attributes, loads
  classified through the frontend field-type map — then forward fixpoint propagation through the
  pointer-deriving ops (`gep`/`phi`/`select`/`call`/`load`) reaches closure. A verifier check at every
  `phi`/`select` enforces consistency (no managed/unmanaged merge), which the frontend's residency
  inference already guarantees by construction.

This dissolves two walls with one mechanism:

1. **The conditionally-managed-pointer ABI wall.** A pointer that is a reference in some cases now has
   one stable type, `ptr addrspace(1)`, because "could this ever be a reference" has a stable per-slot
   answer. Whether it is a live root *right now* — the part that genuinely varies per value — is the
   value set plus the shape descriptor.
2. **The addrspace-across-calls stack-promotion wall** ([148 §148.1](148-ssair-optimizer-tier.md)). A
   stack-promoted object crosses a non-inlined call as `ptr addrspace(1)` with one ABI type. The callee
   roots it uniformly; at runtime the collector sees the root's address lies in a stack frame, declines
   to move it (relocate is a no-op), and traces its fields in place via the caller's frame-root field
   map. This is the unblock §148.1's summary-consumption work was parked on.

## Why — option comparison (runtime performance is the deciding axis)

Four ways to give RS4GC a signal other than the address space were weighed. Runtime cost is the emitted
machine code plus collection behavior; the emitted code is fixed by the IR reaching RS4GC and the
classification it applies. An option ties the status quo on runtime exactly when it feeds RS4GC the same
classification without perturbing the IR the mid-end optimizes.

- **A — precomputed managed-value set + forked predicate (chosen).** Changes RS4GC's classification
  *input*, leaves its *lowering* alone. Ordinary heap roots emit identical statepoints and `gc.relocate`s;
  the mid-end optimizes identical IR (types unchanged, `ni` kept). The added cost is compile-time (the
  pre-pass) with no runtime footprint.
- **B — attribute/metadata carrier.** Ties A on runtime (the carrier is passive). Its in-IR seed is
  droppable on the one fragile seed — the interior load of a managed field, whose managedness is not
  structurally recoverable — in a way that silently loses a root (a use-after-free under GC stress).
  Every fix for that drives B back into A's re-derivation. Loses on safety, not speed.
- **C — intrinsic/token wrapper.** To carry the signal it must survive the mid-end, where it acts as an
  optimization barrier and breaks SSA value identity → worse emitted code. Its only parity path is to
  insert wrappers late, which needs A's analysis anyway, collapsing into A. Capped below A on runtime.
- **D — a different type signal.** No referent under opaque pointers — the address space is the only
  type-level bit on a `ptr`, so D reduces to picking another address-space number, which is the status
  quo. Does not solve the problem.

Runtime being king, and B/C/D each failing it (B on the safety tiebreak, C structurally, D entirely), A
is the direction.

## Relationship to 176 and the `String` `small` case

[176 shaped GC roots](176-shaped-gc-roots.md) is the **piggyback alternative**: it handles
value-conditional roots on the *existing* `addrspace(1)`-means-managed model, through deopt-operand side
records, **without forking RS4GC**. 179 forks RS4GC classification and unifies the address-space meaning.
They overlap on the pointer cases and diverge on scope. Move 1's measurement partly decides between them:
if the win is mostly conditional roots, 176's side path suffices; if it is mostly stack-promotion across
calls, 179 is what earns it.

The `String` `small` case stays [176](176-shaped-gc-roots.md)'s shape-descriptor job under **both**
models. That word bit-puns a heap pointer against inline UTF-8 **bytes** in one 64-bit slot, and `ni`
protects pointers — you cannot store raw bytes into a non-integral pointer. Pointer/non-pointer
bit-stealing is a different problem than conditional rooting. 179 dissolves the ABI wall for pointers
that stay pointers; the bit-punned word still rides 176's `kind 2` shape descriptor. 176.3's frame-root
field-map is a building block 179 reuses for the stack-promotion case.

## Performance expectation

- **Common mutator path:** unchanged. RS4GC lowering is identical, classification is compile-time only,
  and the mid-end optimizes the same IR because `ni` is kept and types pre-RS4GC are unchanged. No
  regression to offset the win.
- **Collection:** recognizing a stack-frame root is a per-root heap-bounds check that folds into the
  per-root space classification the collector already performs (immortal / nursery-vs-mature /
  large-object). It is per root, not per traced object, and a stack-promoted object does no
  heap-lifecycle work at all (no alloc, no evac copy, no reclamation, no fragmentation of a moving
  space).
- **Dominant term:** interprocedural stack promotion unlocked → fewer heap allocations, a smaller live
  set, fewer collections, promoted objects dying with their frame for free. Net faster, floor near
  parity, magnitude workload-dependent and measurement-gated (155/159).

## Commit gating — three moves before building

**Move 1 — bound the payoff before building, attributed by feature.** Run the escape analysis
([169](169-interprocedural-escape-summary.md)) over representative code and count the allocation sites
that are provably non-escaping yet forced to the heap *because they cross a non-inlined call* — the exact
population 179 unblocks. Weigh it dynamically (allocations + bytes on real workloads). Hand-promote one
or two hot cases and measure the delta. Report the number **net of what 176's side path already
captures**, since only the stack-promotion-across-calls population requires 179. If that net is small,
ship 176 and stop here — the cheapest outcome.

**Move 2 — size the low-level risk with a spike.** Determine whether value-level classification enters
RS4GC through a supported extension point or requires patching the pass itself (the hook takes a `Type*`,
so a value predicate most likely means a fork). Measure the patch size and whether it rebases cleanly
across an LLVM version bump — a correctness-critical pass where a classification bug is memory unsafety.
This is the analog of the deopt-operand spike already run for 176 and it sizes the one genuinely
low-level piece before commitment. If the answer is "a large fork that fights every upgrade," that
reshapes the decision.

**Move 3 — stage the build behind an equivalence oracle.** The dangerous phase has a perfect oracle: the
current addrspace predicate. See phase 179.1.

The one part with no historical oracle is the collector-side behavior (stack-frame recognition,
frame-root field-map trace, pinned relocate-as-no-op), because nothing today stack-promotes across calls.
The two-collector world (kept for benchmarking, not retired yet) is its differential check, alongside the
`Tn` GC-stress obligations.

## Phases (if it clears the gates)

- **179.1 — classifier at parity (the oracle step).** Land the pre-pass and the forked
  `isGCManagedValue` predicate *defined to reproduce the status-quo answers exactly* — the value set is
  "the `addrspace(1)` pointers, and nothing else." Run the new predicate and the old type predicate in
  parallel and assert they agree on every value across all existing code and the full GC-stress suite,
  at benchmark parity. Proves the new plumbing correct and cost-neutral before it classifies anything
  new.
- **179.2 — address-space repurposing.** `addrspace(1)` = "may be a managed reference, do not launder";
  unmanaged pointers → `addrspace(0)`; `ni:1` kept, so the laundering ban is unchanged. Frontend codegen
  emits the one managed address space uniformly (broad but mechanical).
- **179.3 — widen the set + the RS4GC fork.** Extend the value set to conditionally-managed values and
  turn on the predicate's structural-derivation half (closure under `gep`/`phi`/`select`/`call`, plus
  RS4GC's own base phis and relocate results). The fork from move 2 lands here. Verifier consistency
  check at merges.
- **179.4 — collector: pinned frame roots.** Stack-frame root recognition (the heap-bounds check),
  frame-root field-map trace, relocate-as-no-op for a pointer whose address lies outside the managed
  heap. Both collectors, in lockstep; the `Tn` obligations and the cross-collector fingerprint are the
  oracle-free behavior's check.
- **179.5 — consume the escape summary (closes 148 §148.1's remaining work).** Wire `StackPromotion` to
  read the stored interprocedural summary ([169](169-interprocedural-escape-summary.md)) and actually
  stack-promote across non-inlined calls. This is the payoff move 1 bounded.

## Dependencies & relationships

- **[148 §148.1](148-ssair-optimizer-tier.md)** owns the escape-promotion *consumption*; 179 provides
  the *placement mechanism* that §148.1's summary-consumption was waiting on, superseding the
  route-(c)/[176 §176.3](176-shaped-gc-roots.md) selection as the way across the addrspace wall (the
  frame-root field-map from 176.3 is reused as a building block). 179.5 closes that consumption item.
- **[176 shaped GC roots](176-shaped-gc-roots.md)** — the alternative/complementary piggyback; see the
  relationship section. Not a dependency in either direction; move 1 weighs them against each other.
- **[121 String](121-string-utf8-model.md)** — related, independent. 179 does not gate 121; the `small`
  bit-punned word stays 176's shape path regardless of the address-space model.
- **[169](169-interprocedural-escape-summary.md) / [166](166-points-to-graph.md) /
  [168](168-scc-fixpoint-engine.md) / [164](164-formal-inference-stage.md)** — the done inference stack
  that computes residency (feeds the value-set seeds) and the escape summary (feeds promotion, 179.5).
- **[177 register-resident GC roots](177-register-resident-gc-roots.md)** — an independent perf lever on
  top; applies to the unified model the same as to the status quo.
- **[150 GC ladder](150-selfhosted-gc-ladder.md) / [155 harness](155-integration-suite-harness.md) /
  [159 GC observability](159-gc-observability.md)** — move 1's measurement and the final perf validation
  run with the GC-benchmarking step. The two-collector world is kept for the oracle-free collector
  behavior.
- **Rests on** the statepoint / stack-map substrate (`internals/backend.md`, "GC backend substrate"),
  `internals/memory-model.md` §6, and the non-integral-pointer (`ni`) datalayout mechanism.

## Open questions / risks

- **RS4GC fork vs supported extension point** — move 2 spike; the biggest single risk.
- **`ni` granularity.** The laundering ban is per-address-space, so the one managed address space must
  carry exactly the possibly-managed pointers while unmanaged pointers stay `addrspace(0)`. Confirm no
  interop pointer needs to be both laundering-protected and integer-punnable at once.
- **Net payoff** over what 176's side path already captures — move 1.
- **Stack-promotable `StringStorage` buffer (future, loose).** 179.4's pinned frame roots plus 179.5's
  cross-call promotion could let a non-escaping [121](121-string-utf8-model.md) `String` place its `heap`
  buffer on the stack, with `word1` pointing into a frame; 176's shape-descriptor trace path would then
  need the same stack-range / pin-in-place handling. Additive to 121's design, not a change to it. Wants
  real design when reached; far out, so left ambiguous here.
