# Dense value layout — investigation and performance

**Avenue:** Risk · **Type/Lifecycle:** `perf · evaluate` (codegen + runtime) · **Size:** M ·
**Status:** done — every value is laid out dense: fields, buffers and the erased path (196.1–196.8), array elements through [181](181-array-managed-buffer.md), enums through [260](260-enum-layout.md); the 196.1 pairs match their hand-packed twins (196.9) · **Source:** [176](176-shaped-gc-roots.md) 176.5.1, which found codegen's
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

- **Scope — every type.** 196 owns dense layout for every value: the layout function, struct, class and
  actor fields, messages, buffers and the erased path are built here; array elements arrive with
  [181](181-array-managed-buffer.md) (`Array` onto `ManagedBuffer`, whose stride is the element's size)
  and enums with [260](260-enum-layout.md)'s layout phases (260.4, 260.5, 260.7). Both are dependencies
  of 196.
- **Layout — decided: dense.** Nomu leaves the 8-byte-slot rule for a dense layout from the layout
  function, as 196.5 lays out: the slot rule's costs fall on ordinary types and cannot be avoided in
  source, while the dense layout costs nothing per access and only debug builds pay in erased
  construction. With it: size equals stride; an actor's mailbox pointer at offset 8; LLVM types built as
  packed structs from the layout and checked against it; enums keep their tag word until 260.4; padding
  bytes unspecified, so nothing compares or hashes a value's bytes whole.

## Results

### 196.1 — per-type cost

Five program pairs, each a slots program and a dense twin computing the same checksum, plus the same five
in Go. Arrays: build 5 arrays of N by `append`, then scan the last. Objects: a ring of 1M live objects,
20M allocations each replacing one entry, then 20 scans. The dense twin of a byte array is a
`ManagedBuffer<Int, UInt8>` grown by doubling like `Array` (it needs `--allow-core-import`); the dense
twin of a struct or class packs the three small fields into one `Int`, the size a dense layout gives it
(16 bytes for the struct, two field words for the class). Apple M3 Max, release config, best of 3–5. The
programs are in the gitignored `practice/gen/dense/` (`run.py`, `sweep.py`) and `practice/go/dense/`.

At N = 4M:

| program | build ms (slots / dense / Go) | scan ms (slots / dense / Go) | max RSS MB (slots / dense / Go) |
| --- | --- | --- | --- |
| `Array<Bool>` | 64 / 42 / 18 | 34 / 26 / 40 | 66 / 10 / 20 |
| `Array<UInt8>` | 64 / 44 / 18 | 40 / 39 / 21 | 66 / 10 / 21 |
| `Array<Color>` (4 cases) | 70 / 41 / 18 | 87 / 84 / 71 | 67 / 10 / 19 |
| `Array<Cell>` (3 flags + `Int`) | 100 / 82 / 77 | 67 / 68 / 100 | 259 / 130 / 175 |
| class (3 flags + `Int`), ring | 555 / 456 / 228 | 39 / 21 / 28 | 237 / 159 / 69 |

The object pair, from the collector's report: collection 488 / 401 ms of the run, peak heap 110 / 69 MB,
promoted 597 / 342 MB (40 against 24 bytes per object).

Scan cost in ns per element over a size sweep (320M elements scanned in all), sequential and in a
scattered order (`(i * 7919) & (n - 1)`, the access pattern of a visited set):

| array | N | sequential (slots / dense / Go) | scattered (slots / dense / Go) |
| --- | --- | --- | --- |
| `Bool` | 1M | 0.44 / 0.35 / 0.50 | 0.73 / 0.57 / 0.57 |
| `Bool` | 16M | 0.44 / 0.35 / 0.51 | 4.55 / 0.71 / 0.86 |
| `Bool` | 64M | 0.48 / 0.53 / 0.51 | 4.15 / 3.02 / 4.13 |
| `UInt8` | 16M | 0.41 / 0.50 / 0.27 | 4.55 / 0.71 / 0.94 |
| `UInt8` | 64M | 0.54 / 0.50 / 0.27 | 5.05 / 3.59 / 4.08 |
| `Cell` | 1M | 0.83 / 0.84 / 1.26 | 4.22 / 1.73 / 1.76 |
| `Cell` | 16M | 0.85 / 0.86 / 1.26 | 12.7 / 9.27 / 11.9 |

Building costs 2.9 ns per element under slots against 0.8–0.95 dense at 1M elements, and 3.1 against 2.6
at 64M.

Findings:

- **Memory.** Slots cost 6–7× the footprint of a byte array and 2× a flag struct array, which matches
  the layout arithmetic. For small objects they cost 1.5× RSS and 1.75× promoted bytes.
- **Sequential scans.** No difference at any size: the loop body sets the speed and the prefetcher hides
  the larger footprint, in Go as well.
- **Scattered access.** Slots cost up to 6.4× when the dense data fits in cache and the slot data does
  not (`Bool` and `UInt8` at 16M: 128 MB against 16 MB), 2.4× for `Cell` at 1M, and 1.3–1.4× once both
  miss.
- **Collection.** For small objects, dense saves 18% of the run, most of it in collection, and halves the
  object scan.
- **The dense twins match Go** in scattered access, so the slot rule accounts for the whole gap there.
  Go's array builds are 2–4× faster than either Nomu version and its object run 2× faster than the dense
  twin. Those gaps come from the append path and the collector, which layout does not change.
- **The raw access path.** The dense `UInt8` sequential scan (0.50) is slower than slots (0.41) and Go
  (0.27). The twin reads through `elementPtr(at:)` and a raw load, so this is the cost of that path and
  belongs to 196.2.

### 196.2 — access cost

Two parts. C kernels compiled by clang `-O2` for arm64 and x86-64, each in a slot layout (every small
field a `uint64_t`, as Nomu stores it) and a dense one (natural C layout), give the instruction-set cost
on both targets. The arm64 disassembly of the 196.1 binaries shows what Nomu emits today (Nomu builds for
the host only, and its LLVM is initialized for the native target alone).

Instructions per kernel, slots / dense (x86-64 without the frame-pointer prologue):

| kernel | arm64 | x86-64 |
| --- | --- | --- |
| load a `Bool` field, branch on it | 6 / 7 | 6 / 6 |
| store a `Bool` field | 2 / 2 | 2 / 2 |
| copy a 3-flags-plus-`Int` struct | 3 / 3 (two 16-byte moves / one) | 5 / 3 |
| build that struct and store it | 6 / 7 | 8 / 7 |
| read array element `i` (`Bool`) | 5 / 2 | 3 / 2 |
| write array element `i` (`Bool`) | 3 / 2 | 3 / 2 |
| read flags and weight of struct element `i` | 8 / 10 | 9 / 9 |
| field-wise equality of two structs | 19 / 19 | 15 / 15 |
| sum a byte array (vectorized) | 45 / 129 | 35 / 83 |

The differences are a zero-extension or a compare on one side or the other, all within one or two
instructions. Indexed byte access (`ldrb [x, i]`, `movzbl (%rdi,%rsi)`) costs the same as indexed 8-byte
access (`ldr [x, i, lsl #3]`, `(%rdi,%rsi,8)`), and byte loads zero-extend for free on both targets. The
dense sum is larger because each vector holds 8× the elements.

What Nomu emits today:

- **Small fields already use byte access.** A field load or store through an address keeps the narrow
  type, so a slot's low byte is read or written with `ldrb`/`strb`. `obj_slots`'s constructor stores its
  three flags with `strb` and its `Int` with `str`, the same four stores a dense layout needs. The slot
  rule costs bytes, and the instruction count is the same.
- **Struct elements are read field by field.** The `cell_slots` scan loads four fields of element `i`
  (two `ldr w`, one `ldrb`, one `ldr x`) with no whole-element copy; a dense layout issues the same
  four loads.
- **No scan loop is vectorized.** Each iteration polls for a safepoint (`ldr x9, [x24]; cbz`), which keeps
  the loop scalar in both layouts. The slots loop also checks bounds and reloads the buffer pointer every
  iteration. The 196.1 sequential scans therefore measure the loop, which hides layout. Once a counted
  loop runs without the poll ([245](245-loop-strip-mining.md), loop strip mining), a dense array fits 8×
  the lanes per vector; this is where dense layout would show in sequential code.

Findings:

- Per access, the two layouts cost the same on arm64 and x86-64, and Nomu's slot codegen already
  emits byte access. Choosing dense layout adds no per-access cost.
- Whole-value copies scale with size: a 32-byte struct is two 16-byte moves, the 16-byte dense one is
  one. This adds to the footprint cost measured in 196.1.
- Vector width is the one place where dense layout changes instruction counts, and it waits on poll-free
  inner loops (245).
- For 196.5: when an aggregate is passed by value, LLVM flattens it by element, so `{i8, i8, i8, i64}`
  takes as many registers as `{i64, i64, i64, i64}`. The register saving needs the small fields
  coerced into words at calls. The layout function's design has to decide that.

### 196.3 — the erased path with alignment

Erased code runs when a generic compiled in one module is called from another without specialization:
`opt.mono: none`, the debug default (release specializes everything). It computes a composed type's size
and field offsets at run time from each type parameter's size in its dictionary.

The measurement setting `measure.erased_layout` (configs `measure_erased_aligned`,
`measure_erased_reordered`) makes erased code do a dense layout's run-time work over the slot layout:

- `aligned` reads each type parameter's alignment from its VWT at entry and rounds every field offset and
  size up to its alignment, in declared order. This is the decided rule's cost when the type-parameter
  fields are declared last.
- `reordered` places each field after every field of larger alignment and every earlier field of equal
  alignment, all at run time: full reordering.

Every alignment is 8 today, so all three modes give the slot layout's offsets. Programs stay correct, and
the modes differ only in the work done. The full tier passes under each mode (1921 cases). The
config `mono_none` builds optimized code that keeps imported generics erased.

The benchmark (`practice/gen/erased196`, gitignored) is a two-module package: `lib` holds generic
readers and builders, and `main` makes 20M calls to each with `T = Pair` (two `Int`s, 16 bytes). `Last<T>`
declares `T` after a `Bool` and an `Int`, `First<T>` declares it before them, and `Two<A, B>`
interleaves two type parameters with concrete fields. Release with `mono_none`, best of 7, M3 Max:

| erased function | ms per 20M calls: specialized / slots / aligned / reordered | instructions: slots / aligned / reordered |
| --- | --- | --- |
| read `Last<T>` (`T` last) | 9 / 24 / 24 / 24 | 6 / 6 / 11 |
| read `First<T>` (`T` first) | 9 / 24 / 24 / 24 | 8 / 10 / 11 |
| read `Two<A, B>` | 10 / 24 / 24 / 25 | 10 / 18 / 26 |
| build `Last<T>` | 5 / 124 / 135 / 132 | 68 / 94 / 96 |
| build `Two<A, B>` | 5 / 167 / 173 / 179 | 112 / 126 / 141 |

Findings:

- **Reads cost nothing measurable.** The added work is a few integer operations on values loaded at entry,
  hidden behind the call itself (1.2 ns per call against 0.45 specialized).
- **Builds cost 4–9% more.** A build computes the whole layout (every field's offset and the size).
  Building in erased code is already 25–35× slower than specialized for other reasons (the typed-root
  registration and copies of an erased body that constructs a `T`-carrying value), so alignment is a small
  addition to an expensive path.
- **The decided rule keeps concrete offsets constant.** With `T` declared last, `aligned` emits exactly
  the slot code for `Last<T>` (6 instructions): the concrete fields' offsets fold to constants, and only
  `T`'s offset needs the alignment. Full reordering makes every offset depend on `T`'s alignment
  (11 instructions) and gains nothing in time. This supports placing type-parameter fields last and
  rejects run-time reordering.
- **For a dense build:** the VWT's `align` must hold the real alignment (it is a constant 8 today,
  `LLVMGenValueWitness.swift`). Concrete leaves in this measurement are given alignment 8. Their real
  alignments are compile-time constants too, so they fold the same way.

### 196.4 — memory laid out outside the compiler

No Nomu struct, class or enum is mapped onto memory laid out elsewhere. A dense layout and alignment
reordering break nothing outside the compiler. What was checked:

- **The runtime declares no Nomu types.** Its records are raw memory read and written at documented byte
  offsets through `RawPtr`: fibers, the scheduler, carriers, mailboxes, a message's prefix, channel
  waiters, `select` areas, kqueue events. The assembly (`rtasm_arm64.s`) reads only these records (the
  fiber at +48, +64 and +72) and its own saved-register area. A layout function for Nomu types does not
  touch them.
- **Two Nomu types are read by offset:** `ChannelState` and `ChannelSlot<T>` (`core.nomu`), by
  `runtime/channel.nomu`.
  - `ChannelState` is eight `Int`s, read at 0–56 from the buffer's +16, with elements at +80. Reordering
    by alignment keeps declared order among equal alignments, so its layout is unchanged. It has to stay
    all words, which its comment already says.
  - `ChannelSlot<T>`: the runtime steps elements by the value witness's size. That stays correct if the
    layout function makes every size a multiple of the type's alignment (size equals stride), which 196.5
    must require. Today the wrapper exists to round `T` up to whole slots; under a dense layout it has no
    purpose.
- **Values the compiler builds for the runtime follow the layout.** A channel receive builds its
  `Option<T>` with the enum layout functions (`enumType`, `caseStructType`, `erasedEnumPayloadOffset`).
  An actor's mailbox pointer and a message's arguments sit after fields the compiler lays out, and only
  compiler-emitted code reads them past the fixed prefix.
- **No FFI.** libc calls take scalars or raw records; none is passed a Nomu struct.

Compiler code that computes offsets from slot counts on its own, which 196.5's layout function must
feed: the GC descriptors (`typeId(forHeapType:)`, `fieldsShape`), the actor mailbox slot
(`actorMailboxIndex` and its descriptor entry), debug info's member offsets and sizes
(`LLVMGenDebug.swift`), `rawStride` (arrays, `ManagedBuffer`, `Ptr<T>`), enum payloads, and the erased
path's sizes and offsets.

One latent constraint: `Ptr<T>.alloc` passes the element stride to `posix_memalign` as the alignment.
That is valid while `Ptr<T>` takes only scalars (strides 1 and 8). If `Ptr<T>` ever takes a struct, it
must pass the type's alignment instead, since a stride such as 24 is rejected and reported as out of
memory.

### 196.5 — recommendation

The options:

- **Keep the slot rule.** Every field fills whole 8-byte slots. Every layout consumer agrees by
  construction, the erased path needs no alignment, and nothing in the compiler changes. It costs 6–7×
  the memory for byte-sized arrays (`Bool`, `UInt8`, payload-free enums), 2× for flag-like struct arrays
  and 1.67× the bytes for small objects; up to 6.4× in scattered access when dense data fits in cache and
  slot data does not; 18% of a small-object churn run, mostly collection; and the 8× vector width once
  inner loops run without polls (245). Swift, Go and Rust are all dense, so these costs show in any
  comparison with them.
- **A dense layout from a Nomu layout function, fields reordered by alignment** (the design the
  Decisions section chose). It recovers the costs above: the dense twins matched Go in 196.1. Per access
  it costs nothing on arm64 or x86-64, and Nomu's code already uses byte access (196.2). Erased code
  computes padded offsets, which leaves reads unchanged and makes erased builds 4–9% slower, in debug
  builds only (196.3). Nothing outside the compiler depends on Nomu layouts (196.4). The work is one
  function in the midend and moving every consumer of slot counts onto it.

On the repository's own programs, the effect of either is near zero, since they hold almost no small
fields.

**Recommendation: adopt the dense layout** (adopted; see Decisions). Every measured cost of slots is one a programmer would hit
through ordinary types (a `[Bool]`, a struct of flags, a small class), with no way to avoid it in
source. The dense layout's costs are either absent (access) or confined to debug builds (erased
construction).

