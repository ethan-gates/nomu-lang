# M8 — Implementation Spec (LLVM Backend)

**Status:** working draft — the ordered work plan for M8, derived from `compiler.md` (§1 IR,
§2 backend strategy, §4 debugger, §6 C→LLVM transition checklist), `memory-model.md` §3/§6,
and `runtime.md`. It pins the build sequence; the design lives in those docs. **Design is
opening** — the big backend forks (8.0.4) are `Open`; this records them and a phased sketch,
not a settled plan.

> Authoring conventions per `lang-project/milestone-doc-guide.md`.

**Build status (2026-07-31):** **not started — design-opening.** M8 is the **next build
milestone** (reordered before M6; `roadmap.md`). Target is **plain LLVM**, MLIR not pursued.
The three big forks (8.0.4) are now **Decided (2026-07-31)**: LLVM **C++ API behind a thin C++
shim** (A); **LLVM statepoints → stack maps** for GC roots + **no bespoke MIR** (B);
**LLVM-only, minimal-correct** scope (C). Phasing (8.1+) can now firm up.

**Framing correction:** the roadmap names M8 "real backend (LLVM)," but M8 is the
**convergence substrate for three later consumers**, not just a release-perf swap: the moving
GC (M6 — precise stack maps), cancellation (M7 — safepoint polls), and scheduler preemption
(`runtime.md`) all ride the **safepoint/statepoint machinery M8 emits** (`concurrency.md` §7).
So M8's safepoint design must be **triple-purpose** from the start, though M6/M7 build after.

**Prerequisites:** none hard — the typed IR (M4.9), whole-program monomorphization (M5), and
the C runtime (M4) all exist. M8 *replaces* the C emitter (`src/codegen/sources/CodegenIR.swift`,
~1340 lines of C-string emission) with LLVM lowering; the **C backend stays as a reference
oracle** for differential testing until M8 is green.

---

## 8.0 · Front matter

### 8.0.1 · Scope

**Ships in M8:**
- Structured typed IR → **LLVM IR**; native release binaries via the LLVM toolchain.
- **DWARF debug info** (Tier 0: line tables + basic types) via `DIBuilder` — the C backend got
  this free from `cc`; the LLVM path must emit its own (`compiler.md` §4, §6).
- The **GC substrate M6 needs** — precise **stack maps** + **safepoints** at calls/back-edges,
  and the **write-barrier insertion seam** (inert until M6, but the codegen hook exists).
- The **safepoint poll seam** M7 cancellation + runtime preemption ride.
- **Runtime as a linked library** — the C preamble (scheduler, poller, `rt_alloc`, `String`,
  `Closure`) compiled to a `.a` and linked, no more per-file inlining (`compiler.md` §6).

**Deferred** (design ref):
- **MLIR** — no language-specific-opt layer; plain LLVM (`compiler.md` §2). Reconsidered only
  if heavy custom optimization is later wanted.
- **Cranelift** debug-build backend — a later fast-compile play once LLVM iteration pain bites
  (`compiler.md` §2).
- **Incremental compilation + cached monomorphizations** — its own effort, tied to the query
  architecture (`compiler.md` §3, §7, §8); M8 must **not foreclose** it, not build it.
- **Own MIR (CFG/SSA)** — deferred with escape analysis / language-aware GC passes
  (`compiler.md` §1). LLVM IR is itself CFG/SSA, so M8 lowers the structured IR straight to it.
- **Debug Tier 1+** — enum variant parts, lldb formatters, runtime-aware plugin (`compiler.md` §4).
- **Perf items** — `ucontext`→hand-written asm, fiber-aware mutex, `Bool` as `i1`/`i8` — M8
  tail or follow-on (`compiler.md` §6).

### 8.0.2 · Compiler surface touched

Current: `… → typed IR → CodegenIR (emit C strings) → cc`. M8 replaces the last two stages.
- **New backend** — typed IR → **LLVM IR** via the **C++ shim** (module / function /
  basic-block construction, not string emission). The per-node lowering *logic* in `CodegenIR`
  carries over; the *string emitter* does not. `Mangle.swift` survives (symbol names are
  backend-neutral). New build component: the C++ shim lib + its Swift-facing interface.
- **Debug info** — `DIBuilder` threaded from the IR's spans (carried on every node, §1).
- **Runtime** — preamble carved into a compiled `.a`; codegen emits calls and links it.
- **Closure conversion / share analysis** — "still in codegen" today (§1); either kept inline
  in lowering or promoted to a pre-LLVM pass (8.0.4-B).

### 8.0.3 · Dependencies (sketch — firms up after 8.0.4)

```
8.1 (LLVM IR production: native hello-world via the chosen mechanism)
└─ 8.2 (full language lowering: every IR node → LLVM, C-backend parity)
   ├─ 8.3 (DWARF Tier 0 via DIBuilder)
   ├─ 8.4 (GC substrate: statepoints + stack maps + barrier/poll seams)  [serves M6/M7]
   └─ 8.5 (runtime → .a, link path)
8.6 (perf tail: ucontext→asm, i1 Bool, opt pipeline)   [descopable]
```

### 8.0.4 · Big design decisions

