# C-Backed Standard-Library Types

**Status:** working draft. The home for standard-library types whose implementation currently lives in
C (the runtime floor) rather than in Nomu. These are the pieces the language needs before it can carry
its own weight — strings, collections, extra numeric primitives — built in C now and migrated into a
Nomu-written stdlib later, as the buffer/primitive substrate to express them appears. Status tags:
**Decided**, **Deferred**, **Open**.

**API scope:** no concrete syntax or keyword here is committed. `[…]` / `a[i]` array spellings, `.count`
/ `.append`, and the numeric type names are illustrative until agreed. What's pinned is the *layout and
runtime contract*.

**Siblings:** the value/reference split and GC category semantics live in `memory-model.md`; the moving
collector and its object model live in `m6-spec.md` (the size/scan tables these types plug into are
§6.2.4 + the Slice-4 array extension); the C runtime floor's origin is the M4.13 split
(`compiler.md`). Codegen lives in `src/llvmgen/Lowering.swift`; the runtime in `src/runtime/`
(`runtime.c`, `core.c`, `runtime.h`); the GC binding in `src/gcbinding/lib.rs`.

---

## 1. The allocation + GC seam

Every heap object these types allocate goes through one of two runtime seams, both returning
zero-initialized memory:

- **`rt_alloc(size)`** — the moving GC heap (Immix). The object participates in collection: it is
  traced, relocated, and its managed fields updated. Backed by MMTk's per-carrier mutator.
- **`rt_alloc_immortal(size)`** — non-moving, never-collected space, for buffers a moving collector
  must not relocate (the String interim, §2).

An object placed in the moving heap must be describable to the collector by its **header type-id** (low
32 bits of the 8-byte object header). Codegen emits per-type-id side tables the binding reads
(`m6-spec.md` §6.2.4): the managed-pointer map (`nomu_gc_typemap`), the fixed size
(`nomu_gc_typesize`), and — for variable-size objects — a kind + element stride (`nomu_gc_typekind` /
`nomu_gc_typestride`, §3.2). A C-backed type is GC-correct exactly when its heap objects carry a
stamped type-id whose tables describe their layout. — **Decided.**

---

## 2. String — **Decided (as built); collectable form Deferred**

A `String` value is `{ ptr data (addrspace 0), i64 len }` — two words, passed by value. `data` is an
**unmanaged** raw pointer, so a String value carries no GC reference and never becomes a root.

- **Literals** (`rt_str_lit`, gc-leaf) wrap static rodata — no allocation.
- **`concat` / `readLine`** (`rt_str_concat` in `core.c`, `rt_read_line` in `runtime.c`) allocate their
  buffer through **`rt_alloc_immortal`**: `{ ObjectHeader, bytes… }`, non-moving. Because `data` is an
  untracked `addr0` pointer, a moving collector could not update it — the immortal space keeps the
  buffer fixed so the raw pointer stays valid. These buffers **leak** (never reclaimed).

**Deferred — the collectable form (Q6).** Making `String` a managed `{ header, len, bytes }` box was
implemented and reverted: it turns every struct/enum with a String field into a category-3 value
aggregate (values mixed with a GC pointer), which `RewriteStatepointsForGC` cannot relocate across a
statepoint ("FCA unimplemented"). Full Q6 needs the **D6 category-3 spill seam** first
(`m6-spec.md` §6.2.4 String decision). Until then, strings use the immortal interim above. The
variable-size buffer machinery arrays now have (§3) is the same shape a heap-boxed String buffer will
reuse.

---

## 3. Array&lt;T&gt; — **Decided (as built)**

`Array<T>` is a **reference type**: a managed handle shared on assignment (`var b = a` aliases `a`;
mutation is visible through every reference, like a class). Value semantics with copy-on-write is the
intended end state but needs an ownership/retain layer the language does not have yet, so reference
semantics is the interim. — **Decided (2026-08; value-later Open).**

### 3.1 Layout

Two heap objects, both in the moving GC heap:

