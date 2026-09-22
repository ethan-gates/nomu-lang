# Interface / IR serialization format — optimization

**Avenue:** Infra · **Type/Lifecycle:** `backend · perf` · **Size:** M ·
**Status:** needs-design — v1 bespoke binary decided in the modules design (`../language/modules.md`); optimization deferred here

The module interface (`.nmi`) and body-IR (`.bir`) artifacts use a bespoke binary format. v1 is
correct-first and unoptimized (fixed-width ints, length-prefixed strings, count-prefixed
name-sorted tables, cross-refs as indices). This task optimizes it once there's real read-cost data.

## Settled (modules design)

- Bespoke binary for both `.nmi` and `.bir` (not a schema framework, not textual). Chosen because
  we need no schema evolution (no cross-version ABI stability; version-stamp + regenerate), `.bir`
  is inherently bespoke IR serialization, and self-hosting means hand-writing the Nomu reader either
  way.
- **Deterministic bytes** are a hard requirement (byte-stable under non-API edits → cache correctness):
  name-sorted tables, no timestamps, consistent int encoding.
- `.nmi` carries no generic body and no body hash (keeps it stable under body edits); the specializer
  reads `.bir` by generic id directly.
- A `nomuc dump-interface` textual view exists for inspection; no authoritative textual artifact.

## Optimization scope (this task)

- **Zero-copy / mmap layout** — read interface fields in place without a deserialize pass. Measure
  whether interface load is a real fraction of compile time first (the reason it's deferred: likely
  small next to typecheck/codegen).
- **String / symbol interning** — a deduplicated string pool; refs by index.
- **Varint integers** and other compaction.
- **Section index / lazy reads** — load only the parts of an interface a given compile needs
  (e.g., signatures without witness layouts) instead of the whole file.
- **Compression** — evaluate against mmap/zero-copy (compression fights zero-copy).
- Keep determinism through every optimization.

## Dependencies

- Modules [100](100-modules.md) — the artifacts and their contents.
- Backend serialization (`../internals/backend.md`).

## Refs

- FlatBuffers / Cap'n Proto (zero-copy reference designs, rejected as deps but useful patterns).
- Rust rlib crate-metadata; Swift `.swiftmodule` (binary) vs `.swiftinterface` (textual).
