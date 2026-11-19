# Calls into C as stops: the in-C state and carrier handoff

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · compiler · designed`
· **Size:** M · **Status:** not started · **Source:** [236](236-fiber-preemption.md), split out of its phases; done as its phase 236.6

## What

Every call into C takes one path, the stub that runs it on the carrier's stack, with the transition built
into that stub (236's Architecture, "Calls into C"). A collection scans a fiber in C without waiting for it,
and a carrier held by one call is handed off. No call is classified short or blocking. This is the substrate
FFI ([130](130-ffi-c-abi.md)) builds on.

## Goals

236's G2 (bounded time to stop the world, calls into C included) and G4 (a fiber blocked in C gives up its
carrier), and 130's F1 and F2 (a call within about a nanosecond of a raw call; a blocking call at least 5×
cheaper than cgo). 236's performance rules apply.

## Today

- **The stub** (`NOMU_SWITCH`, `src/runtime/embedded/rtasm_arm64.s`) switches to the carrier's stack and saves
  the fiber's SP in a frame record on the carrier's stack, where the collector does not look.
- **Calls into libc are leaf calls,** with no stack map at the call site. A collection waits for them.
- **Blocking syscalls hand off eagerly** to an offload carrier before every call.

## Cost to measure first

For a collection to scan a fiber in C, the call into C must be a stop with a map: a statepoint, which spills
each reference live across the call and reloads it after (243.1 measured that kind of cost at 5–6% on calls).
[177](177-register-resident-gc-roots.md)'s register option, references kept in callee-saved registers and
recorded in the map, removes most of it. Until then, the runtime's own tiny libc calls (`strlen`, the clock)
may stay leaf calls that a collection waits for: a fixed list the runtime owns, apart from user FFI.

## Phases

- **270.1 The in-C record and the stop.** The stub records the fiber's SP and return PC in the fiber record
  before the call and clears them after, and checks the fiber's request word (236.3) on return, parking if
  it is set. The call site into C becomes a statepoint. Measure the spill cost on the compute and I/O
  benchmarks, and decide the leaf list.
- **270.2 Collection without waiting.** A stop-the-world counts a fiber in C as stopped and scans it from the
  in-C record. A fiber returning from C during a collection parks at the stub's check.
- **270.3 Carrier handoff.** Each carrier counts its calls into C. The monitor (236.5) sees a carrier held by
  one call across ticks, past a fixed threshold (Go's is about 20 µs; tuned under
  [258](258-runtime-policy-tuning.md)), and hands its queued work to a spare carrier. The fiber, on return,
  takes a carrier as any ready fiber does.
- **270.4 Blocking syscalls on this path.** Retire the eager offload; a syscall that does not block pays
  nothing.
- **270.5 Verify.** G2 with fibers in long C calls; G4 with a fiber blocked in `read`; the per-call cost
  against a raw call and against cgo on the same machine.

## Dependencies

- **Needs** 236.3 (the request word) and 236.5 (the monitor).
- **236 runs this task as its phase 236.6,** to close G2 and G4.
- **Callbacks from C into Nomu** re-enter while the fiber is marked in C; the record must nest. Left to
  [130](130-ffi-c-abi.md).
- **Calls into C the toolchain compiled** may skip the stack switch where their stack use fits, or inline:
  130's F8, later.

## Refs

`src/runtime/embedded/rtasm_arm64.s` (`NOMU_SWITCH`, `NOMU_LIBC`); `LLVMGen.libcViaCarrier`;
[104](104-fiber-stack-strategy.md) ("Calls into libc"); `runtime.md` §6 (present-as-parked syscalls).
