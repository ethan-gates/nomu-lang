# String / UTF-8 model

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · stdlib` · **Size:** L ·
**Status:** **121.1 + 121.2 (SSO) complete** — green (suite 133/133, incl. the `module_generic_string`
cross-module relocation leg). `String` is a Nomu struct **off the C floor**: the surface is Nomu
(`count`/`isEmpty` computed properties, `eq`/`lt`/`byte(at:)` methods, `concat`) and all four `StringBase` ops
are codegen — `fromStaticUTF8` (literals, `lowerStringLit`), `allocHeap` (`__stringAllocHeap` through the
shared `emitManagedBufferAlloc`), `count`/`bytePointer` (`strLen`/`strPtr`). The heap buffer is a
`ManagedBuffer<EmptyHeader, UInt8>` on the one shared tail-alloc path; the bespoke `stringStorageTypeId` /
`__nomu_stringstorage_typeid` are retired. No String function remains in C; `rt_read_line` (I/O) is the only C
String constructor, via the `nomu_str_make` inline helper. **121.2 (SSO):** all three tags live — short
literals (≤15 B) and short `concat` results are `small` (inline, no allocation), longer ones `immortal`/`heap`;
`strLen`/`strPtr` are tag-aware, and a `small` value's inline bytes are materialized to a per-call stack slot
when a byte pointer is needed (the small/heap/immortal split is invisible above `StringBase`). Representation
is chosen by **result size** — small→heap graduation is upward-only, no heap→small demotion (see *Representation*).
[176 shaped GC roots](176-shaped-gc-roots.md) is **done** including 176.3 frame-root placement.
`byte(at:)` is an unchecked load today; the bounds-checked form (a `precondition` primitive + analysis-based
removal) is [183 precondition / bounds checks](183-precondition-bounds-checks.md). **121 is complete** — the
byte-level `String` is done and parser-ready; `String` is immutable today (no mutation path), so copies share
the write-once buffer and COW does not yet bite. Follow-ons are their own tasks: checked `byte(at:)` →
[183](183-precondition-bounds-checks.md); Unicode views → [184 String Unicode views](184-string-unicode-views.md);
`Substring` → [185 Substring](185-substring.md); `withBytes` → [152](152-first-class-functions.md);
`Array<UInt8>` interop → [120 stdlib](120-stdlib-core.md); mutation-in-place (`StringBuilder`) +
compiler-inferred COW → the value-semantics effort ([123 copy-on-write](123-copy-on-write.md)). · **Source:**
deferred.md (stdlib track); pulled forward because a hand-written parser
([163 manifest/YAML](163-manifest-yaml.md)) needs a real `String`.

## Goal

Replace the builtin `String` (a C primitive, `{ i8* data, i64 len }` with immortal/leaking storage) with a
**stdlib `String` written in Nomu**, built to scale: UTF-8, value semantics, small-string optimization,
zero-copy literals, a GC-managed growable buffer, and a layered Unicode API. The builtin is retired.

## Model (decided)

- **UTF-8 storage.** Bytes are the backing; the public low-level unit is the **byte** (`UInt8` at a byte
  offset) — what a parser wants. Unicode scalars and grapheme clusters are **views layered on top** (now
  [184 String Unicode views](184-string-unicode-views.md)), so the parser works on bytes now and the type
  grows into full Unicode without reshaping its core. (Decision: *bytes now, scalar/grapheme views layered* —
  the byte core is primary, not opaque-index-only from the start.)
- **Value type** (`struct`) with value semantics; the backing buffer is shared on copy and copied on
  mutation (copy-on-write). Immutability is the default; mutation needs a `var` binding. (The COW elision and
  a mutating builder ride the value-semantics effort, [123 copy-on-write](123-copy-on-write.md) — see *Phases*.)
- **No separate `Char` primitive** (carried into [184](184-string-unicode-views.md)): a grapheme is a
  `String` (a small one); a Unicode scalar is a `UInt32`-carrying value from the scalar view.

## Type layering (settled): `StringBase` and `String`

The implementation is layered so the compiler magic is quarantined in the lowest type:

- **`StringBase`** — an **internal** compiler-primitive type: user programs never name it and it is not
  exported from the stdlib. It *is* the 16-byte bit-stealing shaped value (Representation, below) and is the
  sole bridge to the shaped-object machinery ([176](176-shaped-gc-roots.md)), for which there is no Nomu
  surface. It may be implemented in codegen/C — the magic is allowed to stay non-Nomu — and stays thin:
  beyond the representation it exposes exactly four operations.
- **`String`** — a pure-Nomu `struct String { let base: StringBase }`, its **only** stored property a
  `StringBase`. Every user-facing operation (the byte layer; `==`/`<`/`+` as methods until the language has
  operators; slicing; hashing; `StringBuilder`) is ordinary Nomu written against the four ops. This is the
  type user code and the rest of the stdlib see.
- **`Substring`** — a lightweight zero-copy span over a `String`'s bytes → [185 Substring](185-substring.md)
  (design decided: Swift-model GC-backed span, distinct type, `small` base inline-by-value, slicing returns a
  `Substring`, `String(sub)` to copy). It is the reason the byte-access op lives on `StringBase` as a
  first-class primitive, so `String` and `Substring` share it. Build is deferred (no blocker).

**The four `StringBase` ops — the whole magic boundary:**

| op | role | caller |
|----|------|--------|
| `StringBase.fromStaticUTF8(_ ptr: RawPtr, _ count: Int) -> StringBase` | the `immortal` case, no alloc | the compiler, through the `String.fromStaticUTF8` initializer it targets for a literal |
| `StringBase.allocHeap(_ count: Int) -> StringBase` | a `heap` value with a fresh zeroed managed buffer (the plan-aware rooted alloc, encapsulated) | stdlib `String` builders — `concat`, later `StringBuilder` / copying slice |
| `base.count -> Int` | byte count, read from `word1` with no dereference | stdlib `String` (`count`/`isEmpty`/`eq`/sizing) and the compiler's `print` |
| `base.bytePointer() -> RawPtr` | the reload-aware, tag-aware byte address | stdlib `String` (`byte(at:)`/`eq`/`lt`/copy sources) and the compiler's `print` |

`small`/SSO (121.2, done) added a `smallConcat` inline builder alongside these. With these, `concat` is
ordinary Nomu — for a ≤15-byte result `smallConcat`, else `allocHeap` then two gc-leaf `memcpy`s from the
inputs' `bytePointer()`s — and the heap path is GC-safe because `allocHeap` is the only safepoint (the inputs
ride the shaped-root path across it) and the copies run with no
safepoint between them.

**Single-field-wrapper-is-shaped.** `String` and `StringBase` are representationally identical (one field at
offset 0, 16 bytes, two registers), so the shaped-value treatment keys on `StringBase` and `String` inherits
it transparently: `isShapedType(String)` reduces to `isShapedType(its one field)`, the `kind 2` descriptor
applies to `String`'s layout directly, and a `String` local rides the shaped-root path while a `String` field
rides the object-field fold — no String-specific GC code. The rule generalizes to any newtype over a shaped
value.

**Compiler couplings, held to two:** (1) a string literal lowers to `String.fromStaticUTF8(<static UTF-8
global>, count)` — one Nomu symbol the compiler targets; (2) `print` of a `String` stays compiler-special,
reading `base.bytePointer()`/`base.count`. Retiring the builtin `.string`/`strTy` typing so `String` resolves
to this Nomu struct is 121.1.5.

## Representation

This is `StringBase`'s layout — a **hand-rolled 16-byte bit-stealing value**, a two-word
`{ i64 word0, i64 word1 }`, Swift-String-shaped, not a language `enum`. The discriminant lives in the **top
byte (byte 15 — the top byte of `word1`)**, matching Swift's small-string layout so the inline bytes stay
contiguous from offset 0. Three cases share the 16 bytes:

- **`small`** — SSO. Up to **15 inline UTF-8 bytes** sit **contiguous at offsets 0–14**; byte 15 carries the
  discriminant plus the inline count (0–15). Zero allocation. Reading a byte pointer from a `small` value
  materializes the 16 bytes to a stack slot (no persistent address exists); the byte layer's uses are
  immediate, so the slot is live for them. **Built (121.2).**

**Representation is chosen by result size (graduation, upward-only).** Each operation sizes its *fresh* value:
a result ≤ 15 bytes is `small`, a larger one is `heap` (or a long literal is `immortal`). So a string
*graduates* `small → heap` invisibly as it grows past 15 bytes, and the reverse (`heap → small` demotion)
never occurs — it cannot arise from `concat` (a `heap` input is always > 15 bytes, so any result containing it
is > 15), and no operation re-inlines `heap` content into `small`. When slicing/`Substring` lands, a ≤15-byte
slice of a `heap` string stays heap-backed (shares the parent buffer) rather than demoting — same rule.
- **`immortal`** — `word0` holds a clean pointer to a static UTF-8 buffer; `word1`'s bytes 8–14 carry the
  count, byte 15 the tag. **String literals land here**: no alloc, no copy, no free — the one good property
  the builtin has, kept.
- **`heap`** — `word0` holds a clean pointer to the managed growable byte buffer (below); `word1`'s
  bytes 8–14 carry the count, byte 15 the tag plus a heap-flag region. GC-tracked and relocated; no manual
  free.

**`word0` is the value-conditional word** — a clean buffer pointer in `heap`/`immortal`, inline bytes in
`small`. It is deliberately a **clean, untagged** pointer in the pointer cases: the discriminant lives in
`word1`'s top byte, never in the pointer word, so the moving collector relocates `word0` with no masking and
the hot buffer-deref path takes no extra op. (Swift tags its pointer word because its second word is an
ObjC-interop `BridgeObject`; Nomu has no bridging, so the pointer stays clean, and the cold count read pays
the one mask instead.)

The 16-byte size fits two registers (the SysV cliff), so a `String` passes and returns without spilling to
memory — the reason to pay for bit-stealing over a wider disjoint-slot layout.

**A language `enum` was rejected** for this type: it lowers to `{ i64 tag, [P x i64] payload }` (a whole
extra tag word → 24 bytes, no bit-stealing), and strings underpin everything, so the representation is
hand-tuned.

**Tag read** — the per-access dispatch — is the top nibble of `word1`: `word1 >> 60` in registers (a 4-bit
discriminant, Swift-style), `small = 0` (so a zeroed value is the empty string), `immortal = 1`, `heap = 2`.
Byte 15's low nibble holds the inline count (0–15) in `small`; in `heap`/`immortal` that nibble plus spare
bits of the 56-bit count word (bytes 8–14) are a flag region (isASCII, future Unicode-fast flags). A
`fastUTF8` / `isForeign` flag is unnecessary — Nomu strings are always native contiguous UTF-8.

**That `word0` can carry a conditional managed pointer at all** rests on
[176 shaped GC roots](176-shaped-gc-roots.md): a moving collector keyed on `addrspace(1)` typing cannot
express "a pointer only when the tag says so". 176 gives value-conditional scanning (relocate `word0` only in
the `heap` case — `immortal` is skipped as non-moving, `small` holds bytes) plus the relocation takeover so
the `heap` buffer still moves and compacts. `word0` is a bare `i64` from the start — the end-state layout —
so **121.1 depends on 176**, not just the `small` case. The shape descriptor (`managed offset 0 iff
tag == heap`) is already exercised at 121.1 by the `heap`-vs-`immortal` split: relocate the `heap` buffer,
skip the permanent `immortal` one. `small` (121.2, done) added no GC work — it is a tag value the descriptor
already excludes, so it was pure stdlib SSO byte code on the same representation. No interim `addrspace(1)`
typing, no retype. (The alternative — a reduced-SSO interim where `word0` is typed `addrspace(1)` and retyped
when SSO landed — was rejected as throwaway string work.)

## The `heap` byte buffer

A [180 managed tail-allocated buffer](180-managed-buffer.md) — the shared single-object
`{ header, cap, tail elements }` primitive, here with `UInt8` elements. It is what `StringBase.allocHeap`
returns and a `heap` `word0` points straight at: one GC-managed, relocatable, leaf object, bytes reached in
one indirection (no handle hop), with header room for the UTF-8 invariant and a cached scalar count. 121 does
not define a bespoke storage type — the heap buffer is an instance of the 180 facility, which also backs
`Array` and a future `Dictionary` (the reason it is broken out rather than hand-rolled here).

**It is a GC leaf** — only bytes and scalars, no managed pointers, so its descriptor is `nptr = 0`. The
collector relocates and marks the buffer but never recurses into it. This is what collapses the `heap`-case
shaped-root work to "relocate `word0`, mark the buffer" with no child scan (176.2).

## Value semantics & copy-on-write

No reference count is available (Immix is tracing/moving; RC is the [127 LXR](127-lxr-collector.md)
endgame), and Nomu exposes no copy/drop hooks, so a stdlib-level manual refcount is impossible. The
Nomu-idiomatic answer follows the **core hypothesis**: `String` is written naively ("copy the buffer on
mutation"), and the **compiler elides the copy where it proves the buffer uniquely owned** — the uniqueness
analysis of [123 copy-on-write](123-copy-on-write.md). Interim, before that inference is strong:

- **Pessimistic copy** on mutation (correct, a little slower), and
- a **`StringBuilder`** for the hot "build a string up" path — owns its buffer, appends in place, never
  shared, so the common parser-output case avoids COW entirely.

## API surface & index model

- **Byte layer (121):** `count` (bytes) ✓, `isEmpty` ✓, `byte(at:) -> UInt8` ✓, `==`/`<` (as `eq`/`lt`) ✓,
  `+`/concatenation (`concat`) ✓ — built; this is the complete byte layer. Relocated: `from`/`to Array<UInt8>`
  → [120 stdlib](120-stdlib-core.md); slicing (a span) → [185 Substring](185-substring.md); `withBytes` →
  [152](152-first-class-functions.md); hashing → a future `Dictionary`/hashing task.
- **Scalar / grapheme views + normalization** → [184 String Unicode views](184-string-unicode-views.md):
  UTF-8 decode, scalar iteration with an opaque scalar index (variable-width access never mistaken for O(1)),
  cluster iteration, and the normalization top layer.

## Compiler coupling (held to two; see *Type layering*)

- **Literals:** `"…"` lowers through a *known* initializer — emit the UTF-8 bytes as a static global, call
  `String.fromStaticUTF8(_ ptr: RawPtr, _ count: Int)` (which wraps `StringBase.fromStaticUTF8`). The compiler
  needs the one Nomu symbol, not the layout. Replaces the builtin literal path.
- **`print`:** the string path reads `base.bytePointer()` / `base.count` into the existing `%.*s`.
- **Retiring the builtin:** `Type.string`, `strTy`, and the sema literal typing all redirect to the named
  Nomu `String` struct (121.1.5).

**No operators or subscripts yet.** Until the language gains operator/subscript surface, comparison and
concatenation are ordinary `String` methods in Nomu (`eq`, `lt`, `concat`); when operators land they are
defined on `String`, in Nomu, with no new compiler coupling. (`interfaces.md §8` tracks operators-as-
interface-requirements.)

## Concurrency

An immutable `String` shared across fibers is safe and rides the existing `shared` inference
(concurrency.md §5). A mutable `StringBuilder` is fiber-local.

## Prerequisite — [176 shaped GC roots](176-shaped-gc-roots.md)

The governing dependency for the bit-stealing `small` case, and **broader than String**: a value whose
managed-ness is per-value and dynamic — `String`'s `word0`, and sum types with a reference payload
(`Option<SomeClass>`, `Result<Buffer, E>`) — cannot be rooted by the `addrspace(1)`-keyed statepoint
model. [176](176-shaped-gc-roots.md) gives the collector a shape it reads to scan `word0` only in the
pointer cases (value-conditional scanning) and to relocate the `heap` buffer itself (the relocation
takeover). It unblocks this `String` and the same mechanism clears [148 §148.1](148-ssair-optimizer-tier.md)'s
addrspace-across-calls wall for stack promotion. The feature is a GC/codegen task, so it lives in 176; 121
builds on it.

## Phases

The GC substrate ([176](176-shaped-gc-roots.md)) is **done** — the `kind 2` shape, shaped-root homing, and
heap-buffer relocation are built and validated on both collectors (a `heap` `String` grown by `concat`
survives forced/evac collections). An interim surface also exists in codegen/C — `concat` produces a `heap`
buffer, and `count`/`isEmpty`/`byte(at:)`/`eq`/`lt` are C-leaf `__string_*` ops on the bare value. The
remaining 121.1 work restructures that into the settled **`StringBase` (internal primitive, four ops) +
`String` (Nomu wrapper)** layering and retires the builtin typing.

- **121.1 — `immortal` + `heap` String (the milestone).** Enough to hand-write the
  [163](163-manifest-yaml.md) parser. Sub-phases:
  - **121.1.1 — `StringBase` primitive + the wrapper rule.** Name `StringBase` as the internal compiler
    primitive carrying the 16-byte shaped value and the four ops (`fromStaticUTF8`, `allocHeap`, `count`,
    `bytePointer`); re-key the `kind 2` descriptor (`stringShapeId`) and the shaped-root homing from the
    synthetic builtin to it; add the *single-field-wrapper-is-shaped* rule so `String` inherits the shape.
    **In progress:**
    - *Rename (done + green).* The internal Type case `.string` is now `.stringBase` across the compiler
      (frontend/sema, midend, llvmgen); the shaped machinery (`stringShapeId`, `isShapedType`,
      `transitivelyContainsShaped`) keys on it. The source name `String` still resolves to `.stringBase` and
      displays as `"String"` through the interim; the surface name re-points to the Nomu struct at 121.1.5.
      Full suite 133/133.
    - *Wrapper rule — built + unit-tested + activated (done + green).* `isShapedType` gained a
      single-field-shaped-wrapper case and a `computeShapedStructs` fixpoint (a struct with exactly one stored
      field that is shaped is itself shaped), threaded through `computeShapedLiveness`; unit-tested in
      `ShapedLivenessTests`. **Activated** in the egress and verifier: the egress collapses a shaped wrapper's
      LLVM type to its field's (`structType` → `strTy`, not `{ strTy }`), lowers `makeStruct`/`extractField`
      on it as identity, keys `shapeOrdinal` to the inner ordinal (String = 0), and tracks/homes a wrapper
      value as a two-register shaped SSA value; `verifySSAIR` routes a wrapper through the shaped-root check.
      The collapse is ABI-identical, so the existing single-`String`-field structs (`Circle`, `Square`,
      `Person`) move from the aggregate frame-slot path to the shaped-SSA path with the full suite green
      (133/133), including the interface/`any`-boxing fixtures and every String-GC `-evac` leg.
    - *Nomu `struct String` — done + green.* `struct String { let base: StringBase }` declared in core.nomu;
      the Sema resolver repoints `String` to the struct and names `StringBase` → `.stringBase` for the one
      field. A literal lowers to an `immortal` `StringBase` wrapped in the struct (`wrapString`); the byte-layer
      surface (`count`/`isEmpty`/`hash` properties, `eq`/`lt`/`byte(at:)` methods, `print`, `concat`,
      `readLine`) accepts the struct and unwraps `.base` (an `asStringBase` adapter) to reach the existing
      C-leaf `__string_*` ops — the unwrap lowers to identity because `String` and `StringBase` share `strTy`,
      so no codegen op changed. Confirmed end-to-end: `print`, `concat`, `count`, `eq`, and `String` as a
      struct/class field (suite 133/133, including every interface and String-GC `-evac` leg).
    - *Byte-layer read surface → Nomu (121.1.4).* `StringBase.bytePointer() -> RawPtr` is surfaced as the
      first of the four ops (a C-leaf keyed on the primitive, `__string_bytepointer_rawptr`; `rawptr` added to
      the builtin type parser + `cType`). Over `bytePointer` + `count` + `RawPtr.load`, the read surface is now
      Nomu: `eq`/`lt` are **methods** and `count`/`isEmpty` are **computed properties** on `String`
      (core.nomu). The string builtin block + member gates serve only a bare `StringBase` (`self.base.count`),
      so a surface `String` resolves through struct/computed-property dispatch. Suite 133/133 (`string-surface`
      exercises all four plus the wrong-result guards). The now-dead `__string_eq`/`__string_lt` C leaves are
      removed with the rest of the interim (121.1.5).
    - *`hash` removed.* The `__string_hash_int` builtin (property `s.hash`) is gone — the gate, the `cLeaf`
      entry, and the C function (+ its FNV constants). Hashing is user/library code, not a `String` builtin;
      its home is a future hashing/`Dictionary` task. The GC oracles that used `.hash` to read the buffer back
      after a collection now fold the bytes with a local `strsum` helper (`sum of byte(at:)`), which reads
      every byte just the same; their asserted values were recomputed (e.g. `pair-string-gc` → `2246000`,
      `option-string-gc` → `2232000`, `gc_string` → `540180000`, module-generic-string → `4147`) and the
      `tests/expected/*.txt` files updated. Suite 133/133. (`examples/benchmarks/hashmap.nomu` brings its own
      `hash()` over a custom struct, so it was unaffected — and demonstrates UInt64 xor + wrapping-multiply
      exist in Nomu.)
    - *`byte(at:)` → Nomu, unchecked — done + green.* `byte(at:)` is a Nomu method on `String` (core.nomu)
      over `self.base.bytePointer()` + `RawPtr.load`, an unchecked raw load like `RawPtr.load` itself: an
      out-of-range offset reads invalid memory rather than trapping. The `__string_byteat_uint8_int` C leaf
      (and its `rt_bounds_trap` call) is removed, and the NOIRGen `byte` interception with it, so `s.byte(at:)`
      resolves through ordinary struct-method dispatch (the `at` label is ignored by sema today, as for `eq`'s
      `other`). The checked form — a `precondition` primitive plus analysis-based removal or forced omission —
      is [183](183-precondition-bounds-checks.md); until it lands the stdlib/parser callers that drive the
      offset own the check. Suite 133/133.
    - *`concat` → Nomu + `allocHeap` (121.1.3 + .1.4 producer) — done + green.* `StringBase.allocHeap(count)`
      is surfaced as a static producer op (`__stringAllocHeap`): a `heap` StringBase backed by a managed
      tail-allocated byte buffer (type-id + cap + bytes-at-16, the `ManagedBuffer<EmptyHeader, UInt8>` layout),
      through the rooted `rtAllocManaged` seam. `concat` is now a **Nomu function** (core.nomu) over
      `allocHeap` + two gc-leaf `RawPtr.copyBytes` from the inputs' `bytePointer()`s — the builtin proto and
      the codegen `concat`/`emitConcat` dispatch are retired. GC-safe: `a`/`b` ride the shaped-root path across
      the single `allocHeap` safepoint, the copies run with no safepoint between alloc and fill. All String-GC
      oracles + evac legs green (133/133).
    - *Perf — investigated, at parity (no action needed).* `gc-string`'s wall-time rose (~12s → ~34s across its
      carrier×iteration runs), but benchmarking attributes it correctly: the byte-layer ops are already fast
      un-inlined (byte scan ~125M/s, `eq` ~1.4B byte-compares/s) and `-O` (the LLVM O2 inliner) does not move
      them, so it is not call-overhead. The rise is the `concat` representation change — the old path made
      **immortal** off-heap buffers (the GC ignores them), the new `concat` makes correct **heap** buffers
      (managed, relocated every collection), which is real, intended GC work under gc-string's 24M-box pressure
      (what `gc-string-relocate` tests) and `-O`-insensitive (~1.1s → ~1.0s per run). "Parity with the builtin"
      there would mean reverting to leaking immortal buffers, which 121 deliberately abandoned. The general
      capability for a fast cross-module stdlib **without LTO** (if a cross-module hot path ever measures a gap)
      is [182 cross-module inlining](182-cross-module-inlining.md), not a per-op egress inline.
    - *Dead C interim removed (121.1.5) — done + green.* With `eq`/`lt`/`byte(at:)`/`isEmpty` all Nomu, their
      C leaves and the old codegen concat path are gone: `__string_eq_bool_string`, `__string_lt_bool_string`,
      `__string_isempty_bool`, `__string_byteat_uint8_int` (the C functions, the `cLeaf` entries, and the
      NOIRGen `isEmpty` gate); `emitConcat` (the dead egress concat) and its `rt_str_snapshot` / `rt_str_fill`
      runtime helpers (C defs, `runtime.h` decls, the `gcLeafRuntimeFns` entries). The surviving `StringBase`
      C primitives are `__string_count_int` (via `self.base.count`) and `__string_bytepointer_rawptr` (via
      `self.base.bytePointer()`), plus `rt_str_lit` for literals. Suite 133/133.
    - *Literals → codegen `fromStaticUTF8` (121.1.2) + `String` off the C floor — done + green.* `String` has
      no C floor left. `lowerStringLit` builds the `immortal` `StringBase` directly in codegen (word0 = the
      static UTF-8 global's address, word1 = `(immortal tag << 60) | count`, a constant) — `rt_str_lit` the C
      function is removed (its two `rt_read_line` empty-string uses switched to the `nomu_str_make` inline
      helper). The two read ops moved off C to codegen-native too: `count` and `bytePointer()` lower through
      `SSAIRToLLVM.strLen` / `strPtr` (the same word-extraction `print` uses, now shared), so
      `__string_count_int` / `__string_bytepointer_rawptr` are gone as C leaves and the `cLeaf` registry is
      empty. The dead `nomu_str_len` / `nomu_str_ptr` / `nomu_str_tag` inline helpers are removed;
      `nomu_str_make` remains for `rt_read_line` (privileged I/O). So all four `StringBase` ops are codegen
      (`fromStaticUTF8`, `allocHeap`, `count`, `bytePointer`) and the surface is Nomu — the design's "the magic
      may be codegen" taken to "codegen, not C." Suite 133/133; `gc_string` evac → `540180000`.
    - *`allocHeap` on the shared `ManagedBuffer` path (121.1.3) — done + green.* `__stringAllocHeap` and
      `__managedBufferCreate` both tail-alloc through one shared `emitManagedBufferAlloc(header:element:
      capacity:)` (size `16 + headerSize + cap*stride`, type-id header at 0, cap at 8); `allocHeap` then wraps
      the buffer into the `heap` StringBase value. The bespoke `stringStorageTypeId` helper + `stringStorageMapId`
      cache and the vestigial `__nomu_stringstorage_typeid` global are removed — the heap buffer's type-id is
      the shared `managedBufferTypeId(EmptyHeader, UInt8)`. A defensive module-start registration of that
      descriptor remains (a module that only *relocates* a received heap String, with no `allocHeap` site, still
      emits the weak-ODR descriptor into its own section; the `module_generic_string` cross-module leg exercises
      this). Suite 133/133. The bounds-checked `byte(at:)` is [183](183-precondition-bounds-checks.md).
    - *121.1 complete.* The immortal + heap String milestone is done: the surface is Nomu, all four `StringBase`
      ops are codegen, `String` is off the C floor, and the heap buffer rides the shared `ManagedBuffer`
      descriptor. Next is 121.2 (`small`/SSO) — see the phase-order note below.
    - *Deferred — `StringBase` is nameable anywhere today.* The Sema resolver makes `StringBase` resolvable in
      any file, not just the stdlib, so user code can currently name the internal primitive. The design keeps
      it stdlib-internal; enforcing that waits until the prelude/core becomes a real module (or modules) with a
      visibility boundary, at which point `StringBase` is an unexported stdlib name. Tracked here until that
      module work lands.
  - **121.1.2 — literal lowering → `immortal`.** `"…"` emits a static UTF-8 global + `String.fromStaticUTF8`
    (→ `StringBase.fromStaticUTF8`, tag `immortal`), replacing `rt_str_lit`.
  - **121.1.3 — the `heap` path.** *(Mechanism validated on the ad-hoc kind-1 buffer; final form rides
    [180](180-managed-buffer.md), now done.)* `allocHeap` + the managed byte buffer + a `heap` value holding a
    movable `word0`, surviving a forced/evac GC via the 176 kind-2 trace/relocate. The buffer is already a 180
    `ManagedBuffer<EmptyHeader, UInt8>` by descriptor (180.4); this phase routes the allocation through the
    `ManagedBuffer` primitive (`StringBase.allocHeap` on `create`) rather than the inline `rtAllocManaged` in
    `EgressBuiltins` concat, retiring the bespoke `stringStorageTypeId` / `__nomu_stringstorage_typeid`
    symbols, and re-keys the header `EmptyHeader` → a `StringHeader` once String wants the isASCII /
    scalar-count cache.
  - **121.1.4 — surface, in Nomu.** `struct String { let base: StringBase }`; migrate the byte layer
    (`count`, `isEmpty`, `byte(at:)`), `eq`/`lt`, and `concat` off the C-leaf interim into Nomu `String`
    methods over the four ops. `print` stays compiler-special. (Slicing → [185 Substring](185-substring.md);
    `StringBuilder` → the value-semantics/mutation effort, [123](123-copy-on-write.md) — not this phase.)
  - **121.1.5 — retire the builtin.** `strTy` / `.string` / sema literal typing resolve `String` to the Nomu
    struct; the `__string_*` C-leaf interim is removed as its methods move to Nomu.
- **121.2 — `small` / SSO — done + green.** The bit-stealing inline case (up to 15 bytes across
  `word0`/`word1`, tag 0). `small` is a tag the kind-2 GC descriptor already excludes (it scans `word0` only
  for `heap`), so no GC/176 work — verified against the descriptor (`tagOff 8, tagShift 60`, one case `heap`).
  Built: (a) tag-aware `strLen`/`strPtr` (`small` count in byte 15's low nibble; `small` byte pointer
  materializes the value to a per-call stack slot — its own, so `concat`'s three `bytePointer`s don't clobber);
  (b) producers — short literals (≤15 B) lower to a compile-time `small` constant (`lowerStringLit`, the Swift
  model), and `concat` builds a `small` result inline via the `StringBase.smallConcat` codegen op (copy both
  sources into one zeroed slot, set byte 15 = count, load once — no mutate-then-reload of an SSA value). The
  small/heap/immortal split is invisible above `StringBase`. Suite 133/133; a direct check confirms
  `concat` → `small` ≤15 B, `heap` ≥16 B, with `eq`/`byte(at:)`/`print` correct for both under nogc and immix.
**121 is complete** — the byte-level `String` milestone (immortal + heap + SSO, the full byte surface, GC-safe
on both collectors) is done and parser-ready. No open phase remains; every follow-on is tracked at its own
home (below). There is no mutation path, so `String` is immutable today and copies safely share the write-once
heap buffer — which is why COW does not yet bite.

**Pulled out of 121** (tracked at their own homes):

- **`Array<UInt8>` interop** — `from`/`to Array<UInt8>` → [120 stdlib](120-stdlib-core.md), built when a real
  consumer (byte-buffer I/O, encoding) lands. No consumer today, and byte reads already go through `byte(at:)`.
- **Slicing** — a slice is a zero-copy span, not a copying op, so it is the `Substring` feature →
  [185 Substring](185-substring.md). Slicing returns a `Substring`; `String(sub)` is the explicit copy. No
  copying-slice stopgap lands in 121 (it would be reworked the moment `Substring` arrives).
- **`withBytes`** — scoped raw-byte access → needs the closure story to bound the pointer's lifetime (a
  `small` value's byte pointer is a transient spill that would dangle) → [152 first-class
  functions](152-first-class-functions.md).
- **Unicode views** — `UnicodeScalarView`, `GraphemeView`, normalization → [184 String Unicode
  views](184-string-unicode-views.md). Interpretation layered on the byte core and storage-agnostic, so it
  need not gate the byte-level type.
- **Mutation-in-place + copy-on-write** — a mutating `StringBuilder` (the hot append path) and compiler-inferred
  COW elision → the general *mutation + COW for value types* effort ([123 copy-on-write](123-copy-on-write.md)).
  `String` is a pure immutable value today with no mutation path, so COW does not yet bite; these land with the
  value-semantics work, not as String-only phases.
- **Bounds-checked `byte(at:)`** → [183 precondition / bounds checks](183-precondition-bounds-checks.md)
  (`byte(at:)` is an unchecked load today).

Prerequisite (separate task): **[176 shaped GC roots](176-shaped-gc-roots.md).**

## Dependencies & triggers

- **Built on:** [176 shaped GC roots](176-shaped-gc-roots.md) — `StringBase`'s `word0` is the shaped
  conditional-managed word; the `kind 2` descriptor, shaped-root homing, and heap-buffer relocation (176.1 +
  176.2) are complete and validated for a bare `String`. **Also needs 176.3** (frame-root placement for value
  aggregates): a `String` as a `struct` field or `enum` payload (`Option<String>`) held by value across a
  moving GC is broken until 176.3 lands — a `struct String { let base: StringBase }` is itself such an
  aggregate, so this blocks 121.1.1. See *Type layering* and Representation.
- **Depends on:** [180 managed tail-allocated buffer](180-managed-buffer.md) — the `heap` byte storage is a
  180 buffer instance (`Element = UInt8`); `StringBase.allocHeap` is built on it. Do-it-right substrate shared
  with `Array`/`Dictionary` rather than a String-only buffer.
- **Rests on:** [125 unsafe raw memory](125-unsafe-raw-memory.md) (the `immortal` `RawPtr` + the
  `StringBuilder` / heap-buffer byte ops) — present and usable from Nomu.
- **Couples with:** [123 copy-on-write](123-copy-on-write.md) (the uniqueness analysis that makes COW
  cheap); [127 LXR](127-lxr-collector.md) (RC would give uniqueness directly); self-hosting
  ([128](128-self-hosting-runtime.md)) — String leaving the C floor.
- **Related (independent):** [179 value-level GC classification](179-value-level-gc-classification.md) —
  the broader "GC residency off `addrspace`" refactor. It does **not** gate this task: the `small` case's
  pointer/non-pointer bit-punning stays [176](176-shaped-gc-roots.md)'s shape-descriptor job under either
  address-space model, because `ni` protects pointers and raw inline bytes cannot live in a non-integral
  pointer. 179 and 121 share the motivation (the `addrspace(1)` biconditional) without depending on each
  other.
- **Unblocks:** [163 manifest/YAML](163-manifest-yaml.md) and any hand-written text processing.

## Refs

deferred.md "Standard library" (String/UTF-8 sub-decision); M4.13 (`String` as C primitive);
[176 shaped GC roots](176-shaped-gc-roots.md) (the value-conditional `word0` enabler);
`LLVMGen` `strTy` + `EgressBuiltins` (the builtin to retire).