### 196.5 — the layout function

What 260.4 (enum layout) and 181 (`Array` onto `ManagedBuffer`) build on.

- **Home and shape.** A layout function in the midend beside `ShapeEnv` (`midend/ssair`), with a
  per-type cache like the shapes'. For each type it gives size, alignment and field offsets in bytes.
  `ShapeEnv.slots` and every `slotCount` caller move onto it. Shapes keep word offsets: every managed
  word is 8-aligned, so a managed field's byte offset is always a whole number of words.
- **Leaves.** `Bool` and `UInt8`: size 1, alignment 1. `Int`, `UInt64`, `Double`, `RawPtr`, `Ptr<T>` and
  references: 8 and 8. A shaped leaf keeps its own size, alignment 8 (`String`: 16). Zero-field types
  stay size 0, as today.
- **Size equals stride.** A type's size is rounded up to its alignment, so arrays, `ManagedBuffer`
  elements, `Ptr<T>` and the channel runtime all step by the size (196.4). No tail padding is reused.
- **Field order.** Alignment descending, ties in declared order. Fields whose type is a type parameter, or
  contains one, come last in declared order, so concrete offsets are compile-time constants in erased
  code (196.3). A build-wide "specialize everything" setting may lift that rule; it is left until such a
  setting exists.
- **Classes and actors.** The header word stays at 0. An actor's mailbox pointer moves from after the
  fields to offset 8, a constant for the runtime-facing code. The fields follow under the same order,
  and the object size rounds up to 8.
