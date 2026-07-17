# Compiler & Toolchain

**Status:** working draft. The home for how Nomu is built — compiler architecture, the mid-level IR, backend strategy, the tooling-first stance, and the debugger plan. Status tags: **Decided**, **Deferred**, **Open**.

**Implementation language:** Swift (decided) for the compiler itself.

---

## 1. Mid-level IR above the backend

Build a typed **mid-level IR** between the typed AST and the code-generation backend (analog: Swift's SIL). Semantics-aware passes run on *this* IR, then lower to the backend. — **Decided.**

Passes that run on the mid-level IR:
- **monomorphization**
- **exhaustiveness checking**
- **escape analysis** (`memory-model.md` §6.1)
- **GC safepoint / barrier insertion**
- **closure conversion**
- **share analysis** — materializing shareability into module interfaces (`concurrency.md` §5)

The backend (LLVM) does not understand the language's semantics, so running these passes on LLVM IR would be the wrong altitude. The IR also carries **debug info** (source spans, variable identity) through every pass — threading it in from day one is cheap; retrofitting is miserable, so it goes in from the start.

(The pass list changed with the memory-model pivot: ARC insertion / refcount elision / isolation-region checks are gone; escape analysis and GC barrier/safepoint insertion take their place, and monomorphization gains importance as a performance lever.)

---

## 2. Backend strategy

- **Prototype: emit C or bind a simple backend** — throwaway scaffolding to get native execution fast and validate the surface + type system + runtime integration without building production codegen. — **Decided (direction).**
- **Release builds: LLVM**, for peak native performance, driven via a stable interface. — **Decided (post-prototype).**
- **Debug/dev builds: consider Cranelift** for fast compiles. — **Deferred.**
- **MLIR** if heavy language-specific optimization is wanted. — **Open.**

LLVM is right eventually but is a big time sink that obscures the early questions, so the prototype gets native execution by a cheaper route first. The **GC integration (via MMTk)** is the real, new backend work:

- **precise stack maps / safepoints** (needed because Immix/LXR move objects),
- **the object model** (how to scan an object for references),
- **write-barrier insertion**.

This is the gating runtime engineering and must be co-designed with codegen.

---

## 3. Tooling-first / query architecture

Architect the compiler **as a server** from early on — query-based, so an LSP can cheaply ask "what's the type here?", with incremental compilation and stable parser error-recovery. — **Decided (architectural commitment).**

Great tooling (Rust, TypeScript) comes from designing the compiler as a server early, not bolting an LSP on later. Tooling is one of Nomu's deltas over Nim and a first-class deliverable, so this is committed up front while it's still cheap.

---

## 4. Debugger

Do **not** build a debugger from scratch. **Emit DWARF and extend lldb.** — **Decided.**

Choosing LLVM + native binaries means breakpoints, stepping, unwinding, watchpoints, and remote/time-travel debugging already exist on our binaries the moment we emit correct debug info (Rust and Swift both took this route). The real work is making existing tools understand *our* semantics — the abstraction gap widened by monomorphization, match lowering, closures-as-structs, and fibers suspended across the scheduler. DWARF is the bridge; its quality depends on debug info surviving every IR pass (§1).

**Tiered plan:**
- **Tier 0 (near-free):** DWARF line tables + basic types → breakpoints, stepping, backtraces, primitive inspection.
- **Tier 1:** DWARF 5 **variant parts** for enums (discriminant + payload, as Rust does) + reference/value layout + **lldb data formatters** (render an enum as its active case, a COW array as its contents).
- **Tier 2:** GC-aware stepping (skip compiler-inserted barrier/safepoint frames so stepping stays in source); a debug-build mode that limits escape-analysis/optimization so inspection works.
- **Tier 3 (hard, differentiating):** a **runtime-aware plugin** presenting a *logical* view — reconstruct backtraces across suspension points, list live tasks by their structured-scope tree, inspect actor state + pending mailbox. The structured-concurrency + actor model makes this possible in a way Go's detached goroutines can't.

**Pragmatics:** target the **Debug Adapter Protocol** (lldb ships `lldb-dap`) → every editor for free. On Linux, **`rr`** gives reverse/time-travel debugging on standard native binaries.

Exposing runtime structures (task tree, actor mailbox) with a stable layout must be co-designed with the runtime, not bolted on.

---

## 5. Library tiers (language / runtime / stdlib)

The build realizes a three-layer separation (positioning in `vision.md` → "Library tiers"):

- **Language** — the compiler-known surface (type system, generics, interfaces, linear types, and a small named set of blessed intrinsics such as the continuation).
- **Runtime** — the mandatory floor: GC (MMTk) + the M:N scheduler/poller. **Always linked** — there is no runtime-less build, because Nomu declines to define reference types or heap allocation without it.
- **Standard library** — ordinary Nomu code with no compiler privilege, and **elidable**.

Two deployment shapes fall out: **language + runtime** (no batteries; minimal footprint) and **+ stdlib**. The consequence for the compiler: privileged capabilities (`park`/`unpark`, GC intrinsics) are reached only through **language/runtime intrinsics**, never handed to a stdlib function that user code couldn't itself call — that is what keeps the stdlib pure and elidable. — **Decided (2026-07-16).**

## 6. Open questions

- **MLIR vs. plain LLVM** for the release backend (§2).
- **Cranelift** for fast debug builds — when it earns its place (§2).
- **Incremental compilation + cached monomorphizations** — the shape that keeps LLVM iteration bearable.
- **Runtime-structure layout** for the Tier-3 debugger plugin — co-designed with the scheduler/actor runtime (`concurrency.md`).
