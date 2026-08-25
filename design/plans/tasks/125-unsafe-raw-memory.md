# Unsafe raw memory / raw pointers

**Avenue:** Infra (prereq for Risk self-hosting + Usability stdlib) · **Type/Lifecycle:**
`language-feature · needs-design` (language + backend + memory model) · **Size:** L ·
**Status:** needs-design · **Source:** deferred.md (2026-08-18)

**► Decide-early: design before the stdlib track.** Collections, strings, SIMD, and self-hosting all
rest on it, so settle the unsafe surface before the stdlib work starts. Design-ahead, not build-ahead.

## What

An unsafe layer: raw pointers, untyped memory (alloc/free off-heap or pinned within the GC heap), raw
load/store, pointer arithmetic, and manual layout. The escape hatch below the safe type system that
low-level code needs.

## Minimal scope (decided 2026-08-25)

Build only as much as the stdlib primitives need — a growable raw **byte buffer**: allocate/free
(GC-heap blob or pinned), raw load/store at an offset, `memcpy`/grow, length + capacity, and pointer
arithmetic for indexing. That is enough to back a real UTF-8 `String` ([121](121-string-utf8-model.md))
and a real `Array<T>` ([120](120-stdlib-core.md)); `Set`/`Dict` ride the same buffer (hand-written).
Hold the wider surface (capability/provenance system, SIMD-aligned storage, FFI marshalling) until a
consumer asks for it.

**GC-scannable buffers — the one non-trivial bit.** A buffer whose elements are managed references
(`Array<SomeClass>`, or a `Dict` of managed key/value) must be **traced by the precise collector**: the
GC has to walk the element slots and relocate them on a move. `String` (raw bytes) and `Array<Int>` are
non-scanned blobs and trivial; `Array<reference>` needs the buffer typed so the precise scan covers its
element slots. Getting this right is what makes "real arrays" work, so it is in scope for the minimal
build. Ref: `memory-model.md` §3 (object model / precise scan).

## Why consequential — a named hard prerequisite for

- **[Self-hosting runtime](128-self-hosting-runtime.md)** — the collector + allocator manipulate untyped
  memory.
- **[Stdlib collections + strings](120-stdlib-core.md)** — byte buffers, control-byte arrays
  (swiss-table), the String backing store.
- **[SIMD](126-simd.md) / c-types** — raw aligned storage, FFI marshalling.

It also touches the **GC**: raw pointers into managed memory must be pinned or excluded from the
moving collector's view, and the safe/unsafe boundary is where the GC's precise-root guarantee ends.

## Design axes

The unsafe surface (pointer type spellings — `Unsafe*Pointer`-style, or a capability), whether unsafe
memory is GC-managed / pinned / off-heap, provenance + aliasing rules, and how much the compiler
checks vs trusts.

## Roadmap assessment (three-head)

**Yes.** Architecture (GC boundary + memory model) + perf envelope (the primitive floor).
Consequential because so much rests on it. Design early (per the self-hosting "design early, build
late" note).

## Refs

deferred.md "Unsafe raw memory / raw pointers"; `memory-model.md` §3 (GC object model); `c-types.md`.
