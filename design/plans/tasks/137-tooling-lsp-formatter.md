# Tooling — query server / LSP / formatter

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design · **Source:** `tooling.md` (query architecture)

## What

The tooling milestone:
- a **query-based compiler server** (the incremental, demand-driven compiler architecture),
- an **LSP** (editor language server),
- a **formatter**.

## Dependencies & triggers

- **Depends on:** [modules](100-modules.md) + [incremental compilation](136-incremental-compilation.md) — the
  query server reasons in module units; modules + incremental are what make the LSP responsive (the
  reason the compilation-model fork is ► decide-early before this).
- **Rests on:** the query architecture direction already committed in `tooling.md`; the live frontend
  blocker (lexer/parser/typechecker `exit(1)` on first error, contra the query-server commitment) has
  a backlog in [parser/frontend error recovery](143-parser-error-recovery.md).

## Refs

`tooling.md` (query architecture); [modules](100-modules.md),
[incremental compilation](136-incremental-compilation.md), [parser error recovery](143-parser-error-recovery.md).
