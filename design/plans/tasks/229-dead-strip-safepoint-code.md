# Unused code with safepoints survives dead stripping

**Avenue:** Perf · **Type/Lifecycle:** `link · binary size` · **Size:** M · **Status:** needs-design (low
priority) · **Source:** found in [158](158-gc-packaging.md).5, closed there as 158.7.

## What

`-dead_strip` keeps every function that has a GC safepoint, called or not. Each object's `__llvm_stackmaps`
section reaches the linker as one unit with a relocation to every function holding stack-map records, and
the section stays, so all of those functions stay. `-why_live` shows it: an unused user function with an
allocation loop is kept "from `__LLVM_StackMaps`", while an unused function with no safepoint is stripped.
The cost is binary size in every program (user code, the stdlib and the runtime alike); run time is not
affected.

## Approach to evaluate

Objects reach the linker with no relocations in their stack-map section, so it keeps nothing alive. The
frame-index step (`FrameIndex.swift`, which already reads the link map) then resolves each stack-map
function entry to its symbol through the object's original relocations and the link map, and leaves out the
entries whose function was stripped. To check: that the linker keeps the stack-map data itself when nothing
refers to it (or mark it so); the effect on cached object bytes and `--check-reproducible`; and how much a
typical binary shrinks, measured first to size the work.

## Refs

[195](195-link-time-gc-frame-index.md) (the frame index), `src/driver/sources/FrameIndex.swift`,
`src/driver/sources/Link.swift`.