- **A · LLVM IR production: C++ API behind a thin C++ shim — Decided (2026-07-31).** Drive
  LLVM's full **C++ API** (not the narrower stable C-API) from a hand-written **C++ shim** —
  our own `.cpp` that uses LLVM internally and exposes a narrow, stable interface to Swift
  (the Rust `RustWrapper.cpp` pattern). Swift calls the shim; the shim calls LLVM; the C++
  complexity stays isolated and grows one wrapper function at a time. Chosen for scalability:
  full API reach (`DIBuilder`, statepoint intrinsics, the pass manager) with a controlled
  Swift↔native surface, vs. the C-API's capability ceiling or raw Swift/C++ interop against
  LLVM's templated headers. *Optional:* a throwaway textual-`.ll` spike in 8.1 to reach native
  fast before the shim is broad — a bootstrap, not the endpoint.

- **B · GC roots via LLVM statepoints; no bespoke MIR — Decided (2026-07-31).** Governed by
  *what integrates most easily with MMTk* (the stated criterion): MMTk needs **precise roots**,
  and LLVM **statepoints** (`addrspace(1)` GC pointers + `gc "statepoint-example"` +
  RewriteStatepointsForGC) emit exactly the per-safepoint **stack maps** whose slots the MMTk
  binding reports as roots — and statepoints are **purpose-built for *moving* collectors**
  (they thread the relocated pointer back out after GC), which Immix/LXR require. The
  shadow-stack alternative fights relocation and was already rejected (`m6-spec.md` 6.0.4).
  **No own MIR in M8:** LLVM IR is itself CFG/SSA, so lower the **structured typed IR straight
  to LLVM**; a bespoke MIR (≈ Rust MIR / Swift SIL — a low CFG/SSA form to host language-aware
  passes) is built only when **escape analysis** needs language types LLVM has discarded
  (`compiler.md` §1).

- **C · Scope fence: LLVM-only, minimal-correct — Decided (2026-07-31).** No MLIR, no Cranelift
  second backend, no incremental compilation in M8; debug info Tier 0 only; perf items (8.6) to
  the tail. Keeps M8 small and unblocks M6/M7 fast; must not *foreclose* incremental
  (`compiler.md` §8), but does not build it.

### 8.0.5 · Runtime posture

The C runtime (M:N `ucontext` scheduler, poller, timer heap, `rt_alloc`, `String`, `Closure`)
becomes a compiled `.a`. The alloc seam stays `rt_alloc` (routed to MMTk in M6). Safepoints M8
emits are **triple-purpose**: GC roots (M6), cancellation poll (M7), preemption (runtime). No
new surface syntax; no language-semantics change — M8 is a backend swap.

### 8.0.6 · Risks / watch items

- **C++ shim + LLVM version pinning** — the shim's Swift-facing interface + a pinned LLVM
  version are the blast radius; bazel + LLVM (+ Swift↔C++ shim) build integration is real setup
  work and the riskiest early unknown.
- **Statepoint discipline** — `addrspace(1)` hygiene and RewriteStatepointsForGC constraints
  (every GC pointer live across a safepoint must be discoverable); the object/pointer model
  must satisfy it (co-designed with `m6-spec.md` 6.1).
- **Differential correctness** — keep the C backend as an oracle; every example matches
  C-backend output until M8 is green.
- **Debug-info fidelity across lowering** — spans → DWARF through monomorphization /
  match-lowering / closures-as-structs (`compiler.md` §4).
- **C-isms in the current emitter** — `({ … })` statement expressions and `int64_t` `Bool`
  vanish under IR construction, but audit the lowering logic as it ports (`compiler.md` §6).

---

## 8.1–8.6 · Phased plan (sketch — firms up after 8.0.4)

## 8.1 · LLVM IR production — native hello-world ⬜
Stand up the **C++ shim** + Swift interop + bazel/LLVM build end to end: a trivial program
(`main` + arithmetic + `print`) lowered to LLVM IR through the shim, compiled, run. This slice
is mostly build/interop plumbing — the riskiest unknown, so it goes first. *Optional* de-risk:
a throwaway textual-`.ll` path to reach native output before the shim is broad. **Exit:** a
native binary from the LLVM path prints correctly; bazel + LLVM + Swift↔C++ shim integration
green.

## 8.2 · Full language lowering (C-backend parity) ⬜
Lower every typed-IR node to LLVM — value/reference types, `struct`/`enum`/`class`/`actor`,
`match`, closures, monomorphized generics, `any`/witness dispatch, `Result`, spawn/actors.
Approach: port `CodegenIR`'s per-node lowering to IR construction; closure conversion inline or
as a pre-pass (8.0.4-B). **Exit:** the full M5 example/test suite produces identical results
under the LLVM and C backends (differential).

## 8.3 · DWARF Tier 0 ⬜
Line tables + basic types via `DIBuilder` from IR spans. **Exit:** breakpoints, stepping,
backtraces, and primitive inspection work in lldb on an LLVM-built binary.

## 8.4 · GC substrate — statepoints + stack maps + seams ⬜  [serves M6/M7]
The safepoint/statepoint machinery: `addrspace(1)` GC pointers, `statepoint-example` GC,
RewriteStatepointsForGC → stack maps; the **write-barrier** insertion hook (inert until M6);
the **per-fiber cancellation poll** at safepoints (inert until M7). **Exit:** stack maps
emitted and parseable at every safepoint; a smoke test enumerates roots at a forced safepoint;
barrier/poll seams present and inert.

## 8.5 · Runtime as a linked library ⬜
Preamble → compiled `.a`; link path. **Exit:** no per-file preamble inlining; the runtime
builds once as `.a` and links; all examples run.

## 8.6 · Perf tail (descopable) ⬜
`ucontext`→hand-written arm64/x86-64 asm; `Bool` → `i1`/`i8`; LLVM opt pipeline (new pass
manager, `-O` levels); fiber-aware mutex. **Exit:** measurable improvement; correctness
unchanged.