- **Enums.** Until 260.4, an enum keeps its tag word with the payload starting at 8; each case's
  fields are laid out by the same function, and the payload region is the largest case's size rounded up
  to 8. 260.4 replaces this with extra inhabitants, reading size and alignment from this function.
- **LLVM types.** Built from the layout as packed structs with explicit byte-array padding, so LLVM
  places every element where the layout says on any target. `fieldStorageType` stores `Bool` and
  `UInt8` as `i8`, keeping the narrow register types. `checkSlotLayout` becomes a check of every
  aggregate against the layout function.
- **Consumers to move** (196.4's list): the GC descriptors (`typeId(forHeapType:)`, `fieldsShape`), the
  actor mailbox slot, debug info's member offsets and sizes, `rawStride` and `arrayElemStride`, the
  `ManagedBuffer` header size (elements start at the header's end rounded up to a word, every element's
  alignment or more, so erased code that knows only the header agrees), enum payloads, and the erased
  path. `Ptr<T>.alloc` passes the type's alignment, not its
  stride.
- **The erased path.** The VWT carries the real size and alignment. Offsets and sizes are computed as
  196.3's `aligned` mode does, which becomes the only mode; `measure.erased_layout` and its two configs
  are removed.
- **Padding bytes are unspecified.** Copies may carry them; nothing may compare or hash a value's bytes
  as a whole. No consumer does so today.
- **Calls.** An aggregate passed by value is flattened per element by LLVM, so a dense struct takes as
  many registers as before. Packing small fields into words at calls is a possible follow-up, left
  until a measurement asks for it.
- **`ChannelSlot<T>`** loses its purpose (rounding `T` to whole slots) and can be removed, with the
  channel runtime reading the element's size from its witness as now.

### 196.6 — the layout function, producing the slot layout

`midend/ssair/sources/Layout.swift` gives each type's size and alignment in bytes and the offsets of a
run of fields (`fieldsLayout`, by declared position), with enum case payloads and the payload size. Leaves
are 8 bytes at alignment 8 (`String` 16), fields in declared order, which reproduces the slot layout.
`ShapeEnv.slots` and the egress's `slotCount` are gone. Every consumer reads the layout function: shapes
(`fieldsShape`), GC descriptors, heap object, value box and message sizes, the actor mailbox offset,
`rawStride` and `arrayElemStride`, `ManagedBuffer` element starts, VWT size and alignment, dictionary
sizes, enum payload words, debug info, and the erased path's concrete sizes. `checkLayout` compares every
struct, class, actor, enum case and actor message LLVM type against it on each compile. The full tier
passes (1921), and the unit tests pass apart from the known `planner_tests` goldens.

Found and fixed on the way: an actor message held each argument at its register type, so two `Bool`
arguments packed into adjacent bytes while the message's descriptor read whole slots, and a reference after
them was scanned at the wrong word (the collector crashed). Message arguments now take their field storage
types and their offsets from the layout function, and `checkLayout` covers messages. Suite case
`gc-actor-small-args` (fixture `gc_actor_small_args`) holds it.

For 196.7: `SSAIRToLLVM.wordPath` walks an aggregate's LLVM type in 8-byte words to find a managed word at
a byte offset; with packed types holding padding arrays it has to step by real element offsets.

### 196.7.1 — one-byte leaves, declared order

`Bool` and `UInt8` are one byte at alignment 1. Fields stay in declared order, each at the next multiple of
its alignment, so LLVM's natural struct layout matches the layout function and no element index changes.
`fieldStorageType` stores a `Bool` as `i8` (an `i1` in registers) and a `UInt8` as itself. The erased path
computes the same layout at run time from each type parameter's VWT size and alignment (196.3's `aligned`
work, now the only mode; `measure.erased_layout` and its configs are removed), and the VWT carries the real
alignment. `wordPath` walks LLVM types under their natural layout. Array elements keep their 8-byte minimum
stride until [181](181-array-managed-buffer.md); a `ManagedBuffer` of `UInt8` and a channel of `Bool` step
by one byte.

