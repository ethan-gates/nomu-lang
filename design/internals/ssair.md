# SSAIR — the optimizer tier (M7)

**Status: Built — M7 done (2026-08-24).** SSAIR is the sole backend path; the NOIR→LLVM tree-walk was retired at M7.7. This is the as-built **design home** for the tier — the *why*, the IR shape, the decisions (with the alternatives rejected along the way), the pass framework, and the GC-precision invariants every pass must preserve. Escape-analysis-as-built is in `memory-model.md` §6.1; the GC/statepoint substrate the tier rests on is `backend.md`; NOIR (the structured IR that lowers into SSAIR) is `noir.md`. Remaining refinements are in `plans/tasks/148-ssair-optimizer-tier.md`; the phased build history + per-slice records are in git + the code.

**One-line intent.** **SSAIR** is a lower, control-flow-explicit, SSA intermediate representation — a separate IR from NOIR (its own types, dumper, files), the level where the language-aware optimizations that carry the "faster than Swift/Go" thesis run. Structured NOIR lowers into SSAIR; SSAIR lowers to LLVM. It is Nomu's analog of **Rust's MIR / Swift's SIL**, sitting below THIR-altitude NOIR and above LLVM IR. (Named 2026-08-14; the sibling to NOIR, both ending in IR.)

## Why a separate tier (the altitude argument)

LLVM optimizes at the wrong altitude for four wins Nomu needs, because by the time code is LLVM IR the language facts are erased:

- **Precise escape analysis** — LLVM will not un-heap a `__nomu_gc_alloc` call; it sees an opaque runtime call, not an allocation whose lifetime we can prove local (`memory-model.md` §6.1).
- **Devirtualization of witness-table calls** — an `any I` / generic dispatch is an indirect call through a loaded function pointer at the LLVM level; the fact that the concrete conformer is knowable is a Nomu-level fact, gone by codegen.
- **Bounds-check elimination** — the check is a Nomu semantic guarantee on `index`; LLVM sees a compare-and-branch with no knowledge that it is redundant with a prior check or a loop bound.
- **Inlining + specialization on our type info** — on top of the existing whole-program monomorphization (M5), driven by Nomu-level cost and type knowledge rather than LLVM's post-lowering heuristics.

Structured NOIR can't host these either: they need **def-use chains and a CFG to follow values across control flow**, which the nested `if`/`switch`/`while` tree lacks. The conservative escape pass shipped in M6 (`memory-model.md` §6.1) is exactly what you can do without them — intra-procedural, single-walk, no flow sensitivity — and its ceiling is why the precise pass waited for this tier.

**Design against the whole tenant set at once (Decided 2026-08-13).** SSAIR is shaped to serve precise EA, devirtualization, BCE, and inlining/specialization together, so its form is validated against all four before it freezes. Building it for one pass would bake in a shape the others fight.

## Position in the pipeline

```
source → lexer → parser (AST) → semantic pass → NOIR (structured, noir.md)
       → monomorphization (M5)
       → LOWER TO SSAIR  ← the M7 tier
       → optimizer passes (devirt → inline → EA/promotion, BCE)
       → lower to LLVM IR → statepoint rewrite → object code
```

The tier lands **after monomorphization** (passes see concrete types, no type parameters) and **before LLVM lowering**. **Single path (Decided 2026-08-14; realized M7.7):** the SSAIR→LLVM step *replaced* the direct NOIR→LLVM tree-walk. Both debug and release run `NOIR → SSAIR → LLVM`; debug runs SSAIR with zero/few passes, release runs the full set. The two paths co-existed transiently behind a differential oracle (the pre-M7 compiler); once the corpus differential was byte-identical the NOIR→LLVM tree-walk was **deleted (2026-08-24)**, leaving SSAIR the only egress. *(Rejected keeping both permanently — a duplicated GC ABI is a silent-miscompile surface; the shared `LLVMGen` emitter kept the ABI in one place during coexistence.)* Debug routes through SSAIR, it does not skip it.

## IR shape (as built)

