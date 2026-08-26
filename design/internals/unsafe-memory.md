# Unsafe Raw Memory

**Status:** design draft (task 125). The unsafe layer the self-hosted runtime is written in — raw
pointers, untyped off-heap memory, raw load/store, and pointer arithmetic, below the safe type system.
Status tags: **Decided**, **Leaning**, **Deferred**, **Open**.

**API scope.** Two type names are agreed: **`RawPtr`** and **`Ptr<T>`**. The surface is **library types
with no new keywords** — the unsafe-ness rides the type name and its module; grammar is unchanged
(Decided with Ethan). The method spellings in §4 are **Leaning** (illustrative) until pinned against the
allocator's first real use.

**Frame.** The consumer is the self-hosted runtime ([128](../plans/tasks/128-self-hosting-runtime.md)):
the allocator and collector ([150](../plans/tasks/150-selfhosted-gc-ladder.md)) manipulate untyped
memory, so this is the raw floor under the runtime bet, and it ships before collector code. The stdlib
buffer machinery that backs `Array`/`String` is a separate, *safe* substrate
([120](../plans/tasks/120-stdlib-core.md)/[121](../plans/tasks/121-string-utf8-model.md)) tracked
elsewhere.

**Siblings:** the value/reference split and address-space model live in `memory-model.md` (§1, §3); the
allocation/GC boundary and the `addrspace(0)` precedent (`String.data`) in `c-types.md` §1–§2; the
builtin wiring pattern in `builtin.md`; the runtime-subset rules that govern the code *using* these
primitives in task 149; the first client in task 150 (the NoGC rung).

---

## 1. The two types

Both are **value types** (`struct`), copied inline, each holding one machine-word address in
**`addrspace(0)`** (unmanaged). Neither carries a managed (`addrspace(1)`) pointer, so neither becomes a
GC root and neither is scanned or relocated. This matches the existing `String.data` word
(`c-types.md` §2). — **Decided.**