One regression found and fixed on the way: erased code sizes a generic class object as the offset past its
last field, which the rewritten offset function first returned as the header offset.

New coverage: `layout_matrix/erased_layout_small` (type parameters of one byte, a `String` and a nested
composed value, across pipelines, so erased and specialized code agree) and `gc_dense_fields` (one-byte
fields beside references and `String`s in a struct, class, enum payload, array, actor message and a
`Channel<Bool>`, under GC stress; suite cases `gc-dense-fields`, `gc-dense-fields-release`). The full tier
passes (1927).

### 196.7.2 — field order

A struct's, class's and actor's fields are placed by alignment, largest first, ties in declared order, with
fields from a type parameter last in declared order (`ShapeEnv.memoryOrder`, `structLayout`,
`objectLayout`). An enum case's payload and an actor message's arguments keep declared order: enum layout is
260.4's, and messages are compiler records with no user-visible order.

- **Which fields came from a type parameter.** Monomorphization marks a specialized field whose template type
  mentions a type parameter (`NOIRField.fromTypeParameter`, carried into `SSAField` and into the interface's
  `DictionaryLayout`, so a specialized type imported by name keeps its producer's order). Erased code reads
  the template directly, and sorts the other fields by alignments it knows statically (`staticAlign`, which
  looks through a generic struct application such as `Trio<Bool>` to its fields).
- **LLVM types** are built in memory order; `llvmFieldIndex(type, position)` maps a declared position to its
  element at every field access (construction, extraction, field addresses, stored-property accessors and
  witness thunks). The layout check compares each field through the map.
- **Actors** hold their mailbox pointer at byte 8 and their fields from byte 16.
- **Example** (`gc_dense_fields`): `struct Cell { lit: Bool, s: String, tag: UInt8, box: Box, seen: Bool }` is
  `{ String, Box, i8, i8, i8 }`, 32 bytes, where declared order would take 40.

`layout_matrix/erased_layout_small` gained `Wrap<T>`, with a word field after a one-byte field and a
`Trio<Bool>` field, across pipelines; with `staticAlign` giving every generic application word alignment,
its debug and no-inline legs fail, so it guards the order erased code computes. The full tier passes (1927).

### 196.7.3 — `Ptr<T>.alloc`

Passes the element type's alignment to the allocator, where it passed the stride.

### 196.8 — the 196.1 pairs under the dense layout

The same programs and runner (`practice/gen/dense/run.py`), best of 5. The slots programs now compile
dense:

| program | build ms | scan ms | max RSS MB | collector |
| --- | --- | --- | --- | --- |
| `Array<Cell>`: slot layout (196.1) | 100 | 67 | 259 | |
| `Array<Cell>`: dense layout | 74 | 67 | 131 | |
| `Array<Cell>`: hand-packed twin | 82 | 68 | 131 | |
| objects: slot layout (196.1) | 555 | 39 | 237 | 488 ms, 597 MB promoted |
| objects: dense layout | 465 | 24 | 159 | 408 ms, 342 MB promoted |
| objects: hand-packed twin | 466 | 22 | 159 | 409 ms, 342 MB promoted |

The struct array and the small objects now match their hand-packed twins, the struct array building faster
than its twin (no packing arithmetic). The byte arrays (`Bool`, `UInt8`, payload-free enums) are unchanged:
`Array`'s element stride keeps its 8-byte minimum until [181](181-array-managed-buffer.md) moves `Array` onto
`ManagedBuffer`, whose stride is the element's size.

### 196.9 — the 196.1 pairs with 181 and 260 in

The same runner, best of 5, with the Go programs (`practice/go/dense`) best of 5 beside them. Each "slots"
program is now the dense layout; its twin is hand-packed.

| program | build ms (Nomu / twin / Go) | scan ms (Nomu / twin / Go) | max RSS MB (Nomu / twin / Go) |
| --- | --- | --- | --- |
| `Array<Bool>` | 35 / 31 / 18 | 35 / 28 / 40 | 10 / 10 / 16 |
| `Array<UInt8>` | 38 / 34 / 18 | 32 / 39 / 39 | 10 / 10 / 19 |
| `Array<Color>` (4 cases) | 43 / 32 / 17 | 94 / 88 / 91 | 10 / 10 / 17 |
| `Array<Cell>` (3 flags + `Int`) | 63 / 69 / 79 | 69 / 69 / 103 | 131 / 131 / 136 |
| class (3 flags + `Int`), ring | 520 / 539 / 226 | 26 / 23 / 29 | 159 / 161 / 64 |

The object pair, from the collector's report: 28 cycles each, peak heap 69 MB, promoted 342 MB for both.

Findings:

- **Every pair matches its twin in memory**, byte arrays included (66–67 MB under slots in 196.1, 10 MB
  now). Nomu's byte and struct arrays take less memory than Go's.
- **Scans match the twins and Go.** `Array<UInt8>` now scans faster than its twin, which reads through
  `elementPtr(at:)` (the raw-path cost 196.1 noted).
- **Builds.** Byte-array builds are 2× Go, through the append path. The object ring is 2.3× Go's time and
  2.5× its RSS, through the collector ([262](262-collector-gaps.md)). Layout plays no part in either.
- **Enum-held references:** binary-trees is in 260.8 (depth 21: 3.89 s and 445 MB, against Go's 5.27 s and
  205 MB, a node 40 → 24 bytes).

## Work

- **196.1** Per-type cost under slots against dense: memory and time for arrays of `Bool`, `UInt8` and
  payload-free enums, arrays of flag-like structs, and objects with a few small fields (allocation,
  collection, iteration). Done; see Results.
- **196.2** Access cost: code size and instruction counts for small-field loads and stores, widened slots
  against byte access. Done; see Results.
- **196.3** The erased path with alignment: the witness tables carry alignment, offsets become padded
  running sums; measured on the erased-call benchmarks, against fully reordered offsets computed at run
  time. Done; see Results.
- **196.4** Confirm nothing maps a Nomu struct onto memory laid out elsewhere (the runtime's records,
  assembly), which reordering would break. Done; see Results.
- **196.5** The recommendation, and if dense, the layout function's design for [260](260-enum-layout.md)
  and [181](181-array-managed-buffer.md) to build on. Done; see Results and Decisions.
- **196.6** The layout function in the midend, producing today's slot layout (every leaf 8 bytes, declared
  order), with every consumer of slot counts moved onto it: a refactor with no layout change, checked by
  the full tier. Done; see Results.
