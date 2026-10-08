# String / UTF-8 model

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · stdlib` · **Size:** L ·
**Status:** designed — permanent contract + `StringBase`/`String` layering settled (see *Type layering*);
[176 shaped GC roots](176-shaped-gc-roots.md) is **done** (heap-String relocation validated end-to-end on
both collectors), so the build is unblocked. · **Source:** deferred.md (stdlib track); pulled forward
because a hand-written parser ([163 manifest/YAML](163-manifest-yaml.md)) needs a real `String`.

## Goal

Replace the builtin `String` (a C primitive, `{ i8* data, i64 len }` with immortal/leaking storage) with a
**stdlib `String` written in Nomu**, built to scale: UTF-8, value semantics, small-string optimization,
zero-copy literals, a GC-managed growable buffer, and a layered Unicode API. The builtin is retired.

## Model (decided)

- **UTF-8 storage.** Bytes are the backing; the public low-level unit is the **byte** (`UInt8` at a byte
  offset) — what a parser wants. Unicode scalars and grapheme clusters are **views layered on top**, added
  in later phases, so the parser works on bytes now and the type grows into full Unicode without reshaping
  its core. (Decision: *bytes now, scalar/grapheme views layered* — not opaque-index-only from the start.)
- **Value type** (`struct`) with value semantics; the backing buffer is shared on copy and copied on
  mutation (copy-on-write). Immutability is the default; mutation needs a `var` binding.
- **No separate `Char` primitive.** A grapheme is a `String` (a small one); a Unicode scalar is a
  `UInt32`-carrying value from the scalar view. (Revisit only if ergonomics demand it.)

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
- **`Substring`** — a lightweight span over a `String`'s bytes. **Deferred design.** It is the reason the
  byte-access op lives on `StringBase` as a first-class primitive, so `String` and `Substring` can later
  share a byte-access abstraction (only if that costs no performance).

**The four `StringBase` ops — the whole magic boundary:**

| op | role | caller |
|----|------|--------|
| `StringBase.fromStaticUTF8(_ ptr: RawPtr, _ count: Int) -> StringBase` | the `immortal` case, no alloc | the compiler, through the `String.fromStaticUTF8` initializer it targets for a literal |
| `StringBase.allocHeap(_ count: Int) -> StringBase` | a `heap` value with a fresh zeroed managed buffer (the plan-aware rooted alloc, encapsulated) | stdlib `String` builders — `concat`, later `StringBuilder` / copying slice |
| `base.count -> Int` | byte count, read from `word1` with no dereference | stdlib `String` (`count`/`isEmpty`/`eq`/sizing) and the compiler's `print` |
| `base.bytePointer() -> RawPtr` | the reload-aware, tag-aware byte address | stdlib `String` (`byte(at:)`/`eq`/`lt`/copy sources) and the compiler's `print` |

`small`/SSO adds a `fromInline` constructor later (121.3); deferred. With these, `concat` is ordinary Nomu —
`allocHeap`, then two gc-leaf `memcpy`s from the inputs' `bytePointer()`s — and is GC-safe because
`allocHeap` is the only safepoint (the inputs ride the shaped-root path across it) and the copies run with no
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
  discriminant plus the inline count (0–15). `withBytes` hands out a pointer to offset 0. Zero allocation.
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
skip the permanent `immortal` one. `small` (121.3) adds no GC work — it is a tag value the descriptor already
excludes, so 121.3 is pure stdlib SSO byte code on the same representation. No interim `addrspace(1)` typing,
no retype. (The alternative — a reduced-SSO interim where `word0` is typed `addrspace(1)` and retyped at
121.3 — was rejected as throwaway string work.)

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

- **Byte layer (now):** `count` (bytes), `isEmpty`, `byte(at:) -> UInt8`, slicing to a `String`, `==`,
  `<`, hashing, `+`/concatenation, `withBytes`, from/to `Array<UInt8>`.
- **`UnicodeScalarView` (next):** UTF-8 decode, scalar iteration, opaque scalar index (so variable-width
  access is never mistaken for O(1)).
- **`GraphemeView` + normalization (later):** cluster iteration; the Unicode-correctness top layer.

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
    (`count`, `isEmpty`, `byte(at:)`, slicing), `eq`/`lt`, and `concat` off the C-leaf interim into Nomu
    `String` methods over the four ops; `StringBuilder`. `print` stays compiler-special.
  - **121.1.5 — retire the builtin.** `strTy` / `.string` / sema literal typing resolve `String` to the Nomu
    struct; the `__string_*` C-leaf interim is removed as its methods move to Nomu.
- **121.2 — `UnicodeScalarView`** (UTF-8 decode, scalar iteration, opaque scalar index).
- **121.3 — `small` / SSO** — the bit-stealing inline case (up to 15 bytes across `word0`/`word1`). Pure
  stdlib SSO byte code on the shaped `word0` already built at 121.1 — `small` is a tag value the descriptor
  already excludes, so no new GC/176 work.
- **121.4 — compiler-inferred COW** (the [123](123-copy-on-write.md) uniqueness analysis; pessimistic copy
  until then).
- **121.5 — `GraphemeView` + normalization.**

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
