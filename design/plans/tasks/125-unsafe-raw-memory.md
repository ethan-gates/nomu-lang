# Unsafe raw memory / raw pointers

**Avenue:** Risk (first prerequisite of the self-hosted runtime) · **Type/Lifecycle:**
`language-feature · design-drafted` (language + backend + memory model) · **Size:** L ·
**Status:** design-drafted — build now · **Source:** deferred.md (2026-08-18)

**► Design:** [`internals/unsafe-memory.md`](../../internals/unsafe-memory.md). Surface pinned with
Ethan: **library types, no new keywords**, named **`RawPtr`** (untyped) and **`Ptr<T>`** (typed). Both
value types holding one `addrspace(0)` word, so they are never GC roots. GC boundary: off-heap and
immortal memory admitted; moving-heap interior gated behind 149's no-safepoint rule / pinning (deferred,
co-designs with 150). Ready to build.

**► Build now — first prerequisite of the self-hosted runtime ([128](128-self-hosting-runtime.md)).**
The collector and allocator manipulate untyped memory, so this is the raw floor the runtime bet stands
on. Design and build it now, ahead of the collector code ([150](150-selfhosted-gc-ladder.md)).

## What

An unsafe layer: raw pointers, untyped memory (alloc/free off-heap or pinned within the GC heap), raw
load/store, pointer arithmetic, and manual layout. The escape hatch below the safe type system that
low-level code needs.

## Scope

The real consumer is the **self-hosted runtime** ([128](128-self-hosting-runtime.md)): the collector and
allocator need raw pointers, untyped memory (alloc/free off-heap or pinned), raw load/store, pointer
arithmetic, and manual layout to implement the very services the safe language rests on.

**Correction to the earlier "byte buffer for String/Array" scope.** A prior pass scoped this to "the
growable byte buffer needed to back real String and Array." That was a mis-bundling: the growable,
GC-scannable buffer machinery already exists inside codegen (`c-types.md` §3 — `Array<T>` is built and
validated; the variable-size GC object model with per-element pointer maps is done, per `arr_gc`).
String/Array being compiler intrinsics rather than extensible Nomu-source types is a real but *separate*
stdlib gap (tracked with [120](120-stdlib-core.md)/[121](121-string-utf8-model.md)), and it wants a
**safe** language-level buffer type, not this unsafe surface. This task is the unsafe raw-memory surface
the runtime is written in.

**GC boundary — the hard part.** Raw pointers into managed memory must be pinned or excluded from the
moving collector's view, and the unsafe surface is where the GC's precise-root guarantee ends. The
self-hosted collector is itself the code that defines that boundary, so this task and the GC ladder
([150](150-selfhosted-gc-ladder.md)) co-design: the unsafe primitives are what the collector is written
in, and the collector is what decides which raw pointers the GC may not touch. Ref: `memory-model.md` §3
(object model / precise scan).

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
