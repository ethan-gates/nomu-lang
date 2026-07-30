# frontend/

Lexer, parser, AST, typechecker, semantic pass (typed IR), and the IR passes
(exhaustiveness, mutation, share analysis). The frontend is **kept across the
C→LLVM backend transition** (`design/compiler.md` §6), so architectural gaps here
are real — unlike C-backend-only limitations, which are throwaway scaffolding.

## Architecture TODO

A living, prioritized backlog of frontend work that keeps the committed
architecture reachable — the tooling/query server (`compiler.md` §3), fine-grained
incremental compilation (§8), and debug info (§1/§4). Seeded 2026-07-30 from the
architecture evaluation. Design deferrals (features, not architecture) live in
`design/deferred.md`.

### P0 — no-crash contract + parser error recovery
The **one live architectural blocker** for the query-server / LSP goal. The
frontend currently **aborts the process on the first error** — `exit(1)` in
`Lexer.swift:227`, `Parser.swift:776` (`error(_:) -> Never`), and
`Typechecker.swift:179`. A server can't `exit` on a keystroke, and there is no
resilient tree from broken input (the parser bails; only Sema collect-and-continues).
- Route lexer/parser/typechecker errors into the **`DiagnosticSink`** (already the
  Sema model), never `exit` / `-> Never`.
- Add **parser error recovery** (resilient parsing): on an unexpected token,
  synthesize an error node and resynchronize (e.g. to the next statement/decl
  boundary or a closing brace) so a usable AST comes out of broken input.
- Contract to hold going forward: **library layers return diagnostics, never crash.**
  Exit codes belong to the CLI/driver only. Audit `preconditionFailure` in
  `Sema.swift` (362/364/434/455) — keep only for genuinely-unreachable invariants.

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
- Keep the **signatures-first / bodies-second** seam clean (already latent in
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
