# Debugger (M11)

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design · **Source:** roadmap M11 (`design/internals/debugger.md`)

## What

The M11 debugger:
- DWARF variant parts (for enums / sum types),
- data formatters,
- GC-aware stepping,
- a runtime-aware plugin (DAP — Debug Adapter Protocol).

## Dependencies & triggers

- **Rests on:** DWARF via `DIBuilder` (landed with M9), the GC object model + precise scan (M6).
- **Hosts:** [memory debugging / heap introspection](139-memory-heap-introspection.md) as a feature.
- **Enables:** [concurrency hardening](105-concurrency-hardening.md) (M12) — the debugger can investigate
  races (part of why hardening is placed after it).

## Refs

roadmap M11; `design/internals/debugger.md`.