- **`RawPtr`** — an untyped, byte-addressable address (Swift's `UnsafeMutableRawPointer`). LLVM
  `ptr addrspace(0)`. The allocator's currency: raw bytes with no element type.
- **`Ptr<T>`** — a typed pointer to `T` (Swift's `UnsafeMutablePointer<T>`). LLVM: the same
  `ptr addrspace(0)`; `T` supplies the element **stride** (`sizeof(T)`) and the load/store type. A
  compiler-known generic value type, monomorphized per `T` like `Array<T>`; because it is pointer-free
  it needs no witness table and no scan map.

**Shareability.** Both hold only an unmanaged word, so the value/reference rules make them trivially
**shareable** across task boundaries (`memory-model.md` §7) with no special case. Safety of what they
point *at* is the programmer's obligation — the meaning of the unsafe surface.

**FCA composition.** A `RawPtr`/`Ptr<T>` field is pointer-free, so a struct/enum holding one stays a
plain value aggregate; the category-3 "values mixed with a GC pointer" relocation problem
(`c-types.md` §2) is absent. Raw pointers compose into value types freely.

## 2. What makes it unsafe — the compiler stops tracking

On the safe surface the collector knows every managed pointer's location and validity. A raw pointer
drops out of that view: the compiler emits the address as an opaque `addrspace(0)` word and performs no
null check, bounds check, liveness tracking, or provenance analysis. Validity is a precondition the
caller guarantees. This is the escape hatch the low-level runtime needs, and the point below which the
GC's precise-root guarantee ends (`memory-model.md` §3).

## 3. The GC boundary (the hard part)

A raw pointer can address memory of three provenances. The minimal 125 surface admits the first two and
gates the third.

1. **Off-heap / OS memory** — from `RawPtr.alloc` (a `malloc` / `aligned_alloc` / `mmap`-class runtime
   entry). The collector never sees it; the program frees it by hand. **The self-hosted allocator's
   working memory (150) is this case,** which keeps 125 contained. — **Decided (admitted).**
2. **Immortal space** — `rt_alloc_immortal` (`c-types.md` §1), non-moving and never collected, so a raw
   pointer into it stays valid for the process lifetime (and leaks). `String` buffers already live here.
   — **Decided (admitted).**
3. **Interior of the moving heap** — a raw pointer aimed inside a managed (`addrspace(1)`) object. The
   collector may relocate that object and cannot update an `addrspace(0)` word, so the pointer dangles
   after a collection. Admitting this requires a no-collection guarantee over the pointer's lifetime (the
   runtime-subset no-safepoint rule, task 149) or an explicit pin. The minimal floor excludes it; the
   NoGC allocator works over case 1, so the near path needs nothing here. Interior-heap access and
   pinning **co-design with 150** when a rung first needs them. — **Deferred (excluded from the minimal
   surface).**

Unsafe raw pointers are unmanaged memory the collector does not touch; the boundary holds because the
runtime's own memory is off-heap.

## 4. Operations (Leaning — spellings illustrative)

Operations are methods and static (type) functions on the two types. Byte offsets apply at the raw
level, element indices at the typed level.

**`RawPtr`**
- `RawPtr.alloc(bytes: Int, align: Int) -> RawPtr` — raw off-heap block (case 1). Static.
- `p.free()` — release it.
- `p.load(fromByteOffset: Int) -> T` / `p.store(_ v: T, toByteOffset: Int)` — access at a byte offset,
  reinterpreting the bytes as `T`.
- `p.advanced(by: Int) -> RawPtr` — byte arithmetic (GEP over `i8`).
- `p.asPtr() -> Ptr<T>` — reinterpret to a typed pointer.

**`Ptr<T>`**
- `Ptr<T>.alloc(count: Int) -> Ptr<T>` — `count` elements of `T`. Static.
- `p.load(at: Int = 0) -> T` / `p.store(_ v: T, at: Int = 0)` — element access at stride `sizeof(T)`.
- `p.advanced(by: Int) -> Ptr<T>` — element arithmetic (GEP over `T`; `by * stride` bytes).
- `p.asRaw() -> RawPtr` — reinterpret to untyped.

A `RawPtr.null` value and pointer equality are **Leaning** (the allocator's sentinel checks want them).

## 5. Compiler wiring

These are **codegen-native builtins** (`builtin.md`, "Codegen-native"), like `Array` — they lower to
LLVM directly rather than to same-named C calls:

- **load / store** → LLVM `load` / `store` in `addrspace(0)`, at the element type (`Ptr<T>`) or the
  reinterpreted type (`RawPtr.load` as `T`). Typed loads carry `T`'s TBAA; raw loads are conservatively
  may-alias-anything.
- **advanced** → a `getelementptr` (over `i8` for `RawPtr`, over `T` for `Ptr<T>`).
- **alloc / free** → a runtime entry: initially `rt_raw_alloc` / `rt_raw_free` (aligned malloc-class in
  `runtime.c`), later re-pointable at the self-hosted allocator itself. Both touch no managed heap.
- **asPtr / asRaw** → a no-op bitcast (both are one `addrspace(0)` word).

`Ptr<T>` reuses the existing generic monomorphization path (M5): each instantiation is a bare
`addrspace(0)` pointer with `T` fixed, supplying stride and load/store type; no witness table, no scan
map. The lexer and parser need no change — `recv.name(args)` and `Type.name(args)` already parse
(`builtin.md`).

**Safepoint classification.** Raw load / store / advance are gc-leaves (no allocation, no block;
`builtin.md` §4). `alloc` / `free` call the runtime entry and hold no managed pointer across it, so they
need no statepoint for the moving collector; if the underlying entry blocks (mmap / syscall) it is an
ordinary scheduler point, handled like any runtime call.

## 6. Trust model — the compiler trusts

The minimal surface performs no provenance, aliasing, or bounds enforcement on raw access; correctness
is the caller's obligation. Typed `Ptr<T>` access carries `T`'s aliasing information; untyped `RawPtr`
access is treated as may-alias-anything, so a miscompile cannot arise from an over-narrow assumption.
This is the conservative-but-correct baseline; tightening it is future work (§7).

## 7. Held back / deferred

- **Capability / `unsafe { }` region.** A gated region (new grammar) confining raw operations, possibly
  carrying provenance or an effect. More expressive, larger surface, new keywords. The minimal floor
  reaches the runtime without it. — **Deferred** (revisit if the trust model needs teeth).
- **Interior-of-moving-heap raw pointers + pinning.** §3 case 3; co-designs with 150 when a rung needs
  it. — **Deferred.**
- **Memory bind / rebind ceremony** (Swift's `bindMemory`, a typed-vs-raw memory state). The floor uses
  direct reinterpret (`asPtr` / `asRaw`); a stricter typed-memory model is future work. — **Open.**
- **Alignment, volatile, atomic raw access.** Alignment is a parameter on `alloc`; volatile / atomic raw
  ops wait until the collector or FFI needs them. — **Open.**

## 8. Relationship to the runtime tasks

- **149 (runtime-subset).** Complementary: 125 supplies the primitives; 149 constrains the code that uses
  them (no implicit GC alloc, no write barrier, no compiler-inserted safepoint). The interior-heap case
  (§3.3) is where the two meet — a no-safepoint region makes an interior raw pointer valid for its
  extent.
- **150 (GC ladder), rung 1 NoGC.** The first client: `RawPtr.alloc` an OS block, bump-pointer within it
  via `advanced`, `store` / `load` object headers. Rung 1 rests on this surface, which is why 125 leads
  the critical path (`horizon.md`).

## 9. Open questions

- **Method spellings** — the §4 names (`fromByteOffset:` / `at:` / `advanced(by:)`) are Leaning; pin
  against the allocator's first real use.
- **Null / equality surface** — `RawPtr.null`, pointer `==`.
- **Interior-heap pinning** — the pin's shape (a scoped API vs. reliance on 149's no-safepoint regions),
  settled with 150.
- **Raw-access aliasing** — whether untyped `RawPtr` stays may-alias-anything or gains a typed-memory
  model (§7, bind / rebind).
