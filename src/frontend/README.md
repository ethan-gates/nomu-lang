# frontend/ — source → NOIR

The Nomu frontend — lexer, parser, AST, and the semantic pass (typed IR = NOIR). As of M7
§7.1 the old single `frontend` module is **split into per-stage modules** grouped under this
directory, with an interface/implementation separation (`design/internals/compiler.md` §8, `compiler.md`
§8):

- `frontend/ast` (Token, AST, ASTDump) — syntactic interface · `frontend/parse` (Lexer, Parser) — impl
- `frontend/noir` (NOIR, NOIRDump) — typed-IR interface · `frontend/sema` (Sema, Typechecker,
  Builtins, Exhaustiveness, Mutation, Shareability, ExtensionMerge) — impl

Siblings outside this directory: `support` (Span, Diagnostic, Type — the shared leaf, top-level)
and `midend` (Monomorphize — NOIR→NOIR, grouped with the M7 SSAIR tier).

The frontend is **kept across the C→LLVM backend transition** (`design/internals/compiler.md` §6), so
architectural gaps here are real — unlike C-backend-only limitations, which are throwaway
scaffolding. This backlog covers the frontend stages as a whole; most remaining items (modular
checking, the query engine, monomorphization) are Sema-centric.

## Architecture TODO

A living, prioritized backlog of frontend work that keeps the committed
architecture reachable — the tooling/query server (`compiler.md` §3), fine-grained
incremental compilation (§8), and debug info (§1/§4). Seeded 2026-07-30 from the
architecture evaluation. Design deferrals (features, not architecture) live in
`design/plans/deferred.md`.

### P0 — no-crash contract + parser error recovery — **done (2026-07-30)**
Was the **one live architectural blocker** for the query-server / LSP goal: the
frontend aborted the process on the first error (`exit(1)` in the lexer, parser, and
typechecker `error/fail -> Never`). Now:
- Lexer, parser, and typechecker take an injected **`DiagnosticSink`** and collect
  errors instead of exiting; all three `-> Never` reporters are gone. The driver is
  the only exit boundary — it reports the sink and `exit(1)` after the parse phase (if
  errors) and after the typecheck phase.
- **Parser error recovery**: `error(_:)` enters panic mode (one diagnostic per broken
  construct, cleared at the next member/statement boundary); `expect`/`expectIdent`
  synthesize a placeholder without consuming; unparseable expressions become an
  `Expr.error` node (`AST.swift`); type-body loops `recover(to:)` a member/decl
  boundary and statement/arg loops carry a no-progress guard, so a usable AST always
  comes out of broken input and parsing never stalls. Coverage in
  `tests/ParserRecoveryTests.swift` and the two lexer-recovery tests.
- Contract now holding: **library layers return diagnostics, never crash.** The four
  `preconditionFailure`s in `Sema.swift` were audited — all guard genuinely-unreachable
  internal invariants (interfaces filtered before `lowerDecl`, extensions merged
  pre-Sema, two exhaustive-dispatch defaults), none see user input; kept as-is.
- **Still future (LSP, not this pass):** Sema/typecheck are still run *only* when the
  parse sink is clean — the driver stops after parse errors, so `Expr.error` nodes never
  reach Sema. A query server will want to continue into Sema over a partial tree; that
  needs `Expr.error` threaded through Sema's checker (it has a compile-time case today
  that returns an `.error`-typed placeholder, but the path is untested end-to-end).

### P1 — split the frontend monolith into per-stage modules — **done (M7 §7.1, 2026-08-16)**
The single `frontend` `swift_library` (~5,900 LoC, one compile unit) is now the six
per-stage modules above, each its own `swift_library` with a shared `support` leaf.
Interface modules (`ast`, `noir`) hold each IR's types + dump; implementation modules
(`parse`, `sema`, `midend`) hold the code. This gives build parallelism, coarse
inter-module incremental (Bazel rebuilds only changed modules + dependents), and enforced
layering. Complements — does not replace — the P2 per-decl query engine (that is
intra-module fine-grained; this is inter-module coarse). Cross-module construction of AST
and NOIR values required explicit `public init`s on their structs (the synthesized
memberwise inits are `internal`). One layering wrinkle to revisit: `llvmgen` depends on
`sema` only for `Builtins` (the builtin-function table codegen shares) — a candidate to
move to a shared module later.

### P1 — structured diagnostics
Today a `Diagnostic` is `severity + message + span`. LSP quality (and stable tests)
wants more, and retrofitting messages→codes later is miserable:
- stable **error codes**, **related locations** (secondary spans), and **fix-its**
  (suggested edits). Seed the fields now even if most sites don't populate them.

### P1 — multi-file → one module
Precondition for fine-grained incremental ("20 files, edit 2, rebuild 2"). Today the
driver is single-file and the prelude is concatenated into one `Program`.
- Accept **N source files → one module**: parse each independently, build the shared
  module **signature environment** from all files, then check each file's bodies
  against it.
- Keep the **signatures-first / bodies-second** boundary clean (already latent in
  `Sema.collectGlobals` → `check()`): a body is checked only against referenced
  **signatures**, never another decl's body. This modular-checking property is what
  makes "recompile only what changed" *sound* — protect it as new checks are added.

### P2 — query / incremental engine (shared substrate)
Fine-grained incremental and the LSP are the **same engine** (Salsa / rust-analyzer
style): demand-driven, memoized queries keyed by stable per-decl identity, with
automatic invalidation on a dependency's fingerprint change.
- **Fingerprint** each decl's public signature (the invalidation trigger) and track
  **query dependencies** so editing a body invalidates only that decl's outputs.
- **Position → node index** for "what's the type here?" (spans are on every IR node;
  no lookup index yet).
- Watch item: **monomorphization** (5.4) fights incrementality — editing a generic
  re-stamps every instantiation. Witness-passing (the current baseline) does not;
  design **cached monomorphizations** (`compiler.md` §7) if 5.4 lands.

### P2 — serializable / fingerprintable boundary formats
Cache and tooling need each phase's output (tokens, AST, typed IR) to serialize
fast and version stably (`compiler.md` §8). They're plain structs/enums today — keep
them that way; add stable (de)serialization when the engine needs it.

## Notes
- **Debug info is not a frontend gap.** Spans are threaded lexer→tokens→AST→IR and
  preserved by every pass (invariant held); the only miss was the C backend not
  emitting `#line`, which is throwaway (LLVM emits DWARF from spans via `DIBuilder`,
  §6). Just keep the span invariant intact — never drop a node's span in a new pass,
  and give synthesized nodes the span of their originating construct.
