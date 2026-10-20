# Shaped GC roots — value-conditional scanning + frame-root relocation

**Avenue:** Risk (the moving-collector precision substrate) · **Type/Lifecycle:**
`gc · codegen · midend` · **Size:** L · **Status:** 176.1–176.3 built + green. 176.1 + 176.2 (bare `String`,
local and as a `class`/`actor` field); **176.3a (structs)** — frame-root placement for value aggregates;
**176.3b (enums)** — the discriminant-conditional half (an `Option<String>` / mixed-case enum relocates its
payload buffer only in the shaped case). Covered by the `verifySSAIR` I11 aggregate-rooting check (teeth
tests) and forced/evac oracles (`pair_string_gc`, `option_string_gc`, `enum_nonshaped_gc`); full suite
133/133. **On the strings critical path** ([121](121-string-utf8-model.md) builds on it, since `word0` is
`i64` in the end-state layout). **Capability complete.** The two throughput refinements moved to
[178](178-runtime-gc-performance.md) — the per-`String`-load volatile narrowing is
[178.2](178-runtime-gc-performance.md) and the Option A/B frame-cost measurement is
[178.3](178-runtime-gc-performance.md), alongside the pre-existing shaped-scan trace-speed item
[178.1](178-runtime-gc-performance.md). Two shape-descriptor generality gaps (nested enum-in-enum managed
payloads — fail-stopped at build today, not silent; and cross-module shape-table ordinals — the erased-shaped
path roots through the VWT, a different channel) are absorbed into
[179](179-value-level-gc-classification.md), whose unified descriptor path is their natural home. **176.5 is
open — a correctness bug:** a `String` local (or a struct holding one) read after a safepoint uses a stale
buffer pointer (the I11a reload misses the `struct String` wrapper), found closing
[195](195-link-time-gc-frame-index.md). The escape-promotion placement route is now 176.4
(stays with [148 §148.1](148-ssair-optimizer-tier.md)/[179](179-value-level-gc-classification.md)) ·
**Source:** split out of [121 String](121-string-utf8-model.md) (the GC capability the bit-stealing
`String` rests on) and [148 §148.1](148-ssair-optimizer-tier.md) (the addrspace-across-calls placement
route, formerly "route (c)"). **Design home:** [`../../internals/shaped-roots.md`](../../internals/shaped-roots.md).

## What

Make a managed pointer's **rooting** and **placement** a compiler-emitted *shape* the collector reads,
rather than a property fixed entirely by its LLVM `addrspace(1)` type. Three capabilities, layered:

