# First-class FFI to the C ABI

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` (runtime + GC + codegen)
· **Size:** L · **Status:** needs-design (substrate partly grounded) · **Source:** deferred.md
(2026-08-18)

## What

Direct, low-overhead interop with the C ABI as a primary feature — call C functions, pass/return
C-compatible types, expose Nomu functions to C, hold C-side callbacks. "First-class" means cheap
calls, layout-compatible structs (`c-types.md`), and an ergonomic binding surface (over today's
hand-written shims).

## Goals

The design is preliminary: it goes far enough to keep [236](236-fiber-preemption.md) (preemption) on a path
FFI can use. FFI is built later. The bar is Rust, Zig and Swift on leaf calls and better than Go everywhere,
unless reaching it costs too much binary size, other runtime performance, or complexity.

**Call cost**
- **F1. A call costs what a raw C call costs,** within about a nanosecond: the switch to the carrier's stack,
  with the transition built into it (236's Architecture; built by [270](270-c-calls-as-stops.md)). Calls into C the toolchain compiled skip the switch
  where their stack use fits, or inline.
- **F2. A call that blocks hands off its carrier** (236's G4) and costs at least 5× less than Go's cgo. It
  takes the same path as F1: the monitor detects the blocked carrier, so no call is declared blocking.
- **F3. A callback from C into Nomu on the same thread** costs tens of ns.
- **F4. A callback from a thread C created** attaches once, cached per thread; later callbacks cost as F3.

**Data at the boundary**
- **F5. C-layout data passes directly:** structs, pointers, arrays, enums, unions, function pointers, variadic
  calls, with no copy where layouts match.
- **F6. Managed objects passed to C stay put:** pinned for the call at near-zero cost; held longer through an
  explicit handle. The compiler checks the rules where Go checks at run time (cgocheck).

**Ergonomics and tooling**
- **F7. Bindings come from C headers,** as in Swift's Clang importer or Zig's `@cImport`. New syntax needs
  agreement.
- **F8. The toolchain builds, cross-compiles and statically links C dependencies** itself, as `zig cc` does.
- **F9. Debuggers, profilers and stack traces work across the boundary.**

**Soundness**
- **F10. FFI keeps the collector correct,** with misuse caught at compile time where possible.

**From [270](270-c-calls-as-stops.md):** the in-C state (`rtEnterC`, `rtExitC`, the coordinator's claim, carrier
handoff with spare carriers) is built; a call into C from compiled code reaches it through the stub that switches
to the carrier's stack, as a stop with the in-C record, which lands with the binding surface, and is measured
against a raw call and cgo then. Callbacks re-enter with the record nested.

**Measured by** a set run against cgo on the same machine: a leaf call, a blocking call, a same-thread
callback, a foreign-thread callback, a struct by value and by pointer, and cross-compiling a program that uses
a real C library (SQLite).

**Non-goals:** C++ interop (classes, templates), Objective-C and Swift interop, making C code safe.

## Performance rules

Shared with [236](236-fiber-preemption.md); the two copies stay identical. Rules for any task that touches
performance, measured against Go first; Swift, Rust and Zig once Go is beaten. Designs are compared against
Go, Swift, C# Native AOT, Java's virtual threads, Rust and Zig.

- **P1. Compute.** Beat Swift and C# Native AOT on value-heavy code, and Swift on reference-heavy code. Polls
  and stack checks cost under 3% on tight loops.
- **P2. Concurrency primitives.** Spawn, switch and channel handoff cost less than Go's.
- **P3. Servers.** Beat Go on throughput and p99 latency in a server that mixes I/O and compute.
- **P4. Collection pauses.** Small and bounded, time to stop all fibers included: at or below Go's, with
  100 µs as the ceiling until measured.
- **P5. Memory.** Fiber stacks start at 2 KiB; the heap stays within 1.1–1.3× the live set.
- **P6. Size.** The runtime under 999 KB, a binary under 9 MB.
- **P7. Predictability.** No hidden cliffs: a loop that keeps its full poll cost, an object that lands on the
  heap. Tooling explains these decisions.

**Non-goals:** compile time (its own discussion), hard real-time latency.

## Why architecturally heavy (moving GC + colorless concurrency)

- **Pinning.** A managed pointer handed to C must stay put while C holds it — direct coupling to the
  moving Immix collector's relocation.
- **Foreign-thread attach.** A C thread calling into Nomu must attach: acquire a mutator context,
  register roots, participate in safepoints (`runtime.md` §5).
- **Safepoint transition.** A fiber inside a C call reaches no safepoint. The stub that switches to the
  carrier's stack marks it as in C, and a collection scans it from the saved stack pointer (236's
  Architecture). A callback re-enters the runtime from inside that state, so the marker nests: entering
  Nomu clears it and saves the C call's state, and returning to C restores it, so a collection during the
  callback sees the Nomu frames on both sides of the C frames.
- **Marshalling + ownership.** C ABI type mapping (structs, `String`, pointers), who owns
  passed/returned memory (malloc heap vs GC heap), copy-vs-borrow at the boundary.

## Perf envelope

The pin/unpin + safepoint-transition cost per call decides hot-path usability. First-class means the
common leaf call approaches a raw C call; keep the boundary thin.

## Trigger / sequencing

A standing "Ongoing" item. The substrate (attach + pinning) rides the runtime; the surface
benefits from [modules](100-modules.md) (binding organization) and matters once real C libraries are
wanted. Settle the pinning + safepoint-transition model before the surface is built. Note:
[stdlib I/O](120-stdlib-core.md) does **not** need this — the privileged C runtime exposes I/O builtins;
FFI enters only under [self-hosting](128-self-hosting-runtime.md) (pure-Nomu I/O calling libc) or for
user bindings.

**C modules (later, low priority).** A user-facing way to designate a module as a C module, built only
from C source files. The language itself should not depend on it: the C floor (`runtime.c`, `core.c`)
moves to Nomu, assembly or LLVM rather than becoming the first C module. Designed with this task's
binding surface.

## Roadmap assessment

**Yes — promote from "Ongoing" to a first-class design question.** All three heads; the moving
collector makes this harder than a non-moving runtime would.

## Refs

deferred.md "First-class FFI to the C ABI"; `c-types.md`; `runtime.md` §5 (attach + pinning), §6
(safepoints); `backend.md`.
