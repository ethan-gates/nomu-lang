# Self-Hosted Scheduler

**Status:** design draft (task 128.1). Bringing the M:N scheduler up in Nomu itself, one mechanism per
rung, each rung diffed against the existing C/pthread scheduler as a correctness oracle. This is the
scheduler half of self-hosting the runtime ([128](../plans/tasks/128-self-hosting-runtime.md)); the GC
half is [150](../plans/tasks/150-selfhosted-gc-ladder.md), climbed the same way. Status tags:
**Decided**, **Leaning**, **Deferred**, **Open**.

**The two framing decisions (agreed with Ethan).**

1. **Full scheduler now.** 128.1 replaces the *entire* C scheduler in Nomu — context switch, run queue,
   carriers, park/unpark, mutex/condvar, mailbox pool, timer heap, I/O poller — before returning to
   GenImmix (150.4). Not a minimal substrate. This is the "retire C" north star taken directly.
2. **Raw syscalls + atomics, no libc floor.** The self-hosted scheduler reaches the OS through raw
   syscalls (thread create, futex-class wait/wake, clock, poller) and LLVM atomic instructions — no
   pthread, no libc mutex/cond, no `ucontext`. This resolves `runtime.md` §4's Open "how far to push
   no-libc" toward the aggressive end. Platform reality is in §3.3 (macOS's raw floor is private
   `libSystem` entry points, not a stable syscall table like Linux).

**Frame.** The scheduler is written in a new low-level primitive surface (atomics + raw syscalls + the
context-switch asm floor), under the 149 subset rules — the scheduler's analog of how the GC is written
over 125 under 149. It runs behind a selectable plan (`NOMU_SCHED=nomu`) with the C scheduler linked as
the differential oracle, exactly the method the GC ladder uses (`NOMU_GC_PLAN=nomu`). Ordering:
`horizon.md` — Immix (150.3, done) → **this** → GenImmix (150.4) → retire MMTk → LXR (127).

**Siblings:** the concurrency *model* this realizes (park/unpark/current, actors, structured concurrency,
cancellation) is `concurrency.md`; the runtime *mechanism* it replaces (scheduler model, wakeup feeders,
cross-thread resume, GC touchpoints, and the as-built C scheduler, §8) is `runtime.md`; the subset rules
it is written under are `runtime-subset.md` (149); the raw-memory primitives it shares with the GC are
`unsafe-memory.md` (125); the GC-side root-scanning pieces that couple to the carrier machinery are
`selfhosted-gc.md` §9 and task 128.3.

---

## 1. The ladder and its method

The C scheduler is a large, tightly-coupled artifact (~1,100 lines in `src/runtime/embedded/runtime.c`:
context switch, run queue, carriers, STW handshake, live-fiber registry, mailbox pool, timer heap, kqueue
poller). Rewriting it in one step multiplies unknowns — the new primitive surface, the asm floor, the
subset discipline, and every scheduler invariant at once. So it comes up one mechanism per rung, mirroring
the NoGC→GenImmix ramp that worked for the GC ladder.

**The method is the differential oracle.** Each rung runs the same fixture two ways — under the new
`NOMU_SCHED=nomu` plan and under the C scheduler — and compares observable behavior (completion, ordering
where defined, counts, liveness). One variable enters per rung with the previous rung (and the C
scheduler) as the oracle, so a regression bisects to the one mechanism just added. This is the same
harness shape as `tools/selfhost-gc.sh`; the self-hosted scheduler slots in as a selector beside the C
one. Concurrent fixtures are compared on *invariants* (all fibers completed, single-drain held, no lost
wakeup), not on a byte-identical fingerprint — a concurrent run is legitimately nondeterministic
(`selfhosted-gc.md` §1 makes the same distinction for the collector).

**One scheduler per process — never co-resident.** A run binds exactly one scheduler at init. The C and
Nomu schedulers are both linked but mutually exclusive; comparison is across two separate runs.

**The terminal deliverable is 128.3.2.** The whole reason the scheduler self-host is interleaved *before*
GenImmix (`horizon.md`) is that GenImmix's stop-the-world over all mutators reads every running carrier's
saved safepoint context, and that context is the self-hosted scheduler's machinery. So the ladder's last
rung is the STW-over-all-mutators integration (128.3.2): each carrier saves a Nomu-readable context at its
safepoint, and the self-hosted stack walk (built at 128.3.1, `selfhosted-gc.md` §9) reads it directly,
retiring the C libunwind crutch. That rung is what unblocks 150.4.

---

## 2. The shared substrate — the new primitive surface

The GC is written over 125's raw-memory primitives. The scheduler needs a *different* floor that does not
exist yet — the scheduler's 125. It has three parts, all subset-legal (149 allowlist), all reached from
Nomu the way the `__raw*`/`__ptr*` intrinsics are:

- **Context-switch asm floor (128.2).** The irreducible per-arch assembly. Three entry points:
  - `rtSwitch(from, to)` — save the current fiber's callee-saved registers + SP + return address into
    `from`, restore `to`'s and jump. arm64: x19–x28, fp(x29), lr(x30), sp, d8–d15. x86-64: rbx, rbp,
    r12–r15, rsp, rip. This is `swapcontext`, hand-written and precise about what it saves (the saved set
    must be exactly what the GC parked-fiber walk expects, `runtime.md` §6).
  - `rtFiberInit(stackTop, entry, arg)` — seed a fresh fiber stack so the first `rtSwitch` into it lands in
    a trampoline with `arg` in place (the `makecontext` analog).
  - **Entry / TLS / stack setup** — the pre-runtime moment: establish the main carrier's thread-pointer
    slot and initial stack before the scheduler loop is live.
