# String / UTF-8 model

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · stdlib` · **Size:** L ·
**Status:** designed — permanent contract settled; ready to build (the bit-stealing `small`/SSO case is
gated on [176 shaped GC roots](176-shaped-gc-roots.md)) · **Source:** deferred.md (stdlib track); pulled
forward because a hand-written parser ([163 manifest/YAML](163-manifest-yaml.md)) needs a real `String`.

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

## Representation

A **hand-rolled 16-byte bit-stealing value** — a two-word `struct` `{ i64 word0, i64 word1 }`, Swift-class,
not a language `enum`. A discriminant in `word0`'s top byte selects three cases that share the 16 bytes:

- **`small`** — SSO. The discriminant + length ride `word0`'s top byte; up to **15 inline UTF-8 bytes**
  span the rest of `word0` and all of `word1`. Zero allocation.
- **`immortal`** — `word1` points to a static UTF-8 buffer, `word0` carries the count. **String literals
  land here**: no alloc, no copy, no free — the one good property the builtin has, kept.
- **`heap`** — `word1` points to a managed growable buffer (`StringStorage`, below), `word0` carries the
  count/flags. GC-tracked and relocated; no manual free.

The 16-byte size fits two registers (the SysV cliff), so a `String` passes and returns without spilling to
memory — the reason to pay for bit-stealing over a wider disjoint-slot layout.

**A language `enum` was rejected** for this type: it lowers to `{ i64 tag, [P x i64] payload }` (a whole
extra tag word → 24 bytes, no bit-stealing), and strings underpin everything, so the representation is
hand-tuned.

**`word1` is value-conditional**, which is what gates the SSO case on the GC side. In `heap`/`immortal`
`word1` is a buffer pointer; in `small` it is inline bytes. A moving collector keyed on `addrspace(1)`
typing cannot express "a pointer only when the tag says so", so this rests on
[176 shaped GC roots](176-shaped-gc-roots.md) — value-conditional scanning (trace `word1` only in the
pointer cases) plus the relocation takeover (so the `heap` buffer still moves and compacts). The 121.1
immortal+heap interim, where `word1` is uniformly a managed-or-null buffer pointer, rides the existing
struct-field GC rule and can precede 176; 176 gates the `small` / bit-stealing case (121.3).

## Storage: `StringStorage`

A dedicated GC-managed **`class`** (an ordinary managed buffer the collector scans + relocates), holding
`{ capacity, count, bytes… }` plus room for the UTF-8 invariant
and a cached scalar count. Purpose-built rather than reusing `Array<UInt8>` — it carries String-specific
invariants and avoids the array handle/buffer double indirection.

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

## Compiler coupling (unavoidable; kept minimal)

- **Literals:** `"…"` lowers to the `immortal` case through a *known* initializer — emit the UTF-8 bytes as
  a static global, call `String.fromStaticUTF8(_ ptr: RawPtr, count: Int)`. The compiler needs the
  initializer symbol, not the layout. This replaces the builtin literal path.
- **`print`:** the string path pulls `(ptr, count)` from a `String` (bytes for `immortal`/`heap`, inline
  for `small`) into the existing `%.*s`.
- **`==` / `+` / `<` / interpolation:** operators-as-interface-requirements are deferred (interfaces.md §8),
  so these stay compiler-recognized and dispatch to known stdlib methods until the operator story lands.
- **Retiring the builtin:** `Type.string`, `strTy`, the `rt_str_concat` leak path, and the sema literal
  typing all redirect to the named stdlib type.

## Concurrency

An immutable `String` shared across fibers is safe and rides the existing `shared` inference
(concurrency.md §5). A mutable `StringBuilder` is fiber-local.

## Prerequisite — [176 shaped GC roots](176-shaped-gc-roots.md)

The governing dependency for the bit-stealing `small` case, and **broader than String**: a value whose
managed-ness is per-value and dynamic — `String`'s `word1`, and sum types with a reference payload
(`Option<SomeClass>`, `Result<Buffer, E>`) — cannot be rooted by the `addrspace(1)`-keyed statepoint
model. [176](176-shaped-gc-roots.md) gives the collector a shape it reads to scan `word1` only in the
pointer cases (value-conditional scanning) and to relocate the `heap` buffer itself (the relocation
takeover). It unblocks this `String` and the same mechanism clears [148 §148.1](148-ssair-optimizer-tier.md)'s
addrspace-across-calls wall for stack promotion. The feature is a GC/codegen task, so it lives in 176; 121
builds on it.

## Phases

- **121.1 — `immortal` + `heap` String (the milestone).** `StringStorage`, byte storage + byte-offset API,
  literal lowering → `immortal`, `print`/`==`/`+`/concatenation, `StringBuilder`. Retires the builtin
  `String`. Enough to hand-write the [163](163-manifest-yaml.md) parser. (`small` and inferred-COW are
  *additions* to this same representation, not rework.)
- **121.2 — `UnicodeScalarView`** (UTF-8 decode, scalar iteration, opaque scalar index).
- **121.3 — `small` / SSO** — the bit-stealing inline case (up to 15 bytes across `word0`/`word1`), once
  [176](176-shaped-gc-roots.md) is in.
- **121.4 — compiler-inferred COW** (the [123](123-copy-on-write.md) uniqueness analysis; pessimistic copy
  until then).
- **121.5 — `GraphemeView` + normalization.**

Prerequisite (separate task): **[176 shaped GC roots](176-shaped-gc-roots.md).**

## Dependencies & triggers

- **Gated on:** [176 shaped GC roots](176-shaped-gc-roots.md) (the bit-stealing `small` case; above).
- **Rests on:** [125 unsafe raw memory](125-unsafe-raw-memory.md) (the `immortal` `RawPtr` + the
  `StringBuilder`/`StringStorage` byte ops) — present and usable from Nomu.
- **Couples with:** [123 copy-on-write](123-copy-on-write.md) (the uniqueness analysis that makes COW
  cheap); [127 LXR](127-lxr-collector.md) (RC would give uniqueness directly); self-hosting
  ([128](128-self-hosting-runtime.md)) — String leaving the C floor.
- **Unblocks:** [163 manifest/YAML](163-manifest-yaml.md) and any hand-written text processing.

## Refs

deferred.md "Standard library" (String/UTF-8 sub-decision); M4.13 (`String` as C primitive);
[176 shaped GC roots](176-shaped-gc-roots.md) (the value-conditional `word1` enabler);
`LLVMGen` `strTy` + `EgressBuiltins` (the builtin to retire).
