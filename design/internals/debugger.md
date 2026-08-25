# Debugger

**Status:** working draft — the plan. The debugger is not yet built (targeted around M11); this doc fills in as it is. Where debug info comes from in the pipeline is [`noir.md`](noir.md) / [`ssair.md`](ssair.md) (the span invariant) and [`backend.md`](backend.md) (`DIBuilder`). Status tags: **Decided**, **Deferred**, **Open**.

Do **not** build a debugger from scratch. **Emit DWARF and extend lldb.** — **Decided.**

Choosing LLVM + native binaries means breakpoints, stepping, unwinding, watchpoints, and remote/time-travel debugging already exist on our binaries the moment we emit correct debug info (Rust and Swift both took this route). The real work is making existing tools understand *our* semantics — the abstraction gap widened by monomorphization, match lowering, closures-as-structs, and fibers suspended across the scheduler. DWARF is the bridge; its quality depends on debug info surviving every IR pass (the source-span invariant, [`noir.md`](noir.md) / [`ssair.md`](ssair.md)).

## Tiered plan

- **Tier 0 (near-free):** DWARF line tables + basic types → breakpoints, stepping, backtraces, primitive inspection.
- **Tier 1:** DWARF 5 **variant parts** for enums (discriminant + payload, as Rust does) + reference/value layout + **lldb data formatters** (render an enum as its active case, a COW array as its contents).
- **Tier 2:** GC-aware stepping (skip compiler-inserted barrier/safepoint frames so stepping stays in source); a debug-build mode that limits escape-analysis/optimization so inspection works.
- **Tier 3 (hard, differentiating):** a **runtime-aware plugin** presenting a *logical* view — reconstruct backtraces across suspension points, list live tasks by their structured-scope tree, inspect actor state + pending mailbox. The structured-concurrency + actor model makes this possible in a way Go's detached goroutines can't.

## Pragmatics

Target the **Debug Adapter Protocol** (lldb ships `lldb-dap`) → every editor for free. On Linux, **`rr`** gives reverse/time-travel debugging on standard native binaries.

## Open

- **Runtime-structure layout** for the Tier-3 plugin (task tree, actor mailbox) — must be exposed with a stable layout, co-designed with the scheduler/actor runtime (`concurrency.md`, `runtime.md`), not bolted on.