- **Atomics.** LLVM atomic instructions exposed as intrinsics (no syscall): `__atomicLoad` / `__atomicStore`
  (with ordering), `__atomicCas`, `__atomicFetchAdd`, `__atomicExchange` (built — all i64 seq-cst), and
  fences (deferred until an ordering weaker than seq-cst is wanted). These back the MT-safe run queue, the
  STW flags, the single-drain word, and the mutex/condvar futex word — `__atomicExchange` is the mutex's
  swap (128.1.4).
- **Raw syscalls.** The OS interface, per-platform (§3.3):
  - **Thread create** — Linux `clone` over an `mmap`'d carrier stack; macOS **`pthread_create`**. The
    macOS choice follows the §3.3 rule: `pthread_create` is the stable libSystem floor, while raw
    `bsdthread_create` hand-rolls a private, version-specific pthread struct + registered trampoline and is
    the Apple-unstable trap even Go abandoned on Darwin. So on macOS the carrier primitive is
    `pthread_create` (with a function-pointer callback into the carrier loop), not `bsdthread_create`.
  - **Futex-class wait/wake** — the primitive under mutex and condvar. Linux `futex(FUTEX_WAIT/WAKE)`;
    macOS `__ulock_wait` / `__ulock_wake`.
  - **Time** — Linux `clock_gettime` (vDSO or syscall); macOS `clock_gettime_nsec_np` / `mach_absolute_time`.
  - **Poller** — Linux `epoll_create/ctl/wait`; macOS `kqueue`/`kevent`. **Built (128.1.7):** macOS
    `RawPtr.kqueue`/`kevent` + `pipe`/`readFd`/`writeFd` as libSystem externs; the epoll path lands with
    the Linux target.
  - **Thread-pointer / TLS** — carrier-local state (`rt_current`). **Built (128.1.6):** on macOS a
    `_Thread_local` word in the embedded floor (`RawPtr.tlsGet`/`tlsSet` → `__sysTlsGet`/`__sysTlsSet`),
    the stable platform TLS; the raw arch-register read (arm64 `TPIDRRO_EL0`, x86-64 `fs`) is the
    Linux/optimization path, deferred with the Linux target (same split as the `svc` `rtSyscall`).

**Whether the primitive surface is its own task number** — the way 125 is separate from 128 for the GC —
is an open bookkeeping choice (§7). For now it is carried as 128.1's early rungs (128.1.1–128.1.2).

**Function-address primitive (Decided with Ethan; built).** The asm floor and `pthread_create` both need a
*bare C-ABI code address of a top-level, non-capturing function* — distinct from a closure value, which is
a heap-boxed `(code, env)` pair with a non-C ABI (and forbidden in subset code). This is exposed as a
runtime-tier primitive: `RawPtr.ofFunc(f)` yields the address of a top-level `fun (_: RawPtr) -> RawPtr`
as a `RawPtr` (a non-capturing function is ABI-identical to a C pointer). Internally it is a NOIR
`funcRef` / SSAIR `funcAddr` node lowering to the callable's symbol. **Deliberately not first-class
functions** — full first-class functions/closures for *user* code are wanted eventually but are a separate
later language step, not built during self-hosting; `ofFunc` claims no user-facing surface and can be
subsumed by that feature later. The consumer intrinsics are `RawPtr` methods too: `ctxSwitchTo` (rtSwitch),
`fiberInit` (rtFiberInit), `threadCreate` / `threadJoin` (pthread_create / pthread_join), and `callEntry`
(an indirect call through a code address with the fiber-entry ABI `i8ptr(i8ptr)`, so the scheduler's Nomu
trampoline can run a fiber's stored user entry — the boundary that lets a subset scheduler run a
non-subset fiber body, since the closure check sees no named non-subset callee).

**Subset discipline stays fixed.** The codegen contract above the scheduler does not move: statepoints,
stack maps, the `__nomu_poll` / `__nomu_write_barrier` seams, the header/object model. Self-hosting moves
the scheduler's *policy* (switch, queue, wake, poll-response, drain) into Nomu; codegen still emits the
poll and barrier sites, and the scheduler fills what they call.

### 2.1 The asm floor — contents and integration (Decided: standalone `.s` files)

The floor is a small, fixed, per-arch artifact — a hand-written context switch, a syscall stub, and a
couple of one-instruction register reads. Everything else in the scheduler is Nomu + LLVM intrinsics.
**Contents (per architecture — arm64, x86-64):**

- **`rtSwitch(from, to)`** — save the callee-saved registers, SP, and return address into `from`, restore
  `to`'s, and jump. arm64: x19–x28, fp(x29), lr(x30), sp, d8–d15 (~40 instructions). x86-64: rbx, rbp,
  r12–r15, rsp, rip (~20). The saved set is the contract the GC parked-fiber walk reads (`runtime.md` §6),
  so it is spelled out here rather than left to the assembler's discretion.
- **`rtFiberInit(stackTop, entry, arg)`** — the stack-seeding is plain memory writes and lives in Nomu; the
  floor provides only the trampoline entry point the first `rtSwitch` into a fresh fiber lands on (it reads
  `arg` from the seeded slot and calls `entry`, then falls into the completion path).
