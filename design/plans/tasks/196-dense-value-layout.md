# Dense value layout — investigation and performance

**Avenue:** Risk · **Type/Lifecycle:** `perf · evaluate` (codegen + runtime) · **Size:** M ·
**Status:** evaluate — not opened · **Source:** [176](176-shaped-gc-roots.md) 176.5.1, which found codegen's
field layout disagreeing with the GC descriptors and the erased path.

## Deliverable

A measured decision on whether Nomu leaves the uniform 8-byte-slot layout for a denser one, and if so, which
design. The slot rule stays in force until this task decides otherwise.

## Background

Every Nomu value layout assumes each field fills a whole number of 8-byte slots: `slotCount`, the GC
descriptors (`collectManagedOffsets`), enum payloads (`{ i64 tag, [P x i64] payload }`), array strides
(`arrayElemStride`), VWT sizes and the erased path's field offsets (`erasedTypeSize`/`erasedFieldOffset`).
The rule held by construction while every leaf lowered to an 8-byte LLVM type. 8.5.2 made `Bool` `i1` in
registers, which also made it 1 byte in memory, since `llvmType` gives both the register and the storage
type; `UInt8` arrived later as `i8`. Codegen's LLVM struct layout then disagreed with every other component:
the collector missed managed fields and the erased path read wrong values. 176.5.2 restores the rule
(small fields stored in full slots, with a check that LLVM's layout matches `slotCount`); this task asks
what a dense layout would buy.

## Questions

- **Footprint.** How much of a real program's heap and stack is small-field padding under the slot rule?
  Measure object-size distributions on the benchmark corpus and the larger module fixtures: types with
  `Bool`/`UInt8` fields, their share of allocated bytes, and arrays of such structs.
- **GC cost.** Allocation rate, nursery collection frequency, and bytes evacuated under the slot rule
  against a dense layout of the same programs.
- **Cache behavior.** Objects per cache line and per Immix line (256 bytes) for the common types; whether
  the difference shows in mutator time.
- **Access cost.** Code size and instruction counts for small-field loads and stores (widen/narrow at the
  boundary against byte loads), on arm64 and x86-64.
- **Designs.** Each with its effect on descriptors, `shape(T)`, the erased path, enum payloads and arrays:
  - LLVM's data layout as the source of offsets (`LLVMOffsetOfElement`), which code outside `llvmgen`
    cannot see.
  - A Nomu layout function (offsets, size, alignment per type) that codegen, descriptors, `shape(T)` and the
    erased path all read, with LLVM types built from it.
  - Field reordering by size inside that function (Rust-style), and its interaction with declared field
    order in debug info and any future C interop.
- **Erased generics.** A dense layout makes a `T` field's offset depend on alignment as well as size, so
  the VWT must carry alignment and the erased path must compute padded offsets at run time; measure that
  cost on the erased-call benchmarks.

## Exit

A recommendation backed by the measurements: keep the slot rule, or adopt one of the dense designs, with
its expected footprint and time effect on the benchmark corpus.

## Dependencies & triggers

- After [176](176-shaped-gc-roots.md) 176.5.2 (the slot rule restored and checked), so measurements start
  from a correct baseline.
- Feeds the GC benchmarking ([150](150-selfhosted-gc-ladder.md) GenImmix vs MMTk) and
  [178](178-runtime-gc-performance.md) (runtime and GC throughput): footprint changes nursery pressure.

## Refs

- `src/llvmgen/LLVMGenLayout.swift` — `llvmType`, `structType`, `enumType`, `slotCount`.
- `src/llvmgen/LLVMGenGCMaps.swift` — `collectManagedOffsets`, `arrayElemStride`.
- `src/llvmgen/SSAIRToLLVM.swift` — `erasedTypeSize`, `erasedFieldOffset`, `erasedEnumPayloadOffset`.
- `tests/fixtures/shape_matrix/` — `layout_*`, `erased_layout*`.
