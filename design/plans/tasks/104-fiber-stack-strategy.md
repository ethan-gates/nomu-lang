# Fiber stack strategy: growth, overflow, high-fiber-count throughput

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `perf · needs-design`
(runtime + compiler architecture) · **Size:** L · **Status:** direction decided (Go-style copying stacks);
the design of its parts is open; built before any collector is measured · **Source:** deferred.md

**Scheduled before any collector is measured** (the benchmark against Go and Swift on GenImmix, then the
GenImmix–LXR comparison), so the benchmarks run on large, fiber-heavy programs. Today's three stack
problems are fixed together: overflow is silent (no guard page), every fiber commits its whole 128 KiB up
front (`rtSchedFiberNew` takes its stack from `RawPtr.alloc`), and the size is fixed.

## Decision: Go-style stacks, copied on growth

Fibers start with a small stack (Go's is 2 KiB). A function checks on entry that the stack has room for
it; when it does not, the runtime copies the stack to one twice the size, fixes every pointer into it, and
continues. The collector shrinks a stack that is mostly unused.

**Why.** Nomu's goal is highly concurrent code as fast as Go or faster, and the workloads it means are
switch-heavy: actors and messages, fibers parking and resuming constantly, at very high fiber counts. That
asks for the fastest switch and the least memory per fiber together. Copying stacks give both: a switch
saves and restores registers and moves nothing, and a fiber's stack is as small as a few KiB and gives
memory back. The cost is a check on function entry (a load, a compare and a predicted branch; typically a
few percent), which inference can drop on most paths (below).

**Alternatives considered:**

- **Fixed stacks** (today): no checks, but 128 KiB a fiber caps the fiber count and overflows silently.
- **Guard page and lazy commit**: reserve a large range per fiber and let the system commit pages as they
  are touched, with a guard page past the end. No checks and calls into C stay on the fiber's stack, but a
  stack is at least one page (16 KiB on Apple Silicon, against Go's 2 KiB), committed memory comes back
  only through explicit system calls, and every fiber holds an address range (Linux limits the count of
  mappings to 65,530 by default). It loses on fiber density, which the goal turns on.
- **Segmented stacks**: Go's first design, dropped because a call sitting on a segment boundary allocates
  and frees a segment on every call ("hot split").
- **Frames copied out on park (Java's virtual threads, Loom)**: a fiber runs on its carrier's large stack
  with no checks; parking copies its frames into a heap object, and resuming copies the top frames back
  lazily. Parked fibers are the smallest of any scheme, but every switch copies frames, which taxes the
  switch-heavy workloads Nomu targets; and frames come back at another address on every resume, so every
  pointer into a frame (Nomu places non-escaping objects in frames) would need fixing on every resume, or
  frames that can park could hold no such objects. Not planned.
- **Stackless coroutines** (Rust `async`, C++ coroutines): a suspending function becomes a state machine
  holding only its live values. They need suspending functions marked, which Nomu does not allow: its
  concurrency is colorless. An inferred version would be colorless but would have to treat every call
  through an interface or a function value as one that suspends, transforming most of a program.

## Open design

- **The entry check.** It compares the stack pointer, less the frame (or the call tree, below), with the
  fiber's stack limit, and calls into the runtime to grow when short. LLVM computes frame sizes only in its
  code generator, and its split-stack prologue support covers x86 and 32-bit ARM, not arm64: either the
  check is emitted in IR with an estimated frame size, or LLVM's AArch64 prologue lowering is extended.
- **Moving a stack.** Every pointer into the stack is fixed when it moves: frame pointers, and pointers to
  objects Nomu placed in frames, wherever they sit (slots, registers saved in frames). The stack maps must
  describe these, beyond the GC pointers they describe today. Escape analysis must guarantee no pointer into
  a frame lives outside its fiber's stack, as Go's does.
- **The runtime's own code.** Runtime-subset functions hold raw addresses the stack maps do not describe, so
  a stack must not move under them: they run where a stack cannot grow (no checks, a fixed reserve), or on
  the carrier's stack (Go's `systemstack`).
- **Calls into C.** A small stack cannot run C code, which needs a large one: a call into C switches to the
  carrier's stack first, as Go's `cgo` does. The runtime's system calls (`write`, `kevent`) are the first
  such calls.
- **Shrinking.** At collections, a stack using under a quarter of its size is copied to one half the size.
- **The limit.** A maximum stack size per fiber; past it, a fatal error through the runtime's fatal path,
  which [219](219-runtime-fault-handling.md)'s handler reports.

## Dropping the check by inference

A check asks whether there is room *from where the stack pointer is now*, whatever the callers used. So:

- **A bound per call tree.** Inference gives each function `max_stack(f)`: its own frame plus the largest
  bound among its callees. It exists when the whole tree is known: no recursion, no calls through an
  interface or a function value, every callee's bound known (from other modules through their interface
  summaries).
- **One check covers the tree.** When `f` checks for `max_stack(f)` on entry, everything `f` calls has room
  by construction, so its callees skip their checks when called from `f`.
- **Two entries per function.** A function is compiled once and called from many places: a checked entry
  for callers that have not covered it (calls through an interface, unanalyzed code, a fiber's start), an
  unchecked one for callers whose check covered its tree. The bound belongs to the callee; each caller
  chooses the entry from what its own check covered.
- **Limits.** Recursion and dynamic calls keep per-call checks, though bounded trees below them are still
  covered. A tree whose bound is large is not folded into one check, which would grow small stacks for a
  rarely taken deep path; only trees under a threshold of a few KiB are.
- **Precedent.** Go keeps a guard zone of a few hundred bytes at the end of every stack, runs small
  `nosplit` functions with no check, and has its linker verify across the program that each chain of them
  fits in the zone: the same reasoning, for leaf code.

## Work

- **104.1** Baseline: a ping-pong benchmark (two fibers, and two actors) against Go's goroutines and
  channels, with the switch's cost split between the register swap and the scheduler's own work. 104's
  later measurements (the entry check's cost, growth) compare against it.
- Further steps are numbered when the open design above is settled.

## Dependencies & triggers

- **Trigger:** the first collector measurement (above), ahead of the dynamic spawn group
  ([103](103-dynamic-spawn-group.md)), which the earlier plan tied the build to.
- **Reports through:** [219](219-runtime-fault-handling.md)'s fault handler for faults, and the runtime's
  fatal path for a stack past its limit. Growth never involves the fault handler, which prints and dies once
  (`SA_RESETHAND`).
- **Couples with:** [TCO](129-tail-call-optimization.md) (lowers stack depth), GC statepoints and the
  parked-fiber scan (the stack maps a move reuses), escape analysis (pointers into frames), the dynamic
  spawn group.

## Refs

`runtime.md` §6 (safepoints, parked-fiber scan, mutator); [103 dynamic spawn group](103-dynamic-spawn-group.md);
`rtSchedFiberNew` (`src/stdlib/runtime/scheduler.nomu`); [219 runtime fault handling](219-runtime-fault-handling.md).