- **Functions are a CFG of basic blocks.** Each block is a straight-line list of instructions ending in one **terminator** (`br`, `condBr`, `switch`, `ret`, `unreachable`). Structured control flow from NOIR (`if`/`switch`/`while`, `break`/`continue`) lowers to blocks + terminators here — the one place the structured tree is flattened.
- **SSA values with block arguments** (the Swift/MLIR style) rather than φ-nodes — the value flows with the edge, so CFG edits don't fix up predecessor-named φ lists. Each value is typed (carries the NOIR `Type`, concrete post-mono); dominance is explicit. **SSA is built by direct construction during lowering-in** (Braun et al. — track the current value per variable, insert block args at joins, seal loop back-edges), not alloca-then-mem2reg. *(Rejected alloca-everything + mem2reg: the tier is above LLVM, so there is no mem2reg to lean on — that path re-writes the same φ-insertion machinery plus a slot layer to carry and delete, and hides GC pointers from EA until promotion runs. Nomu has no address-of, so every local is trivially an SSA candidate.)*
- **Value aggregates use slots (Option B, Decided 2026-08-16).** Scalars and reference types stay pure SSA; a mutable value-type aggregate (`struct`/`enum` local) lives in a `stackAlloc` slot (`fieldAddr`/`load`/`store`), GC-safe via the frame stack map. *(Rejected functional-update: a first-class pointer-bearing SSA aggregate hits the LLVM FCA/`gc.statepoint` limitation across a safepoint — I10 below. SSA-above-LLVM practice is slots: SIL address-only types, Go SSA decompose-else-memory.)* EA's scalar promotion later scalarizes safe slots (`memory-model.md` §6.1).
- **Explicit memory + allocation ops.** `alloc` (the site EA reasons about, lowering to `__nomu_gc_alloc` by default), `stackAlloc`, `load`/`store` with the **GC address space** attached (addrspace 1 = managed, 0 = stack), field GEPs, and the **write-barrier** as an explicit op so barrier elision is a pass over this IR. This is what lets precise EA rewrite an `alloc` to a stack slot and drop the barriers that fed it. **`boundscheck`** is likewise an explicit op (index, length) so BCE is a pass that proves it redundant and deletes it; the egress lowers a surviving check to the trap form.
- **Explicit dispatch ops.** A call carries its dispatch kind — `direct` (known target), `witness` (through a witness-table slot, the devirt target), or `indirect` (closure/fn-pointer). Devirtualization is a rewrite from `witness` to `direct`, which then unlocks inlining.
- **Closures lowered to explicit environments.** Closure conversion moves here (out of the old codegen): a closure becomes an explicit env struct + a direct/indirect call, so the optimizer sees the capture set as ordinary values (feeds scalar-capture EA, `memory-model.md` §6.1).
- **Pattern matches lowered to decision trees / switch terminators** — exhaustiveness already checked upstream (`noir.md`), so this tier sees only the lowered branch form.

**Preserved by construction (every pass holds these):** **types** on every value (concrete post-mono); **source spans** on every instruction (debug info is threaded from the front and must survive every pass — the DWARF quality the debugger rests on depends on it, `debugger.md`; dropping a span is a bug); **GC precision info** (address spaces + which values are managed roots).

## Pass framework

- **Two pass kinds:** *analyses* (side tables keyed by value/site identity, mutate nothing — the escape result, dominator tree, alias facts) and *transforms* (rewrite the IR, invalidating analyses). The M6 conservative EA already uses the side-table shape, so its precise replacement slots into the same codegen consumer contract, **reused unchanged** (`memory-model.md` §6.1).
- **A pass manager** with explicit analysis dependencies + invalidation. Small and hand-rolled; no need to mirror LLVM's.
- **Ordering (as built):** devirtualize → inline/specialize → (EA/promotion, BCE) on the now-concrete, inlined bodies. Devirt-before-inline matters: a `witness`→`direct` rewrite is what makes a call an inlining candidate, and inlining is what makes intra-procedural EA and BCE see across the old call boundary. Each pass is A/B-gated (`NOMU_NO_DEVIRT`/`NOMU_NO_INLINE`/`NOMU_NO_ESCAPE`/`NOMU_NO_SCALAR`) so a regression is bisectable, and `verifySSAIR` re-checks the GC-precision invariants (below) after every pass.

## The four passes (as built)

1. **Precise flow-sensitive escape analysis** (`memory-model.md` §6.1) — def-use + CFG follow a pointer across branches and through the now-explicit closure envs. Two rewrites: **stack promotion** (a non-escaping class / closure object / `any`-box → a `stackAlloc`, barriers dropped) and **scalar promotion** (a loop-carried non-escaping class, which flows through a block-param φ that LLVM's SROA can't un-heap, is decomposed into per-field SSA values). Replaced the M6 conservative front-end; the codegen consumer is unchanged.
2. **Devirtualization** — a `witness`/`any` call whose concrete conformer is known (a `some`/opaque underlying, a monomorphized instance, or a locally-constructed box) is rewritten `witness` → `direct`.
3. **Inlining + specialization** — single-block splice and multi-block CFG surgery (with a return-φ join) to a bounded fixpoint. "Specialization" means **value/constant** specialization (mono already specializes on *types* whole-program) — the cost model + value specialization are backlogged.
4. **Bounds-check elimination** — **the loop-bound case was descoped**: `for … in` (+ ranges) is the bounds-check-free-by-construction path, so proving hand-written index loops safe proves something idiomatic code won't write. The retained residual (dominating-redundant + constant-fold) is a deferred cleanup.

The IR is designed so all four compose (see ordering), rather than as four independent bolt-ons. Interprocedural EA, cost-model inlining, and the closure/spawn-env promotions are the backlogged tails (`plans/tasks/148-ssair-optimizer-tier.md`).

## Lowering out to LLVM

