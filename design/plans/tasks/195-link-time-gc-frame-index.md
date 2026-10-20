# Link-time GC frame index

**Avenue:** Risk · **Type/Lifecycle:** `correctness · ready-to-build` (driver link step + both stack
walkers + codegen) · **Size:** L · **Status:** 195.1–195.4 done; 195.5 (the driver writes the signature) remains · **Source:** split
from [190](190-explicit-module-builds.md) 190.6 F1 (GC stack scanning unsound across objects). 190 depends
on it.

## Deliverable

GC stack scanning that is sound for a program linked from many objects: a sorted frame index built by the
driver after the link and written into the binary, read by both stack walkers with no setup at launch or
first collection.

## The problem

Three findings in the stackmap handling of both stack walkers: the C walker (`nomu_gc_stackmap_init`,
`gc_lookup`, `nomu_gc_walk_context` in `runtime.c`, used under the default `RT_SCHED_C` plan) and the
self-hosted walker (`rtCollectRoots`, `rtWalkFrom` in `src/stdlib/runtime.nomu`, used under
`RT_SCHED_NOMU`), plus the ordinals emitted in `LLVMGenGCMaps.swift`. All hold since modules became
separate objects (100.4) and the embedded workspace did (174); 190 made them visible by changing the link
order.

- **Lost stackmaps (serious).** Every object carries its own `__llvm_stackmaps` blob, and the linker places
  the blobs back to back with no padding (each blob's length follows from its header and records; their sum
  equals the section size). Both walkers read one header and stop, so frames of every object after the
  first have no records. `gc_pressure` holds three blobs (entry 18 records, `runtime.nomu` 556, `std` 10);
  the runtime loads 18.
  - In the C walker a frame without a record is skipped: its roots are missed and left pointing at old
    locations after a moving collection.
  - In the self-hosted walker a frame without a record ends the walk (`if !found { walking = false }`),
    since the step to the caller needs the record's frame size. Every frame outward loses its roots,
    including frames of the first object.
  - Reproduced with a two-module program (a library module `hold` keeping a `Box` live across collections,
    and the entry keeping one live across a call into `hold`). The same code as one module passes. Linked
    entry-first (the driver's order) it crashes under MMTk immix stress and under the self-hosted GC. Linked
    `hold`-first, `hold` is correct and the entry's root is missed: wrong output with no crash (`6000` for
    `6042`; self-hosted, a different wrong value each run). A scratch runtime reading every blob fixes the
    C walker's case.
  - The 15 GC crashes in 190.4.2 were this: with `std` first, the entry's frames had no records. Linking
    the entry first hides it for the suite, whose GC cases hold their roots in the entry.
- **Colliding shape ordinals.** A frame value whose type holds managed pointers is recorded by a 32-bit
  ordinal (0 = `String`, then 1, 2… per compile in first-seen order), resolved through `__nomu_shape_table`
  by `nomu_shape_desc_for_ordinal`, which both walkers call. Every object emits its own table, weak-ODR,
  and the linker keeps one, so a module's ordinal resolves in another module's table. Lost stackmaps hide
  it today: the first object supplies both the only blob read and the table kept. Reproduced with every
  blob read: the entry's ordinal 1 is `Head { s: String, n: Int }`, `hold`'s is `Tail { n: Int, s: String }`;
  linked entry-first the program prints a wrong value with no crash (`19561` for `7114012`), linked
  `hold`-first it is correct. Today's cached `std` objects record only ordinal 0 and `runtime.nomu` none,
  which is why programs hold.
- **Linear record lookup.** `gc_lookup` compares the return address with every record, per frame walked,
  and the self-hosted walker re-parses the section per frame. With every blob read, ~600 records in a
  small program.
- **Duplicate copies.** A weak-ODR function emitted into several objects (a cross-module generic
  specialized in more than one consumer, 100.5.5) brings each copy's records, all bound to the one copy the
  linker keeps: `churnKeep<Cell>`, specialized in modules `a` and `b`, has entries in two blobs at one
  address. The records match when the copies' code matches; copies compiled with different options (F4 in
  190.6) or inlining contexts can differ. Dead stripping leaves no stale records (195.1). The linker applies none of its per-function transforms to the stackmap section ([194](194-gc-frame-metadata.md)).

## Options weighed

1. **Walk the blobs in place in each walker.** Smallest; keeps the self-hosted walker parsing the whole
   section per frame and two parsers in lockstep.
