# Compiler architecture — the pipeline

**Status:** working draft, as-built. The whole-flow entry point: how the stages connect, and the interface/implementation module split they're built on. Each subsystem has its own doc — [`noir.md`](noir.md) (mid-level IR), [`ssair.md`](ssair.md) (optimizer tier), [`backend.md`](backend.md) (LLVM codegen + GC substrate + mangling), [`tooling.md`](tooling.md) (query architecture), [`debugger.md`](debugger.md).

**Implementation language:** Swift (decided) for the compiler itself.

## The pipeline — two representations, Rust-staged

```
source → lexer → parser (untyped AST) → semantic pass → NOIR (typed, structured)
       → IR passes → SSAIR (CFG/SSA optimizer tier) → LLVM → native binary
```

There are deliberately only two trees above the optimizer tier: the untyped **AST** (parser output) and one **typed structured IR** — NOIR — the semantic pass builds *directly* from it. There is no separate "typed AST" step, because the AST is immutable `enum`s and can't be annotated in place the way Swift decorates its mutable AST. NOIR ≈ **Rust's THIR** ([`noir.md`](noir.md)); the lower CFG/SSA level — the SSAIR optimizer tier ([`ssair.md`](ssair.md)) — ≈ **Rust's MIR / Swift's SIL**. NOIR lowers into SSAIR, and SSAIR is the sole backend egress to LLVM ([`backend.md`](backend.md)).

Debug info is threaded from the front: every NOIR and SSAIR node is typed and carries a source span, preserved by every pass ([`noir.md`](noir.md), [`ssair.md`](ssair.md); the DWARF the debugger rests on depends on it, [`debugger.md`](debugger.md)).

## Interface / implementation module split — Decided (2026-08-16), built (M7)

Each IR is its own **interface module** (its format: the types + dump), separate from the **implementation modules** that produce and consume it:

`support` | `ast` / `parse` | `noir` / `sema` | `midend` | `ssair` / `ssairgen` / `ssairpasses` | `llvmgen`

The interface module is the structural home for the phase-output-format and format-stability work (deferred; see `plans/deferred.md` "Pipeline boundary hardening"), and the dependency surface the query architecture ([`tooling.md`](tooling.md)) memoizes against. Built as the first M7 slice; the module layout is the record.

## Committed capabilities — architecture evaluation (2026-07-30)

Three capabilities are committed and the code is checked so it doesn't quietly foreclose them (the rule: C-backend-only limits are throwaway; only frontend/IR/LLVM-path gaps count):

- **Debug info** ([`noir.md`](noir.md), [`debugger.md`](debugger.md)) — safe; the span invariant is held.
- **Fine-grained incremental compilation** (intra-module, per-file) and the **query server** ([`tooling.md`](tooling.md)) — the *same* engine (memoized per-decl queries + fingerprint invalidation). Prerequisites (multi-file input, per-unit codegen, dependency/fingerprint layer) are unbuilt but not foreclosed; the soundness property that makes it work — **modular checking** (bodies depend only on referenced signatures) — is held.
- The **one live blocker** is in the frontend and survives to LLVM: the lexer/parser/typechecker **`exit(1)` on first error** with no recovery, contra the query-server commitment. Actionable backlog: `src/frontend/README.md`.