`LLVMGen` is the shared GC-ABI emitter (address spaces, the `__nomu_gc_alloc`/`__nomu_write_barrier`/`__nomu_poll` hooks, object/witness/any-box layout, the `gc "statepoint-example"` attribute, calls); `SSAIRToLLVM` is a CFG-walk egress that holds one `LLVMGen` and lowers through its primitives — the only egress since M7.7. The mapping is close to mechanical: blocks → LLVM basic blocks, SSA values → LLVM values, block args → LLVM φ, the `alloc`/`store`/barrier/dispatch ops → the emitted forms. Because SSAIR values are already SSA (no alloca-per-scalar-local), the statepoint rewrite sees SSA-valued GC pointers directly — the mem2reg-before-statepoint dependency is gone for scalars. Statepoint insertion stays **late** (post-opt, at the LLVM level, `backend.md`).

## GC-precision invariants (the tier's soundness contract)

EA is the first pass to rewrite a managed allocation into a stack slot and drop write barriers, so the tier's soundness under the moving collector rests on the invariants below. Bugs here are **silent** (relocation corruption, non-deterministic), so each is enforced two ways: the **`In` checks** by `verifySSAIR` (a compiler self-check run after every pass, debug + release today — `SSAIRVerify.swift`), and the **`Tn` obligations** by forced-GC differential scripts (`tools/gc-*.sh`, `escape-nonleaf.sh`, `scalar-carried.sh`) in CI. The underlying statepoint/root/barrier machinery is `backend.md`.

*Master property.* With the tier ON, the root set recovered at each safepoint and the set of executed write barriers are a **justified refinement** of the tier-OFF program — every removal individually licensed by an invariant below, nothing otherwise-needed dropped or added.

- **I1** — every value's address space is preserved; `addrspace(1)` (managed) stays managed unless a transform soundly re-provenances it (only EA promotion, I4).
- **I2** — no transform introduces an `addrspace(0)→(1)` reinterpretation (the statepoint rewrite rejects a GC base from a differing-addrspace cast); only sound `1→0` narrowing at C-ABI boundaries.
- **I3** — a value is a GC root at a safepoint iff it is a managed value live across it; the recovered root set equals the un-optimized set modulo values the tier legitimately made dead or stack-local.
- **I4** — stack/scalar promotion applies only to an allocation proven non-escaping; when unsure it escapes (the fallback is always heap — a false "non-escaping" is the one unsound direction).
- **I5** — a promoted object's managed fields stay precisely scannable: each `addrspace(1)` field is SROA'd (stack promotion) or decomposed into a statepoint-tracked SSA root (scalar promotion) — never a stack object holding a managed pointer no root map describes.
- **I6** — promotion never extends a lifetime past the frame (corollary of I4).
- **I7** — a barrier is elided only where the store cannot create an untracked old→young reference (into a stack slot, or an initializing store into a fresh nursery object); a store into a mature heap object keeps it.
- **I8** — a transform that moves/copies a store carries its barrier obligation with it (inlining preserves a callee's heap-field-store barrier).
- **I9** — safepoint coverage is preserved: no transform deletes the last safepoint from a loop or creates an unbounded safepoint-free region (the egress's unconditional loop-header poll + faithful block cloning under inlining hold this).
- **I10** — a managed value live across a safepoint stays a first-class SSA `addrspace(1)` value; no transform sinks it into a by-value aggregate embedding a GC pointer across a statepoint (the FCA limitation — why value aggregates use slots, and why scalar promotion decomposes to per-field SSA values rather than an aggregate φ).

*Test obligations (`Tn` — forced-GC differentials with a ground-truth oracle; "runs without a crash" is not a pass):* A/B × collector byte-identical over the corpus (T1); forced evacuation of a promoted object's interior pointer (T2 — `escape-nonleaf.sh`, `scalar-carried.sh`); barrier obligations under a minor GC (T3); exact tier-on root-set introspection (T4); corpus root/barrier differential at scale (T5); safepoint coverage after inlining (T6); randomized differential (T7, deferred to M12).

## Build history

The tier shipped in phases **7.1** modularization → **7.2** SSAIR + inert lowering (differential-verified byte-identical to the pre-M7 compiler before any pass ran) → **7.3** pass manager + precise EA (stack + scalar promotion) → **7.4** devirtualization → **7.5** inlining → **7.6** perf validation → **7.7** NOIR oracle retired. Each pass is A/B-gated so the tier is switchable and a regression bisectable. The full phased plan + per-slice records lived in the `m7-spec` build plan, retired on completion; git and the code are the record.

## Open questions / tails

- **Inlining cost model** — what drives the heuristic (callee size, call-site hotness, specialization); value/constant specialization on top.
- **Interprocedural EA summary** — how much survives without whole-program iteration to fixpoint; whether monomorphization's whole-program view makes a cheap summary enough.
- **Debug info through inlining** — inline-site DWARF records, or defer.
- **Alias/effect model** — how much aliasing precision the passes need before the cost outweighs the win.
- **Artifact/dump format** — the tier reuses a flat textual SSA dump (`dumpSSAIR`); whether it hardens into a versioned round-trippable format is the IR-hardening item (`plans/tasks/142-ir-pipeline-hardening.md`).

The full backlog of tier work (passes, analyses, infra, validation) is `plans/tasks/148-ssair-optimizer-tier.md`.
