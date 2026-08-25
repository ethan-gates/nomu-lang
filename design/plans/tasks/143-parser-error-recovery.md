# Parser / frontend error recovery

**Avenue:** Usability (compiler robustness) · **Type/Lifecycle:** `refactor · ready-to-build` ·
**Size:** M · **Status:** ready-to-build (actionable backlog exists) · **Source:** deferred.md
(post-M9 raw list + pipeline hardening tail)

## What

The frontend (lexer / parser / typechecker) calls `exit(1)` on the first error, which contradicts the
query-server commitment (a language server must recover and report many diagnostics). Two concrete
symptoms:
- **Parser crashes on a missing trailing `)`** — a source file missing a trailing close paren crashes
  the frontend instead of emitting a clean parse diagnostic. Harden the parser to report
  unexpected-EOF / unclosed-delimiter as a recoverable diagnostic (with the opening delimiter's span)
  rather than trapping.
- **`exit(1)` on first error** generally — recover and continue collecting diagnostics.

## Why it matters now

The [LSP / query server](137-tooling-lsp-formatter.md) (M10) can't be built on a frontend that halts on
first error. A live actionable backlog already exists in `src/frontend/README.md`.

## Dependencies & triggers

- **Blocks:** the M10 [query server](137-tooling-lsp-formatter.md) responsiveness.
- **Actionable now:** the missing-`)` crash is a small, self-contained fix.

## Refs

deferred.md "Post-M9 backlog" (parser crash), "Pipeline boundary hardening" (frontend blocker);
`src/frontend/README.md`.