2. **Build one sorted index from every blob at first walk, in each runtime.** Measured below: it reads every
   record, over the 1 ms budget at the target program size, and it pages in the whole section at the first
   collection, pushing other pages out of the cache at the moment the collection needs them. Its index
   (~24 bytes per function) is process memory for the program's lifetime.
3. **Build the index after the link, in the driver.** Chosen (below).
4. **One LLVM module for the whole program.** Rejected: it serializes code generation and defeats the
   per-module object cache.

**Cost measured.** Benchmark (C, M3 Max) over synthetic sections built from real Nomu function records
(~68 bytes per record; user code measured 0.2–0.8 records per non-blank line, so a 2M-line program is
~1M records):

| Records | Section | Page faults | Step every record (warm / freshly mapped) | Per-function index (warm / mapped) | Today's copy-per-record shape |
|---|---|---|---|---|---|
| 100k | 6.8 MB | 0.2 ms | 0.69 / 0.62 ms | 0.47 / 0.59 ms | 2.7 ms |
| 1M | 68 MB | 1.8 ms | 3.5 / 5.8 ms | 3.7 / 5.8 ms | 16 ms |
| 2M | 137 MB | 3.5 ms | 7.1 / 12.1 ms | 7.4 / 12.4 ms | 32 ms |

The budget is under 1 ms of GC setup for a 2M-line program. Any runtime build reads every record once
(records are variable length with no directory), so option 2 meets it only to ~150k records.

## Design

- **Link, then index, then patch.** Before the link the driver sums the record counts from the input
  objects' stackmap headers and links in a zero-filled index section of that size. It links with
  `-Wl,-map,<file>`. After the link it reads the binary's `__llvm_stackmaps` and the map, builds the index,
  writes it into the reserved section and signs the binary.
- **Signing.** On arm64 macOS the linker ad-hoc signs every binary (page hashes) as its last step, and
  patching afterwards invalidates that signature. The driver links with `-Wl,-no_adhoc_codesign`, patches,
  then signs once with `codesign -s -` (verified in 195.1: unsigned after the link, valid after signing,
  correct under GC). Writing the ad-hoc signature in the driver itself, as Go's linker does, is 195.5.
- **Index.** One sorted entry per function, positions relative to the section start (ASLR slides the image
  as a whole): function address, record offset into `__llvm_stackmaps`, record count, stack size, and the
  source object. The records stay LLVM's; the walkers decode the records of the frames on the stack only.
- **What the step drops.** The records of folded-away duplicate copies: an entry is kept only when the live
  definition it binds to comes from the blob's own object (195.1). Dead stripping leaves no stale records.
- **Shape ordinals.** Each object's ordinal table gets a name unique to that object instead of one weak
  `__nomu_shape_table`, so every table survives the link. An index entry names its source object; a walker
  resolves an ordinal through that object's table. Kept copies' records resolve through the kept copy's
  object. `nomu_shape_desc_for_ordinal`'s single table goes.
- **Walkers.** Both binary-search the index; neither parses the section or builds anything. A binary linked
  without the step carries an empty index, which the runtime detects and aborts on.
- **Memory.** The index and records are file-backed pages: a lookup pages in the ~17 index pages of a binary
  search and its record pages, and the OS may drop them again. No process memory is spent on them.
- **Independent of 194.** The index points into LLVM's records, so it works with today's stackmaps; if 194
  replaces the record format, the step's input changes and the walkers keep reading the index.

## Phases

