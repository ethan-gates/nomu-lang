# Write barrier for stores through a `mutating` receiver

**Avenue:** Risk · **Type/Lifecycle:** `correctness · gc · needs-investigation` · **Size:** S–M ·
**Status:** not reachable today · **Source:** [104](104-fiber-stack-strategy.md).3.6's audit of what points
into a fiber's stack

## The question

Codegen emits the generational write barrier only when a store's base is a heap reference (`storeField` in
`src/llvmgen/LLVMGenRuntime.swift`: `addrspace(1)` base). A `mutating` method receives `self` as a plain
pointer (`addrspace(0)` at codegen; possibly a frame address, tracked since 243). When the struct lives in a
field of a heap object, a store of a reference through `self` would then get no barrier: if the object is
old and the stored reference young, a minor collection that does not see the object as remembered would
miss the edge, and free or move the young object while the old one still points at it.

Unverified: the caller may remember the containing object around the call, or the lowering may store
through the object rather than `self`. To check first, in generated code and with a fixture:

- a class holding a struct field, the object promoted to the mature space, then a `mutating` method on the
  field storing a freshly allocated reference, then a minor collection, then a read through the field.

## If it is real

Options to weigh then: remember the containing object at the call site of a `mutating` method on one of
its fields (the caller knows the base); pass the base alongside `self`; or barrier every reference store
through `self` with the heap-range guard deciding (a stack or global `self` falls outside the heap and is
skipped, as the barrier already does for stack-placed objects).

## Refs

[104](104-fiber-stack-strategy.md).3.6; [243](243-frame-mechanism-feasibility.md) (frame addresses passed
down); `design/internals/memory-model.md` (the barrier).

## Status from 251

The scenario cannot be written today: a mutating call on a class's struct field is rejected ("cannot call mutating
method on an immutable value"), from outside and from a method of the class. If that is allowed later, this applies:
`structAddr` now reports the owning heap object (`addrOwner`), which gives the call site the base to remember. The
plain store, `b.v.s = x`, had the same gap and is fixed (251.10).
