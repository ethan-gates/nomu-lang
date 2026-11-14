# Dense value layout — investigation and performance

**Avenue:** Risk · **Type/Lifecycle:** `perf · evaluate` (codegen + runtime) · **Size:** M ·
**Status:** in progress — approach and reordering decided; 196.1 next · **Source:** [176](176-shaped-gc-roots.md) 176.5.1, which found codegen's
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

## Decisions

- **How the question is answered — measure the cost per type, decide on principle.** The programs in the
  repository (benchmarks, examples, fixtures) hold almost no small fields, so a footprint survey over them
  would read near zero whatever slots cost. 196 measures what slots cost where small fields occur (arrays
  of `Bool`, `UInt8` and payload-free enums, arrays of flag-like structs, objects holding a few flags), the
  access cost, and the erased path's cost with alignment; the decision weighs those magnitudes and what
  comparable languages do (Swift, Go and Rust are all dense). A representative corpus for footprint
  distributions is left to the benchmark against Go and Swift.
- **The design evaluated — a Nomu layout function.** Size, alignment and field offsets per type, computed
  in the midend beside `ShapeEnv` (which already computes slot counts) and read by codegen, the
  descriptors, `shape(T)` and the erased path. LLVM's data layout is not an option: code outside
  `llvmgen` cannot see it, and the shape model and the collector's maps live in the midend.
- **Field reordering — decided: yes, by alignment.** Users never order fields for padding. The order is a
  pure function of the field types (alignment descending, ties in declared order), so every build and
  module agrees. Fields whose type is a type parameter keep a fixed place (after the others), so erased
  code computes an offset as a running sum and never sorts at run time; specialized and erased code agree
  because both apply the same rule. Under a build that specializes every generic, the rule could be
  lifted for full reordering, but only build-wide, since layout is shared between modules. Debug info
  records each field's offset, so debuggers show declared order. C layout for FFI types is left until FFI
  exists (it would need a way to ask for declared order, which is a syntax decision).

## Work

- **196.1** Per-type cost under slots against dense: memory and time for arrays of `Bool`, `UInt8` and
  payload-free enums, arrays of flag-like structs, and objects with a few small fields (allocation,
  collection, iteration).
- **196.2** Access cost: code size and instruction counts for small-field loads and stores, widened slots
  against byte access.
- **196.3** The erased path with alignment: the witness tables carry alignment, offsets become padded
  running sums; measured on the erased-call benchmarks, against fully reordered offsets computed at run
  time.
- **196.4** Confirm nothing maps a Nomu struct onto memory laid out elsewhere (the runtime's records,
  assembly), which reordering would break.
- **196.5** The recommendation, and if dense, the layout function's design for [260](260-enum-layout.md)
  and [181](181-array-managed-buffer.md) to build on.

## Exit

A recommendation backed by the measurements: keep the slot rule, or adopt one of the dense designs, with
its expected footprint and time effect on the benchmark corpus.

## Dependencies & triggers

- After [176](176-shaped-gc-roots.md) 176.5.2 (the slot rule restored and checked), so measurements start
  from a correct baseline.
- Before [260](260-enum-layout.md).4 (enum layout), which builds on the layout this task settles.
- Feeds the GC benchmarking ([150](150-selfhosted-gc-ladder.md) GenImmix vs MMTk) and
  [178](178-runtime-gc-performance.md) (runtime and GC throughput): footprint changes nursery pressure.

## Refs

- `src/llvmgen/LLVMGenLayout.swift` — `llvmType`, `structType`, `enumType`, `slotCount`.
- `src/llvmgen/LLVMGenGCMaps.swift` — `collectManagedOffsets`, `arrayElemStride`.
- `src/llvmgen/SSAIRToLLVM.swift` — `erasedTypeSize`, `erasedFieldOffset`, `erasedEnumPayloadOffset`.
- `tests/fixtures/shape_matrix/` — `layout_*`, `erased_layout*`.
