# GC frame metadata — LLVM statepoints or our own

**Avenue:** Risk · **Type/Lifecycle:** `perf · evaluate` (codegen + runtime) · **Size:** L ·
**Status:** evaluate — not opened; to be opened once there is more concrete evidence · **Source:** raised
by [190](190-explicit-module-builds.md) 190.6 F1 (stack scanning across objects), now [195](195-link-time-gc-frame-index.md).

## Deliverable

A decision on how Nomu describes GC roots in frames: keep LLVM's statepoint and stackmap machinery, or
replace it with our own. Either way the runtime reads a compact frame table built at link time, sorted, with
no setup at launch or first collection; this task designs that table too, since its producer depends on the
decision.

- **Keep statepoints:** a link-time step converts the linked binary's `__llvm_stackmaps` into the table
  (as [195](195-link-time-gc-frame-index.md) does over today's stackmaps).
- **Replace them:** our code generation emits the table's per-object input directly.

## Evidence so far

- **Size.** LLVM's format spends 12 bytes per location and three meta constants per record: ~68 bytes per
  record, ~68 MB of section for a 2M-line program. A runtime-built index pages all of it in.
- **No directory.** Records are variable length and per-object blobs are concatenated with no index, so any
  reader must step every record; at ~1M records that is 3.5–6 ms ([195](195-link-time-gc-frame-index.md) benchmark), over the 1 ms setup
  budget.
- **Shaped roots ride the deopt bundle.** A stackmap Constant cannot hold a link-time value, so shaped roots
  ([176](176-shaped-gc-roots.md)) carry a per-compile ordinal resolved through a side table, which collides
  across objects ([195](195-link-time-gc-frame-index.md)).
- **Optimizer coupling.** `rtCollectRoots` must keep its frame-reading loop inline so the
  `llvm.frameaddress` memory effect makes its caller spill roots at the statepoint (selfhosted-gc.md §9).
- **The linker cannot see inside it.** Each object's stackmaps are one blob in one section, so the linker
  relocates the addresses but applies none of its per-function transforms to the records: dead stripping
  never removes a function the section references, so every function with statepoints ships even when
  unused (195.1), weak/COMDAT folding keeps every copy's records pointing at the kept
  copy (seen in [195](195-link-time-gc-frame-index.md): a generic specialized in two consumers, `churnKeep<Cell>`, has entries in two
  blobs bound to one address), identical-code folding leaves the folded body's records, and no sorted lookup
  table is built. Other per-function metadata gets this from the linker: `eh_frame` is split per function,
  Apple's `__LD,__compact_unwind` is dropped with dead or folded functions and merged into a sorted
  `__unwind_info` at link time, and Go's linker owns its frame tables.
- **Designed for JITs.** Stackmaps and patchpoints came from WebKit's FTL JIT and statepoints from Azul's
  Falcon JIT: one in-memory module, no link. Separately compiled native binaries were never the target
  (from memory; to confirm).
- **Known friction elsewhere:** `musttail` with statepoints ([129](129-tail-call-optimization.md)), the
  `addrspace(1)` coupling 176 works to loosen, and moving fiber stacks
  ([104](104-fiber-stack-strategy.md)).

## Work

- What statepoints give us today (relocation, derived pointers, register roots, the optimizer's view of GC
  pointers) and what each would cost to build ourselves.
- The frame-table format: entry layout, how shaped roots and frame sizes are stored, lookup, size per
  record; one format both walkers read.
- The link-time step that builds it, and how it handles dead-stripped functions, folded duplicate copies
  and multiple images. One avenue: a per-function frame-table section with `S_ATTR_LIVE_SUPPORT`, one atom
  per function, so ld64 drops an entry with its function, as for `eh_frame`; whether ld64 also drops the
  atom of a folded-away copy is untested.

## Dependencies & triggers

- See also [195](195-link-time-gc-frame-index.md): the link-time frame index over today's LLVM stackmaps,
  which a new frame format would feed.
- Interacts with [176](176-shaped-gc-roots.md), [129](129-tail-call-optimization.md),
  [104](104-fiber-stack-strategy.md), [150](150-selfhosted-gc-ladder.md).