- **196.7** Turn on the dense layout.
  - **196.7.1** One-byte leaves in declared order, the erased path's padded offsets, real VWT alignment,
    `wordPath` on natural layout. Done; see Results.
  - **196.7.2** Field order: alignment descending, type-parameter fields last, with LLVM types built in
    memory order and a declared-to-LLVM index map at every field access; the actor mailbox at offset 8.
    Done; see Results.
  - **196.7.3** `Ptr<T>.alloc` passes the type's alignment. Done.
- **196.8** Re-run the 196.1 pairs: each slots program, now dense, should match its hand-packed twin;
  the full tier and the shape, layout and value-refs matrices green. Done; see Results.

- **196.9** Dense arrays and enums, through the dependencies: [181](181-array-managed-buffer.md) moves
  `Array` onto `ManagedBuffer`, and [260](260-enum-layout.md).4, 260.5 and 260.7 lay enums out with extra
  inhabitants. Then re-run the 196.1 byte-array pairs (`Bool`, `UInt8`, payload-free enums) against their
  hand-packed twins and Go, and binary-trees for enum-held references; 196 is done when they match.
  Arrays done: with 181 in, `Array<Bool>` and `Array<UInt8>` of 4M take 10 MB, matching their twins (they
  took 67). Payload-free enum arrays take 10 MB with 260.4 (`Array<Color>` matches its twin; they took
  67); generic enum instances (`Option<T>`) follow with 260.5 (`Option<TreeNode>` one word). Done; see
  Results.