- **`rtSyscall(num, a0…a5)`** — load the syscall number and up to six args into the ABI registers, issue
  `svc #0` (arm64) / `syscall` (x86-64), return the result. **Linux-only (Decided).** Darwin
  intentionally keeps its raw syscall numbers and trap path unstable across releases; `libSystem` is the
  only supported stable ABI (Go abandoned direct syscalls on macOS for the same reason). So on macOS every
  OS entry is reached as a **`libSystem` extern symbol** emitted directly by codegen (`clock_gettime_nsec_np`,
  `__ulock_wait`/`__ulock_wake`, `bsdthread_create`, `kevent`), not through an `svc` stub — see §3.3. The
  `svc` `rtSyscall` stub lands with the Linux build target (§5), where raw syscalls are the stable ABI.
- **`rtTLSGet()`** — read the thread-pointer register (arm64 `TPIDRRO_EL0`, x86-64 `fs`-relative) for
  carrier-local state. One instruction.

**Integration — standalone `.s` files (Decided with Ethan).** The floor lives in its own per-arch assembly
files, assembled by clang and linked into the binary (Go's model), rather than emitted as naked/inline-asm
functions from codegen. Rationale: the floor is a fixed arch-specific artifact that reads best as real
assembly in its own file, and it keeps codegen free of embedded instruction strings. The Nomu side reaches
each entry point as an `extern` symbol the same way it reaches the C runtime seams today; the `.s` files
join the link line beside the emitted object. The alternative (codegen-emitted inline asm, no separate
build step) is recorded as the rejected option.

**Built (arm64 floor + integration).** `src/runtime/embedded/rtasm_arm64.s` carries `rtSwitch(from, to)`
and `rtFiberInit(ctx, stackTop, entry, arg)` + the fresh-fiber trampoline (saved set: x19–x28, fp, lr, sp,
d8–d15 — a 168-byte context buffer, the layout the GC parked-fiber walk will read). The `.s` is embedded
in `nomuc` (`EmbeddedSources.rtAsmArm64`), assembled by `cc` and archived into `libnomuruntime.a` beside
the C floor, so its symbols resolve in every emitted binary. Isolation-tested first, as §6 requires: the
C harness `rt_asm_selftest` seeds a fiber, switches in, the fiber records its argument and switches back,
and the round-trip is verified — reached from Nomu as `RawPtr.asmSelfTest()` (`tools/asmswitch.sh`). x86-64
is deferred (its `.s` is absent; the self-test degrades to a stub off-arm64). `rtTLSGet` and the `svc`
`rtSyscall` (Linux) are not built — unneeded on the macOS path so far.

---

## 3. Rung structure

Each rung is `NOMU_SCHED=nomu`-selectable and diffed against the C scheduler. Rungs are numbered 128.1.N;
128.2 (the asm floor) is a co-requisite consumed from the first rung on; 128.3.2 (STW integration) is the
terminal rung and lives under 128.3 because it is inherited from the GC ladder.

1. **128.1.1 — atomics + raw-syscall substrate (§2).** The primitive surface: atomic intrinsics, and the
   OS entry points for thread create / futex / clock / poller / TLS. Subset-legal, allowlisted in 149's
   closure check. No scheduler yet — this rung is validated by direct-call fixtures (a CAS loop, a futex
   ping-pong between two OS threads, a clock read) diffed against the C equivalents. **Built (the
   codegen-only substrate — complete):** the i64 seq-cst atomics (load/store/cas/fetchAdd, with
   `atomicExchange` added at 128.1.4 for the mutex — `tools/atomics.sh`), the 149
   safepoint-poll suppression the scheduler loop needs (`tools/subset-poll.sh`), the monotonic clock —
   `RawPtr.monotonicNanos()` → libSystem `clock_gettime_nsec_np` (`tools/sysclock.sh`), and the futex —
   `RawPtr.futexWait`/`futexWake` → libSystem `__ulock_wait`/`__ulock_wake` (`tools/futex.sh`, the
   value-check contract validated single-threaded: mismatch returns prompt, a matched wait sleeps in the
   kernel to the timeout). All are pure LLVM instructions or `libSystem` externs (`__sys` allowlist), no
   assembly. **Moved to 128.1.2:** raw thread-create and the two-thread futex sleep→wake ping-pong. A
   second OS thread that runs our code needs the carrier callback + per-thread setup that couples to the
   asm floor, so it lands with 128.1.2 rather than in the codegen-only substrate.
2. **128.1.2 — single-fiber context round-trip + carrier thread-create.** The asm-floor rung. Two
   couplings that the codegen-only substrate could not carry land here:
   - **Fiber context switch (the irreducible asm).** Over the 128.2 floor: `main` seeds a fiber
     (`rtFiberInit`), switches into it (`rtSwitch`), the fiber runs and switches back. No run queue. Oracle:
     the C `swapcontext` round-trip. Proves the saved-register set and stack seeding before any scheduling
     policy rides on them. *(The NoGC-equivalent checkpoint of this ladder.)* **Built:** the arm64 floor
     and both round-trips — the C-harness isolation test (§2.1, `tools/asmswitch.sh`) and the Nomu-driven
     round-trip (`tools/fiberswitch.sh`), where the fiber entry is a Nomu function reached via
     `RawPtr.ofFunc` and main drives the switch through `fiberInit`/`ctxSwitchTo`. *Remaining:* a run queue
     (128.1.3) is what a formal diff against the C `swapcontext` oracle attaches to.
   - **Carrier thread-create + the two-thread futex ping-pong (moved from 128.1.1). Built.**
     `pthread_create` (the stable macOS floor, §2/§3.3) via `RawPtr.threadCreate`/`threadJoin` starts a
     second OS thread running a Nomu `worker` (reached via `RawPtr.ofFunc`); the futex sleep→wake ping-pong
     between two threads closes — a real cross-thread wake, main blocked in `futexWait` until the worker
     wakes it (`tools/pingpong.sh`). The function-pointer callback is the `ofFunc` primitive (§2).
3. **128.1.3 — single-carrier run queue + spawn/park/unpark/join. Built.** A Nomu scheduler loop on one
   carrier, written entirely over the substrate (off-heap fiber handles + the asm context switch +
   `ofFunc`/`callEntry`): an intrusive run queue, `fiberSpawn`, the `fiberMain` completion trampoline,
   `park`, `unpark`, and `joinFiber`. Single-threaded, so the queue needs no atomics yet. The scheduler
   functions are runtime-subset (they compile clean under `--runtime-subset`, so they hold no managed
   alloc / non-subset call / safepoint poll), while fiber bodies run through the indirect `callEntry` and
   need not be. Three scenarios green (`tools/scheduler.sh`): spawn-run-complete (three fibers summing to
   6), a park/unpark handoff (111), and join (42), identical under the moving collector.
   *Simplifications carried forward:* fiber handles/stacks are not freed yet (leak — a completion/free
   pass lands with the live-fiber registry, 128.1.6); park is bare (no permit / lock-coupling — the
   lost-wakeup hardening arrives with the MT lock at 128.1.4, `concurrency.md` §2); a formal byte-diff
   against the C single-carrier scheduler is deferred (the scenarios assert observable outcomes, which
   single-carrier cooperative scheduling makes deterministic, matching §6).
4. **128.1.4 — mutex over futex + MT-safe run queue + lock-handoff park. Built.** A self-hosted `Mutex`
   as a 3-state futex word (0 unlocked / 1 locked / 2 contended — Drepper "mutex1": an uncontended CAS
   fast path, a `__ulock_wait` slow path) is the single scheduler lock; the run queue push/pop all move
   under it, so it is multi-producer/multi-consumer-safe. The **lock-handoff park protocol**
   (`concurrency.md` §2 lock-coupled park, M6 6.4) is encoded across every fiber↔scheduler switch: the
   carrier switches *into* a fiber holding the lock; the fiber releases it only after switch-in
   (`mutexUnlock` at the resume point) and runs lock-free; to suspend it re-acquires the lock and switches
   back to the carrier while holding it, so its context is fully saved before any waker (which must hold
   the same lock to enqueue) can re-queue it. `park`/`parkLocked`, `unpark`/`unparkLocked`, `joinFiber`
   (check+register+park under the lock, closing the join lost-wakeup window), and the `fiberMain`
   completion path are all threaded through it. Added one substrate primitive — `RawPtr.atomicExchange`
   (`__atomicExchange`, LLVM `atomicrmw xchg`, the mutex's swap), covered directly in `tools/atomics.sh`.
   Four scenarios green (`tools/scheduler-lock.sh`, `examples/scheduler_lock.nomu`): spawn/run/complete=6,
   park/unpark=111, join=42, and a **parking-heavy relay** (two fibers bounce a token 1000 rounds each,
   2000 lock-coupled park/unpark cycles) = 2000 — subset-legal and identical under the moving collector,
   watchdogged so a lost wakeup fails loud. Still single-carrier (the lock is uncontended, so the futex
   slow path never fires); 128.1.5 puts a second OS thread on the queue where the lock actually contends
   and the M6 6.4 race can recur.
5. **128.1.5 — multi-carrier + idle sleep + cross-thread wake. Built (the wake-on-push half; the
   cross-thread park half rides 128.1.6).** N carrier OS threads (`threadCreate`, here N = 4) each run
   `schedLoop` over its own off-heap context buffer against the one shared MT-safe queue; a carrier that
   finds the queue empty sleeps in `futexWait` on a **wake-generation word** and is woken when a producer
   bumps that word and `futexWake`s (remote-wake, `runtime.md` §3) — the generation bump closes the
   window between a carrier's unlock and its `futexWait` (no lost wakeup). Shutdown is an atomic
   outstanding-fiber counter: the fiber that drives it to zero raises a stop flag and broadcasts, and every
   idle carrier exits for `main` to join. This is the **first rung where the scheduler lock actually
   contends** — `main` and the carriers all take it, so the mutex slow path (`__ulock_wait`) fires for
   real. A fiber records the carrier that switched into it (fiber offset 232) so it can switch back to the
   right one without TLS. Fixture `examples/scheduler_mc.nomu` (`tools/scheduler-mc.sh`): 4 carriers drain
   100 pre-queued fibers, go idle, then 100 more are pushed from `main` ~50 ms later (each a cross-thread
   wake of a sleeping carrier); every fiber adds 3 to a shared atomic accumulator, so the sum is 600
   regardless of interleaving. NoGC-only and looped 30× (raw carriers are not registered mutators, same
   envelope as the ping-pong; they touch only off-heap memory), each run watchdogged so a lost wake or
   lock imbalance fails loud. **Deferred to after 128.1.6:** a fiber that self-parks (`park()` with no
   args) must identify the running fiber, which needs thread-local `rt_current` (128.1.6); so cross-thread
   PARK/UNPARK of fibers — where the M6 6.4 race fully reproduces — rides the rung after TLS. `park`/
   `unpark` were validated single-carrier at 128.1.4. Work-stealing stays deferred (single shared queue
   first, matching the C scheduler). A parallelism knob (`NOMU_CARRIERS`, already an env knob on the C
   side) is not yet read by the self-hosted fixture, which manages its own carriers; wiring it lands with
   the production carrier pool.
6. **128.1.6 — carrier-local state + live-fiber registry. Built.** Two mechanisms:
   - **`rt_current` in a carrier-local slot.** The running fiber handle moves to a thread-local word so a
     fiber that suspends with no arguments can identify itself — the one thing multi-carrier self-park
     needs that 128.1.5 could not provide. The carrier sets it at switch-in (`RawPtr.tlsSet(fib)`) and the
     lock-coupled hand-off (the park) reads it (`RawPtr.tlsGet()`). On macOS the slot is a
     `_Thread_local` word in the embedded floor (`core.c`, reached via `__sysTlsGet`/`__sysTlsSet`), the
     stable platform TLS (dyld thread-local support), matching §3.3; the one-instruction `rtTLSGet` over
     the arch thread-pointer register (arm64 `TPIDRRO_EL0`) is the Linux/optimization path, deferred with
     the Linux target. The per-carrier scheduler *context* did not need TLS — a fiber records the carrier
     that switched into it (fiber offset 232) and switches back to that one (built at 128.1.5). Isolated
     TLS check: each thread's slot is independent across a `threadCreate`.
   - **The cross-thread park/unpark stress (the M6 6.4 race), deferred from 128.1.5, now closed.** With
     `rt_current`, `examples/scheduler_tls.nomu` (`tools/scheduler-tls.sh`) runs 16 A↔B token-pair rings
     bouncing a token via a **lock-coupled hand-off** while 4 carriers steal them off the shared queue,
     racing to claim a fixed work budget. The hand-off makes the partner runnable *and* parks the caller
     under a single scheduler-lock hold (`concurrency.md` §2 `unlockAndPark`): the partner cannot run — so
     cannot re-queue the caller — until the caller's context is fully saved. Splitting it into a separate
     `unpark` then `park` (lock free between them) is the lost-wakeup bug, and an early cut of this fixture
     did exactly that and hung/crashed on most runs; the single-hold hand-off runs clean 300×. Budget
     claimed exactly once each (atomic accumulator == budget) and terminates under a watchdog; a broken
     lock-handoff corrupts a half-saved context (crash) or loses a wakeup (hang), both loud. NoGC-only
     (raw carriers, same envelope as the ping-pong).
   - **The live-fiber registry** (`runtime.md` §6) is an intrusive doubly-linked list threaded through
     link slots in the fiber, so the scheduler inserts on spawn and removes on completion in O(1) (no
     scan), and a STW walk iterates it to reach every parked fiber's roots. Built + tested in isolation
     (`examples/fiber_registry.nomu`, `tools/fiber-registry.sh`): insert, O(1) remove of a middle/head/
     tail node, and full iteration report the right live set; subset-legal and GC-independent. 128.3.2
     drives the iteration from a real STW over all mutators.
7. **128.1.7 — wakeup feeders. Built (both).** The two layer-2 feeders (`concurrency.md` §2), each a
   dedicated thread that unparks a fiber when its wait resolves, each with the 6.4 handoff spanning the
   feeder and the scheduler.
   - **Timer heap** (`examples/scheduler_timer.nomu`, `tools/scheduler-timer.sh`) — a Nomu min-heap of
     `(deadline, fiber)` guarded by a second lock (the timer lock), and a timer thread that waits on a
     timer-gen futex until the earliest deadline (or a push) and unparks the due fiber. `fiberSleep` reads
     the monotonic clock, pushes its deadline, and parks holding the *scheduler* lock across the push so
     the timer thread's unpark (which takes the scheduler lock) cannot re-queue it mid-save. Lock order is
     scheduler → timer for the register; the timer thread releases the timer lock before reaching for the
     scheduler lock (in unpark), so the two orders cannot deadlock (the C runtime's rule). Four fibers
     sleeping 40/80/120/160 ms wake in deadline order → 1 2 3 4. No new substrate — the monotonic clock and
     futex timeout are from 128.1.1.
   - **I/O poller (kqueue)** (`examples/scheduler_poller.nomu`, `tools/scheduler-poller.sh`) — a poller
     thread blocks in `kevent()` and unparks the fiber stashed in a ready event's udata; `waitReadable`
     registers an fd (`EV_ADD|EV_ONESHOT`, udata = the fiber) and parks holding the scheduler lock across
     the register, while the poller does its `kevent()` wait *without* that lock and takes it only to
     unpark (the poller-edition 6.4 handoff). Shutdown is a self-pipe: `signalStop` writes to a stop pipe
     whose read-end is registered with the kqueue, so the blocked `kevent()` returns and the poller exits.
     Eight fibers parked on their own pipes, main writes each fiber's id, every fiber is woken once and
     reads its byte → sum 36. **New substrate (128.1.7):** `RawPtr.kqueue` / `kevent` / `pipe` / `readFd` /
     `writeFd` — libSystem externs (§3.3), subset-legal (`__sys`). Blocking-syscall offload stays deferred
     (as on the C side). Both fixtures are NoGC-only (raw carriers + feeder threads) and watchdogged.
8. **128.1.8 — actor mailbox + mailbox-fiber pool. Built.** The fire-and-forget message-send model
   (`concurrency.md` §9), self-hosted over the 128.1.6/128.1.7 machinery in
   `examples/scheduler_actor.nomu` (`tools/scheduler-actor.sh`), mirroring the C `rt_actor_send` /
   `rt_mailbox_pool` oracle:
   - **Mailbox** — an MT-safe FIFO of messages (`mb_head`/`mb_tail`) plus a `scheduled` flag and a
     `sched_next` link. **`actorSend`** enqueues a message and returns; on the 0→1 schedule edge it appends
     the mailbox to a **global scheduled-mailbox queue** and dispatches a fiber.
   - **Single-drain invariant** — a mailbox is `scheduled` (queued or draining) at most once, so its
     handlers run serially / non-reentrant / per-sender FIFO without a per-actor lock. A drain that empties
     the mailbox clears the flag under the same scheduler lock a concurrent send takes, so no message is
     lost (a send after the clear re-schedules; one before is seen by the in-flight drain).
   - **Capped mailbox-fiber pool** — reusable fibers (≤ a cap) pull mailboxes off the scheduled queue and
     drain each to completion, parking on a free-list (linked via a fiber `pool_next` slot) when the queue
     is empty; `mailboxDispatch` wakes a free one or creates one up to the cap, else the mailbox waits for
     a busy fiber to free. A mailbox fiber is entered/resumed with the scheduler lock **held** (the loop-top
     invariant, unlike a user fiber's trampoline which releases it after switch-in), drains without the
     lock, and re-takes it.
   - **Drain-to-quiescence** — an `active_drains` count of scheduled mailboxes plus a producer guard: the
     run stays alive while the producer is active or drains are outstanding and stops when both reach zero
     (§9 drain-then-collect), rather than exiting with queued work dropped.
   - Unlike the C runtime — whose drain loop is emitted by codegen to hold the mailbox/message as tracked
     addrspace(1) roots across each handler call — this drain loop is plain Nomu, because the mailboxes and
     messages are off-heap raw memory the collector never moves. (The scheduled-queue head is the GC root
     already read self-hosted at 128.3.1.) Scenario: 8 actors × 50 messages, a pool cap of 4 (< actors, so
     fibers are reused), each handler asserting its seq == the actor's expected counter → handled 400,
     errors 0, clean 250×. **The M6 pthread-mutex actor is retired.** NoGC-only, watchdogged.
9. **128.1.9 — integration: the self-hosted scheduler runs real user programs behind `NOMU_SCHED=nomu`.
   Built.** The rungs above proved each mechanism as a standalone NoGC-only fixture that builds its own raw
   carriers; none was yet the process scheduler for a GC-registered user program. This rung assembles the
   proven machinery into one scheduler and makes it selectable. Scope (agreed with Ethan): **NoGC** — the
   default MMTk plan never collects, so no stop-the-world over the self-hosted carriers is needed yet; that
   is 128.3.2. Three parts, all built:
   - **Consolidate.** The machinery (3-state futex mutex, MT-safe run queue, carriers + idle wake-gen
     sleep, `rt_current` TLS, lock-coupled park, timer heap + timer thread, actor mailbox + capped
     mailbox-fiber pool) is consolidated into `src/stdlib/runtime.nomu` — the runtime-subset prelude
     compiled into every binary beside `rtWalkFrom` — under one canonical `Sched` (256 B) / `Fiber` (288 B)
     layout, as `rtSched*` helpers + C-callable `nomuSched*` entry points. The kqueue poller and the
     live-fiber registry are not consolidated yet (no user surface exercises the poller under NoGC; the
     registry is 128.3.2's to drive) — the `Sched` reserves the registry-head slot for it.
   - **Dispatch, codegen unchanged.** An `rt_sched_plan` global (`runtime.c`), set from `NOMU_SCHED` at
     init, makes `fiber_spawn` / `spawn_join` / `rt_sleep_ms` / `rt_actor_send` / `rt_mailbox_pop` branch
     to the C path (default) or a thin shim into the Nomu entry points (`nomu_fn_nomuSched*`, the codegen
     symbol name for a top-level Nomu function); `main` runs the Nomu bootstrap (carrier pthreads that run
     real `nomu_main` user code and poll) instead of `rt_scheduler_run` when the Nomu plan is selected. The
     actor drain loop is the **codegen-emitted `nomu_actor_drain`** reused as the mailbox-fiber body (via
     `callEntry`), so it holds messages as GC roots correctly when collection turns on — its address is
     passed to the boot; a weak fallback definition keeps the symbol resolvable for actor-less programs
     (codegen's strong definition overrides it when actors are used).
   - **GC coupling is registration only.** Carriers are ordinary pthreads, so user allocation binds their
     MMTk mutator lazily through the existing thread-local path (`rt_gc_alloc`); a real stop-the-world over
     them saving a **Nomu-readable** context is 128.3.2. Under NoGC the STW never fires in a normal run.
   - **Differential harness (`tools/sched-integration.sh`).** Real user programs — `spawn.nomu` and
     `shareability.nomu` (spawn/join, struct capture), `actor.nomu` (actor + sleep + spawn/join),
     `actor_relay.nomu` — run under `NOMU_SCHED=nomu` at 4 carriers and 1 carrier, 25× each, and must match
     the C scheduler's output; watchdogged. Green. All 23 pre-existing drivers stay green (the C path is
     unchanged behind the plan branch). The three user-facing surfaces (spawn/join, the timer `sleep`, and
     actor send) are all exercised on the self-hosted scheduler.
10. **128.3.2 — STW-over-all-mutators + self-hosted root walk. Built.** A real stop-the-world across the
   128.1.9 self-hosted carriers, each stopped mutator's roots recovered by the self-hosted pcsp walk
   (`rtWalkFrom`) with no libunwind. The realization refined the doc's original "save the register set
   rtSwitch spills" framing: `rtWalkFrom` matches a frame by testing the pc against **statepoint** return
   addresses, so a saved `rtSwitch` `lr` (a non-statepoint address inside a runtime-subset park function)
   can't be walked. Instead the anchor is captured at the **user frame**, where the return address is a
   statepoint:
   - **Anchor capture in the C dispatch shims.** `spawn_join` / `rt_sleep_ms` / `__nomu_gc_poll_slow` are
     the immediate callees of the user code that parks or polls, so `__builtin_return_address(0)` is the
     user function's statepoint return address and `__builtin_frame_address(0)+16` its SP (the same
     caller-frame math `rtCollectRoots` uses) — a direct immediate-caller read, no libunwind/CFI. The shim
     stores `(sp, pc)` in the fiber (Fiber+264/+272) before it parks.
   - **Safepoint stop for a running mutator.** Under the Nomu plan `__nomu_gc_poll_slow` captures the anchor
     and calls `nomuSchedSafepoint`, which parks the running fiber at state 4; its carrier acks the STW and
     waits. A carrier idle at the loop top acks directly. The handshake is a request flag + an ack count vs
     the carrier total + a resume-gen futex (`Sched+136..160`), driven by a plain coordinator thread (never
     a fiber, so it never polls). This is the piece 128.1.9 unblocked: the park path is all-Nomu, so no C
     `swapcontext` frame sits between the anchor and the user roots.
   - **The walk.** `nomuSchedWalkParked` iterates the now-maintained live-fiber registry (128.1.6,
     consolidated here) and runs `rtWalkFrom` from each stopped fiber's anchor (state 2 parked or state 4
     safepoint-stopped; idle mailbox fibers carry a null anchor and are skipped). This retires the C
     libunwind crossing (`gcParkedAnchors`) that 128.3.1 left in place for the self-hosted path; the C plan
     keeps libunwind as the differential oracle.
   - **Exercise + oracle (`tools/stw-selfhost.sh`).** A forced STW (`NOMU_STW_SELFHOST`) over two busy-loop
     workers stopped mid-run at a safepoint, and a sleep-parked fiber, both recover exactly `{111, 222}`
     (dead `999` excluded) at 2 and 4 carriers, matching the C libunwind STW (`NOMU_GC_STW_SMOKE`) on the
     same programs. A live MMTk collection driving this STW is 150.4, not this rung. **Open follow-up for
     150.4:** the global scheduled-mailbox queue lives in the Nomu `Sched` rather than the C `rt_sched_head`
     GC root, and moving-GC pointer fix-up over the recovered roots is untouched (NoGC scope).

   This is the rung that lets 150.4 (GenImmix) land on the self-hosted scheduler.

128.1.9 makes the self-hosted scheduler the production path behind `NOMU_SCHED=nomu` (the C scheduler stays
as the differential oracle, the same open question as retiring MMTk, `selfhosted-gc.md` §7). 128.3.2 then
lets 150.4 land on the self-hosted scheduler, and the generational write barrier co-designs with the
now-self-hosted carrier/mutator path.

---

## 3.3 Platform reality — raw syscalls on macOS vs Linux

`runtime.md` §4 notes that "no libc" is realistic on **Linux** (stable raw syscall ABI) but that
**macOS/BSD**'s stable ABI is the platform libc (`libSystem`). The "raw syscalls + atomics" decision is
taken with that understood:

- **Linux** — genuine raw syscalls (`clone`, `futex`, `epoll_*`, `clock_gettime`), the north-star static
  binary. This is where the no-libc payoff is real.
- **macOS (the current dev platform)** — the raw floor is the **private `libSystem` entry points**
  (`bsdthread_create`, `__ulock_wait`/`__ulock_wake`, `kevent`, `clock_gettime_nsec_np`), reached as
  extern symbols emitted directly by codegen. These are the same primitives the platform's own pthread/libc
  are built on; using them directly is "raw" in the sense that we bypass pthread, though it still binds a
  `libSystem` symbol. A syscall-table-only macOS build (an `svc` stub with hardcoded numbers) is **not a
  target** — Apple keeps those numbers unstable on purpose, so `svc` on Darwin is a portability trap, not a
  no-libc win. Atomics are pure LLVM instructions on both platforms, no OS entry point.

So the intrinsic surface (§2) is one Nomu-facing API with two per-platform lowerings: a `libSystem` extern
call on macOS, the `svc` `rtSyscall` stub on Linux — the same shape as the codegen already carries for
other platform splits. **Built:** the first entry, the monotonic clock — `RawPtr.monotonicNanos()` lowers
directly to `clock_gettime_nsec_np(CLOCK_MONOTONIC)`, subset-legal (the `__sys` allowlist prefix), no
C-runtime shim (`tools/sysclock.sh`).

---

## 4. Dependencies and pull-forwards

- **The near-term 149 dependency is safepoint-poll suppression** (built), not the stack marker. The
  scheduler's own loop must not emit a `__nomu_poll` that recursively tries to stop the world; that
  codegen-site guard (`runtime-subset.md` §4) is in place — a subset function's `noSafepoint` property
  makes the backend elide the loop-header poll (`tools/subset-poll.sh`). The bounded-stack marker
  (`nostackgrow`) stays behind [104](../plans/tasks/104-fiber-stack-strategy.md): with fixed 128 KB fiber
  stacks there is no growth check to suppress, so it is inert until stacks grow. No pull-forward needed.
- **Marker surface (Decided, `runtime-subset.md` §3):** the runtime-subset guarantees are the orthogonal
  property set `{noAlloc, noBarrier, noSafepoint, nostackgrow}`; the first three are the runtime-tier
  module default (no marker), and `nostackgrow` is a **bare descriptive keyword on the line before `fun`**,
  contextual and runtime-only (absent from user code). No sigil / attribute grammar.
- **128.2 asm floor** is a co-requisite, consumed from 128.1.2 on.
- **125 (built)** carries in unchanged — the scheduler manipulates raw fiber-stack and handle memory over
  the same `RawPtr` surface the GC uses.

---

## 5. What this ladder excludes (deferred)

- **Work-stealing** — single shared run queue first (as the C scheduler does); per-carrier queues +
  stealing are a later throughput rung (`runtime.md` §1, M4.3c).
- **Contiguous stack growth** — fixed 128 KB fiber stacks first; copy-on-grow rides
  [104](../plans/tasks/104-fiber-stack-strategy.md) and the dynamic spawn group
  ([103](../plans/tasks/103-dynamic-spawn-group.md)), `runtime.md` §1.
- **Blocking-syscall offload** — carriers may block on a syscall first; the offload handoff (`runtime.md`
  §2) is a later rung.
- **Linux poller** — the first self-hosted poller targets the dev platform (kqueue); the epoll path lands
  when Linux is a build target.
- **Foreign-thread attach / FFI** — deferred with FFI (`runtime.md` §5); the context-free resume contract
  (§3 of `runtime.md`) is honored so it "just works" later.

---

## 6. Testing and safety

Floor bugs corrupt silently instead of raising an error, so the harness is built to make corruption loud
and located.

- **Differential oracle (backbone).** Mirroring `tools/selfhost-gc.sh`: each rung adds an `examples/`
  fixture and a `tools/*.sh` driver that runs it under `NOMU_SCHED=nomu` and under the C scheduler and
  compares. Concurrent fixtures assert *invariants* (all fibers completed; per-sender FIFO; single-drain
  held; no lost wakeup) rather than a byte fingerprint. The existing concurrency fixtures (spawn/join,
  sleep, actor send, the 6.4 park-stress) are the seed corpus.
- **Test the asm floor in isolation first.** Before any scheduler rides them: a driver that switches
  between two hand-built contexts and checks `rtSwitch` round-trips, and one that calls `rtSyscall`
  (e.g. `write`) and checks the output. A proven floor bisects later bugs to the logic above it — the
  oracle can't cover the floor (no C equivalent of "did `rtSwitch` save x27").
- **Invariant assertions in debug builds.** Stack canaries / guard pages (catch a `nostackgrow`
  overflow), context poison values, run-queue and single-drain integrity checks — silent corruption
  becomes an immediate named failure.
- **Concurrency last, then stressed.** The rung order proves single-carrier (128.1.3) before multi-carrier
  (128.1.5), so nondeterminism enters in isolation; race bugs are probabilistic, so concurrent fixtures
  loop thousands of iterations (how the 6.4 park race surfaced).
- **Sanitizers.** ASan for memory corruption, TSan for races on the queue and park protocol. TSan cannot
  follow a hand-rolled stack switch, so it covers the logic and is disabled around the asm floor (Go hit
  the same).

**Safety envelope.** This is userspace — the OS isolates it behind the MMU, so the worst outcomes are a
process crash, a hang, or a runaway, all contained (a reboot clears anything stuck; nothing reaches other
processes, the OS, disk, or firmware). Raw syscalls carry no privilege — they do what libc does without
the wrapper. Standard guardrails: run tests under `ulimit` (address space, thread count, CPU seconds) to
bound a runaway, and wrap every driver in a `timeout` so a deadlock fails the test instead of wedging.

---

## 7. Open questions

- **Primitive-surface task number.** Whether the atomics + raw-syscall surface (§2) gets its own task
  number like 125 did for the GC, or stays folded into 128.1.1. Bookkeeping only.
- **macOS raw floor** (§3.3) — **Resolved.** macOS binds the private `libSystem` entry points directly as
  extern symbols (no C-runtime shim, no `svc` stub); the `svc` `rtSyscall` floor is Linux-only and lands
  with the Linux build target. Rationale: Darwin's raw syscall ABI is intentionally unstable, so `svc`
  there buys a portability trap rather than a no-libc win. The no-libc north star is a Linux property.
- **Remote-wake primitive** — eventfd / self-pipe / futex for waking an all-idle carrier set (`runtime.md`
  §3, still Open there); the futex path is the natural fit given the substrate.
- **Keeping the C scheduler as an oracle** after retirement — same shape as the MMTk-retirement question
  (`selfhosted-gc.md` §7).