- **Handle** — fixed 24 bytes: `{ i64 header, i64 len, p1 bufptr }`. One shared type-id for every
  `Array<T>` (the layout does not vary with `T`); its pointer map is `[16]` (the `bufptr` slot). `len`
  is the live element count. `bufptr` is a managed pointer to the buffer (never null — an empty array
  gets a zero-capacity buffer).
- **Buffer** — variable size: `{ i64 header, i64 cap, elems… }`. Element `i` sits at byte
  `16 + i*stride`, in `T`'s natural representation (a reference element is one pointer; a value
  aggregate is stored inline). Per element type it has its own type-id. `cap` is the allocated element
  count.

Elements between `len` and `cap` are always zero (rt_alloc zeroing; grow copies only the live prefix),
so their managed offsets read null and the collector skips them.

### 3.2 GC object model (the variable-size extension)

The buffer is the first variable-size GC object. Its type-id is registered as **kind = array**
(`nomu_gc_typemap_kind[id] == 1`) with an element **stride** (`nomu_gc_typemap_stride`) and an element
**pointer map** (`nomu_gc_typemap`, the managed offsets *within one element*). The binding
(`gcbinding/lib.rs`) branches on the kind:

- **`get_current_size`** = `16 + cap*stride` (reads `cap` from the object; the whole allocation).
- **`scan_object`** applies the per-element map at each of the `cap` element slots.
- **`copy`** / relocation are size-driven, so they need no array-specific code (the 6.2.4 payoff).

The handle is an ordinary fixed object (kind 0); tracing it follows `bufptr` to the buffer, which is
then sized and scanned as above. Both objects relocate under evacuation; element references inside the
buffer are updated. Validated: `examples/arr_gc.nomu` + `tools/arr-gc.sh` (an `Array<Box>` built by
`append` is byte-identical under NoGC and constant Immix evacuation).

### 3.3 Operations (codegen-lowered)

`[…]`, `a[i]`, `a.count`, `a[i] = x`, and `a.append(x)` desugar in Sema to dedicated IR (`arrayLit`,
`index`) or builtin calls (`__arrayCount` / `__arraySet` / `__arrayAppend`), lowered in
`Lowering.swift`:

- **Literal** allocates the handle + buffer and stores elements.
- **Subscript read/write** emit an unsigned `idx >= len` bounds check; out-of-range calls
  **`rt_bounds_trap`** (prints + `abort`, Swift-style; gc-leaf).
- **`append`** grows in codegen (not C): the new-buffer allocation is a statepoint, so the rewrite pass
  relocates the handle / old buffer / value across it and the current buffer is reloaded from the
  relocated handle afterward. A C helper could not do this — a raw heap pointer cannot survive a moving
  collection. Growth is 4→2×; the copy is a gc-leaf `memcpy` on relocated pointers.

### 3.4 Open / Deferred

- **Value semantics with COW** — the end goal (better reasoning + fewer defensive copies). Blocked on an
  ownership/retain layer under the tracing GC (no release hook to detect uniqueness). — **Open.**
- **Whole-aggregate element by value.** Storing aggregate-with-reference elements is fine, but reading
  a whole such element out by value (`let p = a[i]` where `p` mixes values and refs) recreates the
  category-3 FCA case (§2) and needs the same D6 spill seam. Field-wise access and reference/scalar
  elements are unaffected. — **Deferred.**
- **Generational write barrier.** `append` publishing a new buffer into the handle needs a write barrier
  under GenImmix; Immix (non-generational) needs none. Fills the inert `__nomu_write_barrier` seam at
  M6 6.3. — **Deferred.**

---

## 4. Planned C-backed items — **Open**

Not yet built; listed so the doc is the map when they land.

- **Extra numeric primitives** (`Double`, `Int32`, …). The type model has only `Int` (i64) and `Bool`
  today. These need type-system + codegen work (LLVM `f64`/`i32` arithmetic, conversions, float
  literals in the lexer), not only a C floor; the C part is formatting/print and conversion helpers.
- **Spawn group / structured wait.** `spawn let x = …` exists (single static binding, joined on read /
  scope exit via `spawn_join`). A group waiting on a dynamic number of spawned tasks is a library type
  over the existing fiber-join machinery (`runtime.c` `joiner`) — likely no new grammar.