## Exit

Every value laid out dense: fields, buffers and the erased path here, array elements through 181, enums
through 260's layout phases; the 196.1 pairs match their hand-packed twins, byte arrays included (196.9).

## Dependencies & triggers

- After [176](176-shaped-gc-roots.md) 176.5.2 (the slot rule restored and checked), so measurements start
  from a correct baseline.
- Depends on [181](181-array-managed-buffer.md) (dense array elements) and [260](260-enum-layout.md).4,
  260.5 and 260.7 (dense enums). Both build on the layout function 196.6 put in place.
- Feeds the GC benchmarking ([150](150-selfhosted-gc-ladder.md) GenImmix vs MMTk) and
  [178](178-runtime-gc-performance.md) (runtime and GC throughput): footprint changes nursery pressure.

## Refs

- `src/midend/ssair/sources/Layout.swift` — the layout function: `size`, `align`, `fieldsLayout`,
  `enumCaseLayout`, `enumPayloadSize`.
- `src/llvmgen/LLVMGenLayout.swift` — `llvmType`, `structType`, `enumType`, `sizeOf`, `objectSize`,
  `actorMailboxOffset`, `managedBufferElementStart`; `LLVMGenLayoutCheck.swift` — `checkLayout`.
- `src/llvmgen/LLVMGenGCMaps.swift` — `collectManagedOffsets`, `arrayElemStride`.
- `src/llvmgen/SSAIRToLLVM.swift` — `erasedTypeSize`, `erasedFieldOffset`, `erasedEnumPayloadOffset`.
- `tests/fixtures/shape_matrix/` — `layout_*`, `erased_layout*`.