1. **Value-conditional scanning.** A managed pointer that lives inside a value aggregate and is a
   reference only for some runtime discriminant. The collector reads the discriminant word, then traces
   the pointer word in exactly the cases that hold a reference. The motivating case is `String`'s
   bit-stealing word (`word0` is a heap buffer in `heap`, inline UTF-8 bytes in `small`, an immortal
   buffer in `immortal`; the tag sits in `word1`'s top byte so the pointer word stays clean and untagged);
   it generalizes to any tagged value that carries a reference in some cases
   (`Option<SomeClass>`, `Result<Buffer, E>`).

2. **Relocation takeover for shaped roots.** A value-conditional word cannot be typed `addrspace(1)` —
   that would relocate the inline-bytes case as if it were a pointer — so it cannot ride LLVM
   `gc.relocate`. For a shaped root whose target may move, the compiler pins the value to a stack slot
   across each safepoint (store-before / load-after), records the slot and its shape in the stack map,
   and the collector performs the conditional relocation itself: read the discriminant, relocate the
   pointer word in the reference cases, write the new address back into the slot. The post-call load
   observes the update, standing in for `gc.relocate`'s reload. The added mutator cost is a spill/reload
   around safepoints for a live shaped value — level with an ordinary root.

3. **Frame-root placement for escape-promoted values.** The same facility — a stack slot carrying a
   compiler-described field pointer-map the collector scans — is [148 §148.1](148-ssair-optimizer-tier.md)'s
   route (c). A value proven non-escaping is placed in a frame slot whose managed fields the collector
   scans in place, so a promoted object crosses a non-inlined call keeping its unmanaged placement
   instead of taking the `addrspace(1)` heap representation. This clears the addrspace-across-calls wall
   that blocks interprocedural stack promotion today.

The codegen type-maps (`LLVMGenGCMaps`) and the collector (`rtWalkFrom` + the flat offset loops in
`src/stdlib/runtime.nomu`) must agree on the shape descriptor. (Until 197 an MMTk binding consumed it too.)

## Why

A moving collector rewrites a managed pointer wherever it finds one, so it needs each pointer's location
exactly. Today that precision comes entirely from LLVM statepoints keyed on `addrspace(1)`
(`internals/backend.md`, "GC backend substrate"), where a single type encodes three decisions at once:
that a value is a managed reference, that the collector roots and relocates it at every safepoint, and
that it travels as a heap pointer. Inference wants to vary the second and third without touching the
first. Two independent features hit the same wall:

- **Bit-stealing `String` ([121](121-string-utf8-model.md)).** A 16-byte representation packs inline
  bytes into the same word that holds the heap-buffer pointer in other cases, so that word's
  managed-ness is per-value and dynamic — unreachable by a type-driven root set.
- **Interprocedural stack promotion ([148 §148.1](148-ssair-optimizer-tier.md)).** A value proven not to
  escape a non-inlined callee should be placed on the stack, but the callee's reference parameter is
  `addrspace(1)` and no `addrspacecast` survives a safepoint, so the promotion cannot land.

Both are the same shortcoming: rooting and placement are welded to `addrspace(1)`. This task decouples
them with a shape-aware root path, so a managed value can be tag-discriminated or stack-placed while the
collector still finds and fixes up exactly the references that are live.

## Keep the fast path

- Ordinary heap roots stay on stock LLVM statepoints. Only shaped roots take the side path, so
  non-shaped code is unchanged and un-regressed.
- Keep the return-address-keyed stack map — the property `backend.md` chose statepoints for over a
  shadow stack (no per-call tax). Shaped roots extend the record; they do not add cost to code that has
  none.
- The reclaimed responsibility is **root interpretation** (is this word a reference now, and does it
  move) plus a narrow slice of **placement** (pin-to-slot for shaped values). LLVM keeps doing liveness,
  spilling, and stack-map emission. This is the piggyback/parallel end of the gradient, not a wholesale
  replacement of `RewriteStatepointsForGC`.

## Phases

- **176.1 — value-conditional *tracing* descriptor** (read-only). The collector finds the discriminant
  word + the pointer word and traces the pointer only in the reference cases. Enough for a shaped root
  whose target does not move (a pinned / immortal buffer). This is the smaller, lower-risk half.
- **176.2 — relocation takeover** (pin-to-slot store/load + conditional writeback), so a shaped root's
  target can be relocated and compacted. This is the default `String` needs: [121](121-string-utf8-model.md)
  chose moving string buffers for the generational-nursery and fragmentation wins, so string buffers are
  ordinary movable heap objects, not pinned.
- **176.3 — frame-root placement for value aggregates holding shaped content** (design home:
  `shaped-roots.md` Stage 3b). Generalizes the shaped-root path from a bare `String` to *any value aggregate
  that transitively contains a shaped value* — a `struct` with a `String` field, an `enum` with a `String`
  payload (`Option<String>`). This is a **correctness gap today** (a `Pair { s: String; n: Int }` and an
  `Option<String>` held live across an evacuating GC read back garbage) and a compiler law: adding a `String`
  stored property must never need a per-type compiler change. Bounded because a value type cannot store a
  reference field, so the only managed content is shaped. **[121](121-string-utf8-model.md) rests on this** —
  it was previously (incorrectly) believed strings needed only 176.1 + 176.2. Staged:
  - **176.3a — structs** (fixed shaped-field offsets). **Done + green.** Record **one** shaped deopt pair per
    live shaped-containing slot — `(aggregate-shape-ordinal, slot-base)`, the bare alloca base (a stackmap
    spike confirmed a non-zero `gep(slot, off)` records as `Indirect` and is dropped; only a bare base is
    `Direct` — `shaped-roots.md` Stage 3b). As built:
    - `transitivelyContainsShaped` (structural predicate over struct fields) + `computeSlotLiveness` (generic
      liveness of the shaped-containing `stackAlloc` slots) in `ShapedLiveness.swift`; the egress
      (`setUpShapedHomes`) records each live slot's base at its crossing safepoints and the header poll.
    - The aggregate's value-layout descriptor (`valueDescId`, kind-0 + `nshaped`) carries the `String`
      sub-fields; the shared enumerator's fold recurses them, so the collector/stackmap are unchanged.
    - The one new runtime piece: the **ordinal→descriptor table** `__nomu_shape_table` (emitted by
      `emitShapeOrdinalTable`, read by a generalized `nomu_shape_desc_for_ordinal` — both walkers, one place).
    - Zero-init of the shaped slot (I11b) + volatile `word0` on `String`-typed loads (I11a).
    Oracle: `examples/pair_string_gc.nomu` (nogc = `immix` evac = `7366794707792290656`); suite 129/129.
    - **`verifySSAIR` I11 aggregate-rooting check (done).** A value aggregate that transitively contains a
      `String`, live across a safepoint, must be a frame slot (an address op codegen records); a first-class
      SSA aggregate is flagged (`SSAIRVerify.swift`, with `SSAAggregate` field types threaded in). Teeth:
      `testUnrootedShapedAggregateCaught` (caught) + `testShapedAggregateSlotPassesClean`. The `volatile`
      `word0` reload (I11a) and slot zero-init (I11b) are by-construction in the egress, below SSAIR.
    **Deferred within 176.3a:** the `String`-load volatile is applied to *every* `String` load (conservative
    — the per-safepoint narrowing is now perf line item [178.2](178-runtime-gc-performance.md)); and the shape
    table is per-compilation (cross-module ordinal unification absorbed into
    [179](179-value-level-gc-classification.md), since the erased-shaped path roots through the VWT, not this
    table).
  - **176.3b — enums** (discriminant-conditional offsets). **Done + green.** As built:
    - **Enum kind-2 descriptor** (`enumShapeDescId`): tag = case index at offset 0; each case's managed/shaped
      entries come from `collectManagedOffsets` over its payload fields (payload at slot 1). The unified
      per-case format grew to `(tag, nFlat, flat…, nShaped, (off, subId)…)` — a case carries both flat
      conditional pointers (`Option<SomeClass>`) and nested shaped sub-shapes (`Option<String>`). Serialized
      at `emitDescriptors` (deferred, since a sub-id resolves to a link-time section offset);
      `registerShapedMap` (String) writes the same shape with `nShaped = 0`.
    - **`collectManagedOffsets`** treats an enum field with conditional managed content as a nested kind-2
      shaped entry, so a struct holding an `Option<String>` nests the enum descriptor (`valueDescId` fold).
    - **Shared enumerator** (`nomu_gc_live_offsets`, both collectors) parses the unified format and recurses a
      matched case's sub-entries through a dedicated enum scratch (alias-free: enum payloads flatten structs
      inline, so a sub-entry is a `String` leaf). A **nested enum-in-enum payload is fail-stopped** at
      descriptor build (would alias the scratch) — the deferred edge.
    - `shapeOrdinal` routes an enum slot to its kind-2 descriptor; `transitivelyContainsShaped` (egress +
      `verifySSAIR`) and the I11 aggregate-rooting check extend to enums (teeth: `testUnrootedShapedEnumCaught`).
    Oracles: `examples/option_string_gc.nomu` (`Option<String>`, nogc = evac = `7366794707792276656`) and
    `examples/enum_nonshaped_gc.nomu` (the **conditional-soundness** oracle — a non-shaped `.count(Int)` case
    held across evac reads back intact, proving the tag is read before the payload is scanned). Suite 133/133.
    **Absorbed into [179](179-value-level-gc-classification.md):** nested enum-in-enum managed payloads
    (fail-stopped at build today, not silent — resolving it wants a reentrant enumerator scratch).
