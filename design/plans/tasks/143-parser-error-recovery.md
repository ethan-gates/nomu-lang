# Parser / frontend error recovery

**Avenue:** Usability (compiler robustness) · **Type/Lifecycle:** `refactor · shipped` ·
**Size:** M · **Status:** shipped (continue-into-Sema tail tracked under 137) · **Source:** deferred.md
(post-M9 raw list + pipeline hardening tail)

## What

The frontend (lexer / parser / typechecker) called `exit(1)` on the first error, which contradicts the
query-server commitment (a language server must recover and report many diagnostics). Two concrete
symptoms, both now resolved:
- **Parser crashed on a missing trailing `)`** — *fixed this session.* The trap was in
  `Parser.shiftOp()`, which read `tokens[pos + 1]` unguarded while probing for `<<`/`>>`. Any
  expression that ended exactly at the EOF token (what a missing closing delimiter produces) indexed
  past the end and hit SIGTRAP. Added the same `pos + 1 < tokens.count` bound the rest of the parser
  already uses (`peek`, `advance`). Now every unclosed `(`/`[`/`<` at EOF reports a clean `expected …`
  diagnostic and returns. Regression coverage: `ParserRecoveryTests.testUnclosedDelimiterAtEOFDoesNotCrash`.
- **`exit(1)` on first error** — resolved earlier (frontend `README.md` P0, "no-crash contract"): the
  lexer, parser, and typechecker take an injected `DiagnosticSink` and collect errors; the parser
  panic-mode-recovers and reports one diagnostic per broken construct, so a whole file's parse errors
  surface in one run.

## Remaining tail (not this task)

The pipeline still stops after the parse phase when the parse sink has errors, so `Expr.error` nodes
never reach Sema. Continuing into Sema over a partial tree is LSP/query-server work — tracked under
[137 tooling / query server](137-tooling-lsp-formatter.md), not here.

## Why it matters now

The [LSP / query server](137-tooling-lsp-formatter.md) (M10) can't be built on a frontend that halts on
first error. A live actionable backlog already exists in `src/frontend/README.md`.

## Dependencies & triggers

- **Blocks:** the M10 [query server](137-tooling-lsp-formatter.md) responsiveness.
- **Actionable now:** the missing-`)` crash is a small, self-contained fix.

## Refs

deferred.md "Post-M9 backlog" (parser crash), "Pipeline boundary hardening" (frontend blocker);
`src/frontend/README.md`.
