# Calls into C as stops: the in-C state and carrier handoff

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · compiler · done`
· **Size:** M · **Status:** done — the in-C state, `print`'s write in C, carrier handoff with spare carriers; compiled code's stub path and the per-call cost against cgo go with FFI ([130](130-ffi-c-abi.md)) · **Source:** [236](236-fiber-preemption.md), split out of its phases; done as its phase 236.7

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

## Decisions

- **Managed memory handed to C is copied or never moves.** A fiber in C counts as stopped, so a collection may
  move what it was given. A small payload (a `String`'s bytes for `write`) is copied to memory C owns before the
  call, which costs far less than the call; a large one is in the large-object space, which never moves. Pinning,
  which FFI's zero-copy goals (130's F5, F6) need, is designed with FFI against LXR, where it is cheaper than in
  GenImmix's copying nursery.
- **No variadic calls into C.** A statepoint around a variadic call loses its stack-passed arguments, so
  `printf`, `dprintf` and `snprintf` go: `print` formats numbers itself and calls `write` (the direction 259 takes
  for libc routines).
- **The runtime's own futex waits stay as they are.** A fiber contending for a runtime lock sleeps in
  `__ulock_wait` holding its carrier; the wait is short because a lock holder never stops while holding a
  runtime lock. Parking the fiber instead is [254](254-scheduler-performance.md).6.

- **Compiled code's calls take the one path; the runtime's own calls stay leaves.** Measured (270.1): making
  every call into C a stop costs no time (0–1.5% on loops calling C: compiled code reaches C through prelude and
  runtime functions whose calls are statepoints already) but about 85 KB in every executable (a 315 KB program
  grew to 401 KB: stack maps 38.6 → 112.3 KB, code 176 → 199 KB), nearly all from the runtime's own ~900 call
  sites (`free` 396, the futex calls 214, `write` 93). Runtime code is also written never to stop: it holds raw
  pointers into managed objects no map records, and half-updated structures across its calls. So a call from
  compiled code (user code, the stdlib, FFI) is a stop with the in-C record, unclassified, as decided; the
  runtime marks itself in C only around its own calls that can block on a fiber and where its state is safe to
  stop (`write` for `print`, `read` for stdin), as Go's runtime calls `entersyscall` in its syscall wrappers.

## Built (270.1, 270.2)

- **The in-C state** (`runtime/scheduler.nomu`, "A fiber in C"): `rtEnterC` anchors the fiber at the frame that
  called in, points its context at registers that frame saved (`Runtime.saveContext`, `rtSaveContext` in the asm
  floor, so the walk finds the anchor frame's x19), sets state 7 and its carrier's word rec+232 to 1. The
  coordinator claims such a carrier (`rtClaimInC`: 1 → 4g + 2 for stop-the-world g, a carrier claimed once a
  generation) and counts the claim as its acknowledgement, looking again on every wake; `rtEnterC` wakes it when
  a stop-the-world is under way. The root walk scans state 7 from its anchor; shrinking leaves it alone. `rtExitC`
  takes the word back to 0, or waits out the stop-the-world that claimed it.
- **Its consumer, `print`'s write** (`runtime/io.nomu`): `print` and `putByte` reach the stdout buffer through
  forwarders (`__nomu_out_*`), stops that anchor the caller. The buffer's lock is held only to copy and to queue
  full chunks; whoever holds a second lock, the write lock, writes the queue out in order, in C, waiting for that
  lock in C too. Holding the buffer's lock across the write would deadlock a stop-the-world: a fiber waiting for
  the lock sleeps in a futex, never acknowledges, and the writer, back from C, waits for the stop-the-world.
- **Compiled code's own calls into C** take the stub path with FFI's binding surface
  ([130](130-ffi-c-abi.md)): today compiled code calls C only from codegen's helper stubs, which have no stack
  maps, so nothing reaches the path yet.

Measured: a fiber printing 200 KB into a pipe whose reader waits 2 s blocks in `write`; collections requested
meanwhile took 1,950–1,970 ms at worst before (waiting for it), 1–3 ms now (it is claimed in C). `print_loop`
35.2 → 38.8 ms through the forwarders (277 ms with `printf`). The suite passes.

## Built (270.3–270.5)

- **Carrier handoff, with spare carriers** (Go's handing a P from an M in a syscall to another M): the monitor
  sees a carrier that ran one fiber across a tick while in C, with work waiting anywhere; with a carrier asleep
  it wakes one, else it hands the carrier off (`rtHandOff`, rec+240 = 1): it wakes a parked spare, or starts a new
  carrier. When its fiber leaves it, the handed-off carrier retires (`rtSchedRetire`): its queued work goes to the
  global queue and it parks as a spare (rec+240 = 2), in C as far as a stop-the-world is concerned, so the
  coordinator claims it. Carriers are made only under the scheduler lock with no stop-the-world requested, which
  is raised under the same lock, so a stop-the-world counts (sched+160) only carriers that acknowledge. The
  deadlock check counts parked spares as idle (sched+336). Measured on two carriers: one fiber blocked in
  `print`'s write on a stalled pipe, two fibers computing about 0.5 s each: 423 ms with the handoff, 785 ms with
  `NOMU_PREEMPT=0` (no monitor).
- **270.4** had nothing to retire: the eager syscall offload went with the C runtime, and the runtime's other
  reads and writes on fibers do not block (stdin is read after the poller reports it ready; stderr is the crash
  report).
- **270.5:** G2 with a fiber in a long call into C (collections 1–3 ms beside a write blocked 2 s, from
  1,950 ms), G4 (the handoff above). The per-call cost against a raw call and against cgo is a cost of compiled
  code's stub path, so it is measured with it, in 130.

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

- **Needs** 236.3 (the request word), 236.5 (the monitor) and [271](271-print-without-printf.md) (236.6: `print` through `write`).
- **236 runs this task as its phase 236.7,** to close G2 and G4.
- **Callbacks from C into Nomu** re-enter while the fiber is marked in C; the record must nest. Left to
  [130](130-ffi-c-abi.md).
- **Calls into C the toolchain compiled** may skip the stack switch where their stack use fits, or inline:
  130's F8, later.

## Refs

`src/runtime/embedded/rtasm_arm64.s` (`NOMU_SWITCH`, `NOMU_LIBC`); `LLVMGen.libcViaCarrier`;
[104](104-fiber-stack-strategy.md) ("Calls into libc"); `runtime.md` §6 (present-as-parked syscalls).