- **176.4 — frame-root placement route** for escape promotion ([148 §148.1](148-ssair-optimizer-tier.md)
  route (c)): a frame slot plus a field pointer-map the collector scans, letting a promoted object cross
  a non-inlined call without the heap representation. Rides the done inference stack that proves
  non-escape (166 / 168 / 169 / 164). Shares the frame-slot-scanned-by-map facility with 176.3 but is a
  distinct driver (escape-promoted would-be-heap objects, which *can* carry `addrspace(1)` fields).

- **176.5 — one shape per type, derived structurally; every consumer reads it.** Opened by a correctness
  bug; the fix is to stop answering "is this shaped?" in several places.
  - **The bug (an I11a gap).** A heap `String` held in a frame local reads a stale buffer pointer after a
    collection moves the buffer. Reproduction (30 lines): `let s = "seed".concat(…)` held across a loop that
    allocates, read back by `s.byte(at:)`; wrong once the moved-from memory is reused.
    - **Cause.** The egress `.load` lowering (`SSAIRToLLVM.swift`, `case .load`) makes `word0` volatile only
      when the loaded type is `.stringBase`. A `let s: String` slot holds `struct String` (the single-field
      wrapper, 121.1.1), so its load is a plain `load { i64, i64 }`. A deopt operand marks the slot read but
      not written, so LLVM forwards the pre-call value; the arm64 code keeps `s` in `x19`/`x20` and never
      reloads the slot. The collector does rewrite the slot (seen in lldb: `word0` `0x4ba000000` →
      `0x4ba200000`, bytes intact); the program ignores it. Structs and enums holding a `String`, loaded
      whole, take the same plain branch. The homed-value path (`val`, `stringHome`) is correct: homing uses
      the wrapper-aware `isShapedType`.
    - **Scope.** Both collectors: MMTk GenImmix with the C walker (`NOMU_GC_STRESS`) and the self-hosted
      minor collection both show it; it predates 195 (the last committed compiler gives the same counts).
      Seen only where moved-from memory is reused soon: nursery collections. Immix defrag often leaves the
      buffer in place, and the force-all collector copies to fresh blocks without overwriting the old ones,
      so a stale read still finds the right bytes — **which is why the existing `*-evac` oracles
      (`pair_string_gc`, `option_string_gc`, `gc_string_relocate`) cannot catch a missed reload.** Default
      settings did not show it in the runs tried.
    - **Why it happened.** Six places decide shapedness independently: `isShapedType` (SSAIR liveness: leaf
      + wrappers), `shapedStructs` (computed in `LLVMGen` and again in `SSAIRVerify`),
      `transitivelyContainsShaped` (egress and verifier copies: struct/enum recursion), `shapeOrdinal` and the
      descriptor builders (`valueDescId`, `enumShapeDescId`, `collectManagedOffsets`, each with a wrapper
      special case), and the `.load` reload (`.stringBase` only). The wrapper was added to some and not
      others.
  - **Requirement.** Adding a new shaped leaf type, or placing shaped content in any aggregate — struct,
    enum, class, actor, closure environment, spawn environment, actor message, array element, generic
    instantiation (mono or erased), parameter or return — needs no change to any consumer, and a consumer
    cannot disagree with the others.
  - **Design.**
    - **Shape propagates up.** One query, `shape(T)`, computed once per type and cached, from a registry of
      shaped **leaves** (today `StringBase`: two words, a discriminant in `word1`'s top bits, `word0` managed
      in the `heap` case). Derivation is structural: a leaf is its own shape; a struct (a wrapper is a struct
      of one field, no special case) is its fields' shapes placed at their offsets; an enum is a per-case
      shape keyed by its tag; a class or actor body, a closure or spawn environment, and an actor message are
      structs of their fields; an array buffer is its element's shape repeated at the stride; a generic
      instantiation is its substituted type's shape, and an erased `T` reaches it through its VWT descriptor.
      The result lists each shaped sub-value: its byte offset, its leaf, and the enum cases (if any) under
      which it is present, plus the plain managed-pointer words.
    - **Consumers map down.** Each reads `shape(T)` and nothing else: SSAIR liveness, homing and slot
      recording (record when the shape is non-empty), the I11 verifier, the shape ordinal, descriptor emission
      (kind-0 value layout and kind-2 enum shapes, both walkers reading them unchanged), and the I11a reload
      (the words to reload volatile are the shape's shaped `word0`s). A check (test or verifier) rejects a
      consumer matching `.stringBase` or a wrapper name directly; only the leaf registry names a leaf.
    - **Where it lives.** In the `ssair` module beside `ShapedLiveness.swift`, taking the type environment
      (struct fields, enum cases) both the midend and the egress already have, so the egress and the
      verifier call the same function instead of keeping parallel copies.
    - **Heap aggregates need no reload.** A class, actor, closure or array field is read through its
      object's base pointer, which RS4GC relocates, so the read sees the moved object; their correctness rests
      on descriptors, which come from `shape(T)`. The reload concerns frame slots only.
    - **The reload mechanism.** Options:
      - (a) Volatile-load the whole aggregate when its shape is non-empty. Type-agnostic; makes plain words
        (an `Int` beside a `String`) volatile too.
      - (b) Load the aggregate's words and make exactly the shape's shaped `word0`s volatile, per the shape.
        Precise; matches I11a's text.
      - (c) Model the collector's write instead: capture each recorded slot (a zero-cost inline-asm operand at
        its zero-init) so LLVM assumes any call may write it, and drop `volatile`. Reloads only after calls,
        so a call-free loop keeps the value in registers; changes the documented I11a mechanism and depends
        on RS4GC leaving the asm alone and on capture analysis at O3.

      **Decided: (b)**, since the shape already gives the words and it keeps I11a's contract. (c) goes to
      [178.2](178-runtime-gc-performance.md) as a candidate for the volatile narrowing it already tracks.
  - **176.5.1 — investigation before building. Done.** Cases and runner: `tests/fixtures/shape_matrix/`
    (`run.sh`; each case prints `bad N`, correct is `bad 0`). Results are the same under the debug and
    release (`-O`) pipelines.
    - **Matrix.** Wrong under both nursery settings (GenImmix stress, self-hosted minor):
      - frame locals — a `let`/`var` `String`, a struct holding one, `Option<String>`, `Option<Pair>`, and a
        `let s` held across calls to a mono or erased generic (`mono_generic`, `xmod_erased`); the I11a
        reload miss. `var_local` (reassigned every 1000 iterations) shows it only under the self-hosted
        minor.
      - `Array<String>` and `Array<Option<String>>` elements, also when the array is a class field: the
        array-buffer descriptor drops shaped entries (below). GenImmix stress panics in the copy
        (`gcbinding/lib.rs:376`, a copy to a null address) and the process hangs.
      - a `String` in a queued actor message (`actor_msg_queued`): the message descriptor drops shaped
        entries. Same GenImmix panic.
      - a read-only method reading `self.s` (`readonly_self2`).
      - a class or struct with two `Bool` fields before a managed field (`layout_*`), including a plain
        class reference: a layout disagreement (below).
      - an enum whose payload is a managed pointer, held as a local (`enum_array_local`,
        `Option<Array<Int>>`): a segfault under both. The payload words are `i64`s, so the statepoint
        rewrite cannot see the pointer, and slot recording counted only `String` content.
    - Correct: a class field, an actor field, `Option<String>` as a class field, a closure capture, a spawn
      environment, a single actor message, a `String` parameter (same module and across modules), a
      `String` return, and the bodies of mono and erased generics (`*_fresh`).
    - **Wrong without any collection.** A `String` spawn result read twice (`spawn_result`, `bad 4000` under
      NoGC): `lowerSpawnJoin` (`EgressConcurrency.swift`) writes `g.values` directly instead of through
      `define`, so a homed result's home is never written and stays the empty string.
    - **Rejected at compile time** by the I11 verifier ("shaped-containing aggregate … spans a safepoint as a
      first-class value"): a shaped aggregate held as a value across a safepoint — a `Pair` or
      `Option<String>` parameter (`agg_param`), a temporary argument while the next argument is evaluated
      (`f(Pair(…), Pair(…))`, `[Pair(…), Pair(…)]`, `array_pair`), a mutating method's `self`
      (`mutating_self`). Sound by rejection; ordinary programs fail to build. Only `String` and its wrappers
      get value homes; a multi-field aggregate is rooted only when it already sits in a `stackAlloc` slot.
    - **Found and fixed on the way: nested-call inlining.** `f(g())` with both single-block callees failed
      I3 ("use of undefined value") after inlining, for any type (`print(hold(s0()))` with `Int`). The splice
      bound `f`'s param to `g`'s pre-substitution result id. Fixed in `Inlining.swift`
      (`spliceSingleBlock` resolves arguments through `subst`). A suite case is owed (176.5.7).
    - **Descriptor builders that drop shaped entries** (they call the `collectManagedOffsets` overload that
      discards them): `arrayBufTypeId`, `managedBufferTypeId` (header and element), `spawnBoxTypeId`,
      `messageTypeIdValue` (`LLVMGenActor.swift`), and the VWT's POD flag (`valueWitness`: a `String` has no
      flat offsets, so its VWT says POD; no reader consults the flag today). `closureTypeId` keys on the LLVM
      type (`p1`) and would miss a `String` capture, but has no callers: closures and spawn environments are
      synthesized classes and use `typeId(forHeapType:)`, which keeps shaped entries.
    - **Layout disagreement.** Descriptor offsets come from `slotCount` (every field a multiple of 8 bytes);
      codegen lays aggregates out as unpacked LLVM structs, where `Bool` is `i1` and `UInt8` is `i8`.
      `class Holder { a: Bool; b: Bool; r: Box }` is `{ i64, i1, i1, ptr }` (pointer at byte 16, 24 bytes);
      its descriptor says pointer at 24, size 32. The collector skips the real field and reads one word past
      the object. Affects class, actor, struct and enum-case layouts with two or more sub-8-byte fields in a
      row; one such field before an 8-byte field is padded to agree (`layout_control`). The erased-generic
      path is a third layout (`erasedTypeSize`/`erasedFieldOffset`: VWT sizes from `slotCount`, no padding),
      so a mono caller and an erased body disagree with no collection at all: `make(7)` returning an erased
      `Trio<T> { a: Bool; b: Bool; v: T }` reads back `4307809280` under NoGC (`erased_layout`; one `Bool`,
      `erased_layout_control`, prints 7).
    - **Pipelines.** The homed path's `load volatile i64` before each statepoint survives both
      `function(mem2reg,sroa)` and `default<O3>` (checked in `NOMU_DUMP_LLVM` post-opt IR).
    - **Enum layout.** `{ i64 tag, [P x i64] payload }`, each case's fields GEP'd as a case struct over the
      payload; the descriptor's tag at 0 and fields from slot 1 agree with it when every field is 8 bytes,
      and share the layout disagreement otherwise.
    - **Splitting a load for (b).** A struct's shaped `word0` is an `insertvalue`/GEP path through its
      LLVM fields (a wrapper is its field's type, `LLVMGenLayout.structType`); an enum's is element
      `offset / 8 - 1` of the payload array. `shape(T)` gives byte offsets, so the reload maps an offset to a
      path, which needs the offsets to be LLVM's (the layout disagreement above).
    - **Slot read paths.** `.load` is the only read of a recorded slot; the erased `.store` `memcpy` reads
      erased buffers, which are shadow-stack rooted. A slot's address also reaches a mutating method as
      `self`, whose reads are `.load`s through the pointer, so the reload covers them.
    - **Consumers.** `isShapedType(t, shapedStructs)` → Bool (liveness, homing); `computeShapedStructs` →
      wrapper names (egress `LLVMGen.shapedStructs`, verifier); `transitivelyContainsShaped` → Bool (egress
      slot recording and zero-init, verifier I11); `isShapedWrapper` → Bool (`shapeOrdinal`, the egress
      `makeStruct`/`extractField` identity, `structType`'s wrapper-is-its-field layout); `shapeOrdinal` → i32,
      registering a descriptor; `collectManagedOffsets` → flat offsets + `(offset, shape descriptor id)`;
      `valueDescId` / `enumShapeDescId` / `typeId(forHeapType:)` → descriptor ids. `shape(T)` must carry the
      wrapper identity, per-case presence for enums, flat managed offsets, and shaped offsets with their leaf.
    - **Why default settings hid it.** No collection ran: the default heap is 1 GiB and the repro allocates
      less (`NOMU_GC_STATS`: "no GC ran"). With real pressure collections and no stress mode, a 32 MiB heap
      (`NOMU_GC_HEAP`) gives 3 GCs and 2,000,580 wrong reads of 3,000,000; 8 MiB gives 12 GCs and 2,750,148.
      Any program that collects once is exposed from then on.
  - **176.5.2 — one layout. Done.** Descriptor offsets and codegen addresses come from one layout, so the
    `layout_*` and `erased_layout` cases pass. Options:
    - (a) Lay every field out in 8-byte slots (store `Bool`/`UInt8` fields widened), so `slotCount` is the
      layout. Simple, and the descriptors stay as they are; costs footprint for small fields.
    - (b) Compute descriptor offsets from LLVM's data layout (`LLVMOffsetOfElement`) for the types codegen
      builds. Keeps dense fields; every descriptor builder and `shape(T)` read offsets from LLVM.
    - (c) Nomu's own layout function (offsets, size, alignment per type) that both codegen and the
      descriptors read, with LLVM types built from it. Dense fields and one owner of layout, at the cost of
      building the function.

    **Decided: restore the 8-byte-slot rule** (option (a)). It is the layout every component except
    codegen's storage types already follows (`slotCount`, descriptors, enum payloads, array strides, the
    erased path); it broke when 8.5.2 made `Bool` `i1`, since `llvmType` gives both the register and the
    storage type. `Bool`/`UInt8` stay `i1`/`i8` in registers and are stored in full slots in aggregates, and
    a check rejects any aggregate whose LLVM layout differs from `slotCount`. Dense layout and its
    performance are [196](196-dense-value-layout.md).

    **Built.** `fieldStorageType` (`LLVMGenLayout.swift`) stores `Bool`/`UInt8` fields as `i64` in struct,
    class, actor and enum-case types; `toFieldStorage`/`fromFieldStorage` widen and narrow at the three
    first-class field sites (`makeStruct`, `extractField`, the struct-value property getter); reads and
    writes through a field address keep the narrow type and touch the slot's low bytes. `checkSlotLayout`
    (`LLVMGenLayoutCheck.swift`) runs after egress under the host data layout and fails the compile on any
    field whose LLVM offset differs from the slot arithmetic; with the widening reverted it reports
    `class Holder field 1 (Bool) is at byte 9 in its LLVM layout but at 16`. `layout_class_ptr`,
    `layout_class_str` and `erased_layout` pass under all three settings.
    - The existing suite case `gc-shapes-across-modules-self` fails intermittently on two carriers (3 of 10
      runs with the committed compiler, the same with this change): its `var t: Tail` slot is the I11a
      reload miss under the self-hosted minor. 176.5.4 fixes it.

  - **176.5.3 — `shape(T)` and the leaf registry. Done.**
    - **176.5.3.1 — `shape(T)`. Done.** `ssair/sources/Shape.swift`: the leaf registry (`ShapeLeaf`: words,
      discriminant word and shift, managed words per tag), `Shape` (plain managed offsets plus conditional
      entries: a leaf, or an enum's per-case payload shapes), and `ShapeEnv` (`shape`, `slots`, `leaf`,
      `isShapedValue`, `isWrapper`, `hasConditional`, `fieldsShape`) over closures the egress and the
      verifier each supply. `slots` is the one slot layout; the egress's `slotCount` reads it. Unit tests in
      `ssair/tests/ShapeTests.swift`.
    - **176.5.3.2 — compiler consumers. Done.** SSAIR liveness and homing, the I11 verifier, egress slot
      recording and zero-init, `isShapedWrapper`, `shapeOrdinal` (leaves take the first ordinals in registry
      order) and the shape table, and every descriptor builder (`typeId(forHeapType:)`, `valueDescId`, the
      enum kind-2 descriptor, the spawn box, the actor message, the VWT POD flag) read `shape(T)`. The homed
      value's slot type, its reload words and its deopt ordinal come from its leaf. Removed:
      `isShapedType`, `computeShapedStructs`, both `transitivelyContainsShaped`, `collectManagedOffsets` and its
      discarding overload, `enumHasManagedOrShaped`, `stringShapeId`, and the dead `closureTypeId`. Slot
      recording now counts an enum with managed payload (`hasConditional`), so `enum_array_local`'s slot is
      recorded; it still reads stale through the plain `.load` (176.5.4).
    - **176.5.3.3 — shaped buffer elements, both collectors. Done.** A kind-1 descriptor carries its
      element's shaped pairs after the element offsets (`nshaped`); the C enumerator takes an element's
      address for kind 1 and folds them as for kind 0, and the shaped accessors read past the header prefix.
      MMTk's `scan_object` and `mv_obj_hash` and the self-hosted collector's eight buffer loops and
      `rtObjHash` enumerate per element when the elements are shaped and keep the hoisted map otherwise. A
      `ManagedBuffer` header with conditional content is a compile error. `array_string`, `array_option` and
      `array_pair_append` pass under both collectors.
    - **176.5.3.4 — direct-match check. Done.** `ssair/tests/ShapeConsumerTests.swift` reads the consumer
      sources (shaped liveness, the verifier, the GC-map, actor, VWT and layout-check files) and fails on
      `.stringBase`, `"String"` or `strTy` in code; a probe edit confirmed it fails. Not covered:
      `SSAIRToLLVM.swift`, which also holds `String` operations; its one shape decision on a leaf is the `.load`
      reload, which 176.5.4 replaces.
    - `actor_msg_queued` went from 47959 wrong reads to 2 (self-hosted minor) and from a GenImmix panic to
      about 25: the message descriptor now scans the `String`. The rest is an operand read before an
      instruction's internal allocation (176.5.5).
  - **176.5.4 — the reload from the shape, and complete slot recording. Done.**
    - **Reload** (option (b)): a load of a type with conditional content through an `addrspace(0)` address
      (a frame slot, a GEP into one, a `self` pointer into a caller's slot, an erased buffer) loads the
      aggregate and reloads each conditional managed word volatile — a leaf's managed words, an enum entry's
      payload words — inserting it at its index path (from slot offsets; an enum payload word is element
      `offset / 8 - 1` of `[P x i64]`). A plain managed word needs no volatile: a pointer loaded before a
      safepoint is an SSA value the statepoint rewrite relocates. A heap (`addrspace(1)`) load stays
      ordinary, since its base is relocated.
    - **Escaped slots.** A slot whose shape has only plain managed words is promoted to SSA by SROA unless
      its address escapes; once it does (it or a `fieldAddr`/`elementAddr` of it is a call operand, or
      flows through a block argument), the slot stays in memory where the statepoint rewrite does not look.
      Record such a slot wherever it is live, as a slot with conditional content is (option (b); recording
      every non-empty slot would block SROA for every struct holding a reference). Found by
      `struct_array_mutating` with `NOMU_NO_INLINE=1`: a segfault under both collectors.
    - **Operands at their own safepoint.** A recorded slot used as an operand of a safepoint instruction
      (a slot passed to a call that runs on it) counts as crossing that safepoint; a derived address records
      its root slot (the deopt bundle needs the bare alloca).
    - **Verifier: not added.** The egress and a verifier check would both call `recordedSlots`, so the check
      would verify nothing independent; the matrix's no-inline leg (`COMPILE_ENV=NOMU_NO_INLINE=1`) is the
      backstop for an escape path the rule misses.
    - **Built.** `recordedSlots` (`ssair/sources/ShapedLiveness.swift`) gives the recorded slots and maps each
      slot-derived address (`fieldAddr`, `elementAddr`, a block parameter it flows into) to its slot; a block
      parameter fed by two slots is a compile error. The egress tracks those ids' liveness, adds a safepoint
      instruction's own slot operands, and records roots. `.load` goes through `loadReloading`: a frame load of
      a type with conditional content reloads `Shape.conditionalWords` volatile at their index paths (a leaf
      reads word by word); the volatile payload word survives `default<O3>`. Unit tests in
      `ssair/tests/RecordedSlotsTests.swift`.
    - **Result.** Every frame-local case passes under both collectors, debug, `-O` and inliner off:
      `local_string`, `struct_local`, `enum_local`, `enum_struct_local`, `enum_array_local`, `var_local`,
      `mono_generic`, `readonly_self2`, `layout_struct_local`, `struct_array_mutating`. The suite is 162/162,
      and `gc-shapes-across-modules-self` passes 20 of 20 on two carriers (3 of 10 failed before).
      `xmod_erased` keeps exactly one wrong read under GenImmix stress (176.5.6).
  - **176.5.5 — value homes for every shaped type.** A value whose shape is non-empty and that crosses a
    safepoint gets a frame home, as a `String` does today: aggregate parameters, temporaries, and `self`,
    so the I11-rejected cases build. Every producer writes its home through `define`, including the spawn
    join (`spawn_result`). An instruction that allocates and then stores its operands (`actorSend`,
    `arrayLit`, `box`, `makeClosure`, `spawn`) has its shaped operands recorded at that allocation and read
    after it: the egress now reads them first (`args.map { val($0) }` before `emitActorSend`), so a collection
    at the allocation stores a stale `String` into the message (`actor_msg_queued`).
  - **176.5.6 — erased-generic buffers under MMTk.** An erased call's argument buffer (`erased.arg`) is
    registered only on the fiber's shadow stack (`rtShadowPush`), which only the self-hosted collector walks
    (`rtWalkShadow`); the C walker never reads it, and `rtShadowPush` returns early when no fiber is bound (the
    default scheduler). So under MMTk a managed value passed through an erased generic is rooted nowhere while
    the call runs. `xmod_erased` shows it once per run (the `String`'s first promotion lands inside the call,
    and the moved-from memory is reused); with a fresh value each call the stale read finds intact bytes, so
    other cases pass by luck. The result buffer (`erased.ret`) and callee-side `T` temporaries ride the same
    mechanism. Options:
    - (a) MMTk's root scan walks the shadow stack too, with a shadow head for threads that run no fiber.
      Covers caller buffers, result buffers and callee-side `T` values (their descriptor comes from the VWT).
    - (b) The caller records each concrete-typed erased buffer in the call's deopt bundle, like a slot (its
      type is known at the call site). Uses the frame-record path both walkers already read, but covers only
      caller-side buffers; callee-side `T` values still need the shadow stack.

    **Decided: (a)**, since it covers the callee side, which (b) leaves to the shadow stack anyway.
    **Closed by [197](197-retire-mmtk-and-c-scheduler.md)** (MMTk and the C scheduler retired): on the one
    runtime erased buffers are rooted through the shadow stack, and `xmod_erased` / `xmod_erased_fresh` read
    `bad 0` on every shape-matrix leg (default, nursery, stress-minor, stress-major). Neither option is built.
    - **Scheduler and collector pair.** The Nomu scheduler implies the Nomu collector and the reverse: MMTk
      with the Nomu scheduler was wrong for every case, including a class field (`class_field`: 995750 wrong
      reads; `array_string` trapped), because only the Nomu collector walks the Nomu scheduler's carriers
      and shadow stacks. The pairing guard built here was deleted with the runtime selector in 197.
  - **176.5.7 — tests.** The matrix into the suite with collecting legs (the `run.sh` set: a 64-block
    nursery, `NOMU_GC_STRESS` minor, `NOMU_GC_STRESS` + `NOMU_MATURE_FLOOR` major); nursery legs added to the
    existing shaped oracles, which today use only stress and cannot see a missed reload; a no-inline leg
    (`COMPILE_ENV=NOMU_NO_INLINE=1`); a nested-call inlining case (`f(g())`).

## Dependencies & relationships

- **[190](190-explicit-module-builds.md) depends on 176.5.** 190 closes after the one-shape-per-type fix.

- **Unblocks [121 String](121-string-utf8-model.md), from 121.1 on.** `word0` is a bare `i64` in the
  end-state layout, so 121.1 (immortal+heap) already needs 176.1 (conditional tracing) + 176.2 (moving
  buffers) — the shape descriptor is exercised by the `heap`-vs-`immortal` split (relocate `heap`, skip
  permanent `immortal`). `small` (121.3) adds no GC work, only stdlib SSO byte code: it is a tag value the
  descriptor already excludes. The reduced-SSO interim (typing `word0` `addrspace(1)` and retyping at 121.3)
  was rejected as throwaway. **176.3 (frame-root placement for value aggregates with shaped content) is needed
by strings** — any `struct`/`enum` holding a `String` by value (demonstrated broken across evac). 176.4 (the
escape-promotion placement route) stays with 148/179.
- **Is [148 §148.1](148-ssair-optimizer-tier.md)'s parked placement decision** (route (c)); 176.3 is the
  build. The inference track it was waiting on ([164](164-formal-inference-stage.md)) is done, and the
  escape summary it consumes is [169](169-interprocedural-escape-summary.md).
- **Rests on** the statepoint / stack-map substrate (`internals/backend.md`, "GC backend substrate") and
  the GC type-descriptor machinery (`LLVMGenGCMaps`, `internals/memory-model.md` §6).
- **Couples with** scalar promotion's reference-like-field widening ([148 §7.3.1 A2](148-ssair-optimizer-tier.md)):
  a bit-stealing `String` field is value-conditional, so its treatment as a loop-carried φ member must
  agree with the shaped-root model.
- **Both collectors** must stay in lockstep — the codegen type-maps and the self-hosted Nomu tracer — or
  the GC-stress suite legs break.
- **Broader alternative:** [179 value-level GC classification](179-value-level-gc-classification.md) takes
  the GC-residency signal off `addrspace` entirely (one managed address space, a value-level managed-set fed
  to a forked `RewriteStatepointsForGC`), dissolving the same `addrspace(1)` biconditional at its root
  instead of piggybacking a side path on it. 176 is the piggyback that ships without forking RS4GC; 179 is
  the larger refactor. They overlap on the pointer cases; the `String` `small` bit-punned word stays 176's
  `kind 2` shape descriptor under either, and 179 reuses 176.3's frame-root field-map. The two are weighed
  against each other by 179's move-1 payoff measurement; neither depends on the other.
- **Independent perf follow-up:** [177 register-resident GC roots](177-register-resident-gc-roots.md) —
  whether LLVM's `max-registers-for-gc-values` lever helps ordinary roots, and if so whether a shaped root
  can share it. 176 ships on the stack-slot form regardless; 177 is a later optimization on top.
- **Trace-speed obligation:** the shared scan enumerator (Stage 5) must keep the kind-0 flat scan at its
  current cost — line item [178.1](178-runtime-gc-performance.md).