- **195.1 — prototype the step's assumptions.** **Done**; every assumption holds. Throwaway Python tools in
  the scratchpad (pre-link reserve, post-link index and patch) and a scratch C runtime whose `gc_lookup`
  binary-searches the index, over the reproduction programs relinked with the driver's link line plus
  `-Wl,-map`:
  - **Blob to object.** The map lists each object's blob as `__LLVM_StackMaps` with address, size and source
    object, matching the section's blobs one for one. No fallback needed.
  - **Local symbols.** The map lists non-external functions (`___nomu_selfhost_alloc`) that `-x` removes
    from the binary's symbol table; every rebase target in the stackmaps resolves through it.
  - **Folded copies.** A weak-coalesced function resolves to its kept definition and that definition's
    object; the folded-away copy is listed under "Dead Stripped Symbols" with its object. Rule: keep a
    function entry exactly when the live definition it binds to comes from the blob's own object. In the
    two-consumer generic case it drops one entry (`b.o`'s `churnKeep<Cell>`) and keeps `a.o`'s.
  - **Dead stripping.** It leaves no stale records: ld64 keeps every function the stackmap section
    references, so a function with statepoints is never stripped (an unused `package fun` with allocating
    calls survives `-dead_strip`; unused functions without statepoints are stripped). No step logic needed;
    the cost is binary size ([194](194-gc-frame-metadata.md)).
  - **Patch and re-sign.** A `__DATA_CONST,__nomu_frameidx,regular,no_dead_strip` section of `.space` bytes
    (sized from the input objects' summed function counts, so folded copies leave slack) survives the link
    zero-filled; the step writes the index into it and `codesign -f -s -` restores a valid signature
    (`codesign --verify --strict` passes). Unsigned after patching, the binary still runs locally but its
    signature is invalid, so the step signs after patching. Linking with `-Wl,-no_adhoc_codesign`, patching,
    then `codesign -s -` once also works.
  - **End to end (C walker).** With the index: the two-module program, entry linked first, is correct under
    MMTk immix stress (`2014000 6042`, 3/3; it crashes today); the two-consumer generic runs correctly; a
    binary linked without the step aborts with a message. Colliding ordinals still give the wrong value
    (`19561`), as expected until 195.3.
- **195.2 — the index step and the walkers (lost stackmaps, linear lookup).** **Done.** Suite 156/156, all 12
  unit-test targets pass. As built:
  - **Driver** (`src/driver/sources/FrameIndex.swift`, called from `linkBinary`): the link reserves the
    section with `-sectcreate` (byte-aligned, so the index starts at the section's first 8-aligned address)
    and adds `-map` and `-no_adhoc_codesign`; the step reads the binary (mapped), decodes each stackmap
    function address from its chained fixup (pointer formats 2 and 6; a bind resolves through the binary's
    symbol table, since binds name globals), scans the map as bytes for the blobs and the objects defining
    those addresses only, writes the index in place, and `codesign -s -` signs. Timings report `frame index`
    and `codesign` under the link. A stack size of `UINT64_MAX` (a frame of dynamic size, as an erased
    generic's runtime-sized buffer) is stored as `UINT32_MAX`.
  - **C walker:** `nomu_gc_stackmap_init` locates the stackmaps and the index at the first walk and aborts
    with a message when the index is missing; `gc_lookup` binary-searches the index and returns the record;
    `nomu_gc_walk_context` decodes the record's slots and shaped roots in place. The per-record copies are
    gone.
  - **Self-hosted walker:** `rtFrameLookup` (runtime.nomu) binary-searches the index through the new
    `RawPtr.gcFrameIndexBase()` builtin (the section's start symbol, as for `gcStackmapBase`); `rtWalkFrom`
    and `rtCollectRoots` use it in place of their scans. The C boot of the self-hosted scheduler checks the
    index exists. `rtStackmapEnd` reads every blob.
  - **Results:** the two-module program is correct under MMTk immix stress (C walker) and under the
    self-hosted pressure GC at 1, 2 and 4 carriers, where it crashed before; the two-consumer generic built
    with `--mono=all` keeps `a.o`'s copy, drops `b.o`'s, and is correct under GC; a binary linked without the
    step aborts at its first walk (a NoGC run never walks and runs).
  - **Costs** (small program, opt build): the index step ~5 ms, `codesign` ~65 ms per link (195.5).
  - **Found along the way, not 195's:** the same generic built erased gives a wrong value under MMTk immix
    with the C scheduler, with the old runtime too: the known gap that erased-`T` typed roots have no walk
    without `NOMU_SCHED=nomu` (100-modules.md edge (d), owned by 171 §171.3). The self-hosted pcsp walk
    cannot step past a frame of dynamic size (it steps by the recorded stack size); this predates 195 and
    is fixed in 195.3. The
    examples `stackmap_probe`, `walk_multiframe` and `walk_mark` no longer compile (they call runtime
    functions user programs no longer see), so `rtCollectRoots` has no running test; predates 195, like
    190.6 F26.
- **195.3 — shape ordinals.** **Done.** Suite 156/156, all 12 unit-test targets pass. As built:
  - **Codegen:** each object's `__nomu_shape_table` is internal to the object and kept from dead stripping
    (`llvm.used`), with its ordinal count in word 0; `__nomu_shape_table_count` and
    `__nomu_string_shape_typeid` are gone (the table's String entry keeps the String descriptor from being
    stripped).
  - **Index version 2:** after the entries, a blob directory gives each blob's object's table (found by name
    and object in the link map). The step checks every shape ordinal in every kept record against that
    table and fails the build otherwise.
  - **Walkers:** an ordinal resolves as word `1 + ordinal` of the table of the entry's blob, read directly
    (C: `gc_lookup` returns the entry; Nomu: `rtFrameShapes`). `nomu_shape_desc_for_ordinal` and the
    `RawPtr.gcShapeDescForOrdinal` builtin are gone.
  - **Results:** the colliding-ordinals program (entry linked first) is correct under MMTk immix stress
    (`7114012`, 3/3; it printed `19561`) and under the self-hosted pressure GC at 1, 2 and 4 carriers.
  - **Fixed along the way:**
    - `rtU16`/`rtU32` returned a negative value when the bytes above the field made the loaded word
      negative (the self-hosted walker crashed reading an index entry's blob next to a negative function
      offset).
    - The self-hosted walk now steps past a frame of dynamic size: its FP is the one its callee saved, in
      the callee's frame record just below the frame's SP (fixed-size frames keep SP + size − 16). Before
      195 such a frame ended the walk by accident (a stack size of −1 led to a junk return address); with the
      index's real stack size it faulted (`module-generic-producer` under `NOMU_STW_COLLECT`).
    - The driver links, indexes and signs the binary under a temporary name and renames it into place: two
      suite cases building one fixture at once (`module-generic-fold` and its `-mono` twin) raced in the
      longer link step, a case of 190.6 F3. `codesign -i` keeps the binary's name as the signature's
      identifier.
- **195.4 — tests.** **Done.** Suite 162/162 (six new cases), all 12 unit-test targets pass.
  - **Fixtures** (`tests/fixtures/`), each run twice: `-evac` (MMTk immix stress, the C walker) and `-self`
    (self-hosted pressure collection with a high trigger reserve, the self-hosted walker, 1 and 2 carriers,
    asserting at least two collections):
    - `gc_roots_across_modules` — roots in a library module's frames, and in the entry's frame across a
      collecting call into the library (the lost-stackmaps reproduction).
    - `gc_shapes_across_modules` — shape ordinal 1 meaning different struct layouts in the entry and the
      library (the colliding-ordinals reproduction).
    - `gc_generic_two_consumers` — a generic specialized in two consumers under `--mono=all` (folded copies).
  - **Build test** `testBinaryWithoutFrameIndexAborts` (`//src/driver:build_tests`): a built binary carries a
    version-2 index with entries and collects correctly; with the index erased and the binary re-signed, its
    first collection aborts with the message, and a run that never collects still runs.
  - The driver always links the entry first, so "entry linked elsewhere than first" is covered by roots held
    in library modules, which is what reading only the first blob missed.
  - **Found along the way, not 195's:** a heap `String` held in a frame, alone or inside a struct, comes out
    wrong under self-hosted minor collections with a small nursery (`NOMU_RUNTIME=selfhost` with
    `NOMU_NURSERY_RESERVE=8`), as a single module too, with a different value each run; major-only and the
    default nursery are correct. So the `-self` cases use pressure collection.
- **195.5 — the driver writes the ad-hoc signature.** Replace the `codesign` process with a code
  directory of SHA-256 page hashes written by the driver, as Go's linker does: no extra process, one hash
  of the file. Taken up once 195.2–195.4 work, with the signing cost measured.

## Dependencies & triggers

- 190 depends on it: 190 closes after it.
- See also [194](194-gc-frame-metadata.md) (whether to keep LLVM statepoints; the compact frame format).

## Refs

- `src/runtime/embedded/runtime.c` — `nomu_gc_stackmap_init`, `gc_lookup`, `nomu_gc_walk_context`,
  `nomu_shape_desc_for_ordinal`, `rt_gc_parked_anchors`.
- `src/stdlib/runtime.nomu` — `rtStackmapEnd`, `rtCollectRoots`, `rtWalkFrom`.
- `src/llvmgen/LLVMGenGCMaps.swift` — `shapeOrdinal`, `emitShapeOrdinalTable`.
- `src/driver/sources/Driver.swift` — `linkBinary`.
