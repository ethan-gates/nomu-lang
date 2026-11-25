# Runtime & Scheduler

**Status:** working draft. The home for Nomu's execution substrate — the M:N scheduler, the wakeup feeders, cross-thread mechanics, platform/syscall strategy, and FFI-readiness. Status tags: **Locked**, **Decided**, **Leaning**, **Open**.

**API scope:** this doc is about runtime *mechanism*, below the surface language. Nothing here is user-facing API. The user-facing concurrency *model* and the abstract suspension primitive (`park`/`unpark`/`current` + permit) live in `concurrency.md` (§1, §2); this doc is how the runtime realizes them.

**Runtime is mandatory.** Per `vision.md` → "Library tiers," there is no runtime-less configuration; the GC and this scheduler are the always-present floor.

**One runtime: the Nomu scheduler and collector.** Both are Nomu code (`src/stdlib/runtime/`), including the GC coordinator thread ([158](../plans/tasks/158-gc-packaging.md)); below them is only the asm floor (`rtasm_arm64.s`: context switch and fiber init). The C scheduler and MMTk were retired ([197](../plans/tasks/197-retire-mmtk-and-c-scheduler.md)). §6's MMTk mechanics and §8's C implementation record are history; the mechanisms themselves live in `selfhosted-scheduler.md` and `selfhosted-gc.md`.

---

## Terminology (settled 2026-07-16, not locked)

- **Fiber** — the lightweight, stackful execution context, many multiplexed M:N over OS threads. The scheduler-level unit: you *park*, *switch*, *schedule*, *steal* a fiber; a fiber *has its own stack*.
- **Carrier** — the OS thread a fiber runs on (the N in M:N). "Green thread" is used only in cross-language comparison, not as our own term.
- **Fiber handle** — the runtime-internal reference `park`/`unpark`/`current` operate on. **Not programmer-visible.**
- **Task** — the library type `task f(x)` returns (`concurrency.md` §8), `Task<T>`, a joinable result over a fiber and a one-shot channel. "Task boundary" and "task-local" name the fiber boundary as a concept. There is no programmer-visible `Fiber` type.

The doc set follows this vocabulary (pass done 2026-07-16): **fiber** for the runtime execution context (park / schedule / suspend / wait-lists / run queue), **task** for the joinable library type and the boundary concept (task boundary, task-local). "Green thread" appears only in cross-language comparison. Spellings of any future user-visible type stay deferred.

---

## 1. Scheduler model

- **M:N stackful fibers** — many fibers multiplexed over few OS carrier threads; a fiber has a real stack and can suspend anywhere. — **Locked** (`concurrency.md` §1).
- **Work-stealing** across carriers, with per-carrier run queues, a slot per carrier, and a shared global queue (Go's shape), below. — **Decided (built, tasks 234, 235, 237).**
- **A parallelism knob** (`GOMAXPROCS`-equivalent) caps carrier count. — **Leaning.**
- **Stack growth** — growable **contiguous** stacks (copy-on-grow, Go's post-2014 model) so a fiber starts small and grows by copying to a larger buffer; segmented ("hot split") rejected. A copy relocates the stack, so every interior/frame-relative pointer and saved SP must be found and rewritten — this reuses the precise parked-fiber stack walk the moving GC already emits (statepoint stack maps + §6), extended from *scan* to *relocate*. Infrastructure is in place; **gated on the dynamic spawn group** (tasks `plans/tasks/104-fiber-stack-strategy.md`, `plans/tasks/103-dynamic-spawn-group.md`) so the payoff (massive fan-out shrinking the fixed-128 KiB footprint) is measurable on that workload's own concurrency benchmark the day it lands. — **Decided (contiguous copy-on-grow); scheduled with the dynamic spawn group.**
- **Task-locals** — per-task storage analogous to goroutine-locals / thread-locals. Shape open. — **Open.**

The abstract suspension primitive these rest on — `park`/`unpark(t)`/`current` with permit semantics — is Locked and specified in `concurrency.md` §2; this doc does not restate it.

### 1.1 Run queues, wakes and handoffs — **Decided (built)**

The policy is Go's, measured against Go's workloads in `tools/schedbench.py`, with two additions of Nomu's own: the deferred wake and the direct switch. The code is `runtime/scheduler.nomu`; the measurements are in tasks [234](../plans/tasks/234-scheduler-wake-and-pool.md), [235](../plans/tasks/235-scheduler-run-queues.md) and [237](../plans/tasks/237-handoff-primitives.md).

- **Where a ready fiber waits.** A fiber readied by a running fiber goes in its carrier's **slot** (rec+104), to run next there (Go's `runnext`); a fiber already in the slot moves to the carrier's **local run queue** (256 entries; Go's `runqput`). A readying off any carrier (the timer, the poller) goes on the **global queue**. `NOMU_SLOT=0` turns the slot off.
- **The pick** (`rtSchedFind`): every 61st pick takes the global queue's head first (`NOMU_GLOBAL_CHECK`); otherwise the slot, the local queue, the global queue, then a steal. A fiber from the slot continues the current **run**; any other pick begins one (rec+112). A run is the unit the monitor ages (§6), so a chain of handoffs is aged as one fiber computing alone is.
- **Stealing** (`rtSchedSteal`): half of another carrier's local queue (Go's `runqgrab`), else a fiber that has waited in another carrier's slot past the **steal age**, 3 µs (`NOMU_SLOT_STEAL_NS`, Go's stealer's wait). A slot's fiber usually runs within a microsecond, when its readier parks, so the age keeps a handoff in progress on its carrier and moves a fiber stranded behind a readier that keeps running.
- **The slot's age without a clock on any switch.** A clock read costs a fiber switch a large share of its time (`mach_absolute_time` runs through the libc stack switch on a fiber's stack), so no switch reads one. Each carrier counts its switches (rec+200), and a first-seen word (rec+256, `rtSlotSeen`) records when an observer first saw the current count, by the observer's clock. A carrier stamps itself when it wakes a searcher (the wake is a system call, so the clock read costs nothing beside it), and the monitor stamps every carrier at each tick. A searcher stamps a carrier only after two of its looks in a row saw the same count there: a handoff chain changes the count at every hop, so searchers spinning beside one leave its record alone. A take leaves the word in place, so the next fiber a still-running readier strands can be taken at once.
- **Wakes** (`rtSchedWake`): a readying wakes one carrier, and only when one sleeps and none is already **searching**. A woken carrier searches, spinning for work up to 20 µs (`NOMU_SEARCH_NS`), and on finding some wakes the next if work is left anywhere (Go's `wakep` and `resetspinning`). A carrier with nothing to do counts itself sleeping, looks once more, then sleeps on a wake-generation word (§3).
- **The deferred wake.** A readying that fills the readier's own empty slot owes its wake instead of making it: the readier's next stops take their slow path, and the third pays the debt (`NOMU_DEFER_WAKE`, 0 turns it off). A park or an end drops it, since the slot's fiber then runs on this carrier next; a call into C or any other leaving pays it. A readier on its way to a park passes a stop or two first (a send's exit, a receive's entry), so paying at the first stop would wake for nearly every handoff. A carrier whose debt was paid wakes at once for its next 16 readyings: its readiers keep running, and owing would only cost them their stops. No wake is lost: the debt is dropped only when its fiber is this carrier's next pick.
- **The direct switch** (`rtSchedDirectTarget`). A fiber parking under a lock handoff (`nomuSchedParkReleasing`, which channels use, and `nomuSchedParkLocked`) with a fiber in its slot switches straight into that fiber and hands it the lock: one context switch a hop, with no pass through the carrier loop. The switch does the loop's duties: the carrier's running fiber (rec+64), the switch count, stop-the-world arming, and the run, which the switched-in fiber continues. `NOMU_DIRECT_SWITCH=0` turns it off.

With these, a fiber hop on 8 carriers takes 28 ns (65 before 237) and a channel hop 58 ns on 61 ms of CPU (109 ns on 831 ms before), against Go's channel hop of 111. The compiler marking handoff sites (237's other option) would add little: a readier that keeps running pays three slow-path stops per wake, which do not show on `stream_channel` against the deferred wake turned off, and the switch is already direct.

---

## 2. Wakeup feeders

The concrete runtime components that call `unpark` (detailed as "Layer 2" in `concurrency.md` §2):

- **I/O poller** — epoll / kqueue / io_uring on a dedicated poller; registers a fiber and unparks it on readiness.
- **Timer heap** — sleeps/deadlines register a fiber with an expiry; the timer fires the unpark. Powers timeouts and `select`-with-timeout.
- **Calls into C, blocking syscalls among them** — one path for every call, with no eager offload: the fiber marks itself in C (`rtEnterC`) and calls on its own carrier. A call that does not block pays nothing more. When one holds its carrier across the monitor's ticks with work waiting, the monitor hands that carrier's work to a spare carrier (Go's handing a P from an M in a syscall), and the fiber, on return, takes a carrier as any ready fiber does (§6, calls into C).

These are all **Nomu-managed threads**. When one unparks a fiber, it is a cross-thread wake *within the runtime* (§3, in-runtime tier) — the normal case, needed regardless of FFI.

---

## 3. Cross-thread resume & wakeup — **Decided (2026-07-16)**

Waking a parked fiber from a different thread than the one that parked it is the runtime's core job. It has two tiers that share one contract.

**The shared contract (locked at the in-runtime tier):**

- **`resume`/`unpark` is context-free** — it operates only on the fiber/continuation handle plus the global scheduler, via thread-safe primitives, and never assumes it runs on a Nomu fiber (no `current()`, no task-locals). This single rule is what keeps a future foreign-thread resume (§5) low-friction.
- **MT-safe run queue** — enqueuing a woken fiber is a multi-producer / multi-consumer operation (poller, timer, offload carriers, and later foreign threads are all producers).
- **Remote-wake** — if every carrier is asleep, the waker must be able to wake one via a cross-thread signal. A sleeping carrier waits on a wake-generation word with a futex-class wait (`__ulock_wait` on macOS, `futex` on Linux); a waker bumps the word and wakes one, and the bump closes the window between a carrier's last look for work and its wait. When to wake is §1.1's policy. — **Decided (built).**
- **Happens-before via the queue** — the run-queue push (release) / pop (acquire) publishes the woken fiber's data (e.g. a continuation's resumed value) to the carrier that resumes it; no extra fence on the value is needed.

**Tier 1 — in-runtime resume (the common, near-term case).** The resumer is a Nomu-managed thread (poller / timer / offload carrier). This is the ordinary scheduler operation above; it backs all of `readFile`, channels, mutexes, actors, and the continuation's non-FFI uses. It needs no FFI and no attach.

**Tier 2 — foreign-thread resume.** The resumer is a thread a C library created (inbound-callback FFI). It needs the same contract **plus** foreign-thread attach and GC pinning (§5). Deferred with FFI; it adds no new continuation or scheduler semantics — only the attach step — precisely because Tier 1 already forces the context-free, MT-safe design.

**Continuation tie-in:** the continuation's cross-thread `resume` (`concurrency.md` §3) is an application of this contract. Its token carries an atomic state word (resume-once; double-resume traps at runtime), and the value it publishes rides the run-queue happens-before above. The token is *shareable-by-construction* because `resume` is internally synchronized here.

---

## 4. Platform & syscall strategy

- **Direct syscalls where possible (Go-style, no CGO), for fully static binaries.** The runtime and stdlib own their threads and talk to the OS directly, which serves the deployment goal (static binary, under 9MB, copy-and-run — `vision.md` → Deployment). — **Leaning (direction).**
- **Platform nuance:** "no libc" is realistic on **Linux** (stable raw syscall ABI). On **macOS / BSD** the stable ABI is the platform libc (`libSystem`), so those targets go through a thin platform-libc shim rather than raw syscalls. — **Noted.**
- **libc dependency is itself under review** — whether to drop it à la Go-without-CGO, accepting the per-platform syscall maintenance cost. — **Open.**

A consequence that matters for §5: because the runtime owns all its threads and does no inbound-callback FFI, **nothing Nomu ships hits the foreign-thread tier.** That friction exists only when a user opts into a C library.

---

## 5. FFI-readiness

FFI (calling C, and C calling back) is **not planned near-term**, and beyond `libc` is not a target for stdlib features (§4). The goal here is only that language/runtime design not make FFI *high-friction later* — not to build it now.

- **Outbound (Nomu calls C):** straightforward — marshal args, call, return. No runtime hazard.
- **Inbound (C calls a Nomu callback), same thread:** a Nomu carrier running C that calls back into Nomu is already attached; fine.
- **Inbound on a foreign thread:** a C library invoking a Nomu callback from a thread *it* created needs **foreign-thread attach** (lend a GC allocation buffer, register for safepoints, set up a fiber context — JNI `AttachCurrentThread` / Go cgo) and **moving-GC pinning** (Immix moves objects, so Nomu objects held across the boundary must be pinned). — **Deferred (with FFI).**

**What protects this cheaply:** the §3 context-free resume rule + MT-safe scheduler primitives are required for the in-runtime tier *anyway*. Honoring them now means foreign-thread resume "just works" once attach exists — FFI-readiness falls out of getting the scheduler right, at no present cost. The one thing to avoid is baking in a "the resumer is always a Nomu fiber" assumption.

---

## 6. GC integration touchpoints

The scheduler and the collector are co-designed at a few seams (object-model + backend detail in `noir.md` / `backend.md`, `memory-model.md` §3). Built as M6 (real GC via MMTk GenImmix); the decisions below are as-built.

- **Safepoints & precise stack maps** — a moving collector needs fibers to reach safepoints and their stacks scanned precisely. Roots come from LLVM statepoints (`backend.md`), never conservative scanning.
- **Write barriers** — inserted by codegen (the `__nomu_write_barrier` seam); the runtime honors them. GenImmix fills it as a generational logging barrier; LXR refills the same seam as the RC barrier.
- **Root scanning across fibers** — every parked fiber's stack is a root set.

As-built decisions (all **Decided 2026-08-04**, built M6; the design forks and their rejected alternatives were retired with the M6 spec — this is the surviving record):

- **Mutator granularity: per-carrier thread.** One MMTk `Mutator` (TLAB + allocators) per carrier, bound at carrier init; every allocation reads the *current* carrier's cursor/limit fresh. Bounds TLAB count to carrier count (~4–16) rather than one-per-fiber, protecting the ~1.1–1.3× footprint thesis. Codegen contract: the fast-path cursor/limit load is not hoisted or cached across a safepoint/suspend. *(Deferred locality optimization: pin a fiber to its carrier while it holds allocation state — revisit only on a measured allocate-then-traverse cost.)*
- **Runtime/binding boundary: thin Rust binding, runtime stays C.** MMTk's `VMBinding` is the only Rust — a shim whose trait methods FFI back into the C runtime (root walk, object-model accessors, STW hooks). Keeps the built M4 scheduler and C stack-map walk untouched; blast radius is one crate. *(Escape hatch on a measured FFI cost: move only the GC-facing hot callbacks — `scan_object` reading static pointer maps, the libunwind root walk — into Rust; scheduler stays C.)*
- **Safepoint poll form: the stack limit as the request word.** A request to stop writes all ones into the running fiber's stack limit (fiber+40), the word its function-entry check already compares the SP with, as Go's stack guard does. The loop poll (a placeholder at every loop header, strip-mined out of call-free innermost loops and expanded after optimization, `backend.md`) loads that word and branches past a slow-path call while it is not all ones. The slow path restores the limit, then reads the stop-the-world flag and parks if set. The function-entry stack check is a stop too: its slow path parks the same way when its `need` is 0 (a frame-split wrapper's check and a runtime-sized buffer's ask for room and only raise the limit again). So a fiber in recursion or straight-line code stops at its next call. Polls that bound nothing are dropped after optimization: one the optimizer left outside every cycle, and a loop header's poll when another poll the loop keeps dominates every latch (`LoopPolls.cpp`). **Preemption** uses the same word: a monitor thread (`rtSchedMonitorMain`) finds a carrier running one fiber across a tick (a quarter of the slice) with work waiting, names the fiber as that carrier's target and raises its limit; at its next stop the fiber, with no stop-the-world pending, switches back ready and its carrier puts it on the global queue (Go's `sysmon` and its preemption request, cooperatively). What that relies on: the check moves after optimization only past values a stop describes (`nomu-expand-stack-checks`); a large argument is forwarded by pointer only past a wrapper's check (`LargeValues.cpp`); a fiber routine's environment is a managed pointer from its entry (`adoptManaged`). The coordinator raises the flag, then each carrier's running fiber's limit; a carrier switching a fiber in restores its limit, publishes it, then reads the flag (`runtime/scheduler.nomu`, the request word), so one of the two always sees the other. The slow-path call is a statepoint, so the poll frame is precisely scannable through the existing call-keyed walker. *(Deferred, profile-guided: protected-page faulting load, the JVM model — needs poll-PC stackmaps our call-keyed pipeline doesn't emit.)*
- **Safepoint density: the placement is the invariant.** Stops sit at function entries (the stack check), loop headers (strip-mined out of call-free innermost loops, so a counted loop polls once per chunk), the alloc slow path and calls into C. Every loop iteration and every call reaches one, so time to stop is bounded by one loop chunk or one call-free stretch of straight-line code. The real rule is a **pass-pipeline constraint: `-O` transforms must not delete the last stop from a loop or create an unbounded stop-free region.** Preemption uses the same stops, so its latency is time to stop plus the monitor's period. What is left unbounded, in Go too: a return path unwinding deep recursion (no check on return), a large copy (`memcpy` from compiled code, a plain call into C), and the runtime's stack move (below). Measured against Go in task [236](../plans/tasks/236-fiber-preemption.md) (`tools/stopbench.py`).
- **Preemption policy (Go's `sysmon`, cooperatively).** The monitor (`rtSchedMonitorMain`) looks at every carrier each tick, and ages **runs** (§1.1): a carrier whose run count (rec+112) is unchanged since the last tick has run one fiber, or one chain of handoffs, at least one period, a quarter of the slice (Go's `schedtick`, which a fiber taken from `runnext` does not bump). It is preempted only when work waits: its run queue, the global queue, or a fiber in its slot with no switch on that carrier since the last tick (a slot that refills at every hop of a chain is no sign of waiting work). With a carrier asleep the monitor wakes one instead. When a run is preempted, its carrier moves the slot's fiber behind its queued work, which ends the chain. The period stays short while a carrier runs one fiber across a tick or has work behind it, and backs off to 1 ms during short bursts and 10 ms when idle. A preempted fiber goes to the global queue, so an idle carrier can take it. **A run keeps its age across stops:** a fiber resumed after a stop-the-world or a stack move goes back in through `rtSchedRearm`, which leaves the switch count and the monitor's target alone and raises the limit again for either; otherwise collections arriving faster than the monitor ticks would hide a fiber that never yields. `NOMU_PREEMPT=0` turns the monitor off.
- **Calls into C: one path, a stop for collections.** A call that may block is made in C: the fiber records its anchor and saved registers (`rtEnterC`), so a stop-the-world counts it as stopped and scans it from that record without waiting, and on return (`rtExitC`) it parks if a collection or a handoff happened meanwhile. A per-carrier in-C mark lets the monitor see a carrier held by one call across two ticks; with work waiting it hands that carrier off (`rtHandOff`): a spare carrier takes its place, and once the fiber leaves it the handed-off carrier retires (`rtSchedRetire`), its queued work going to the global queue and the carrier parking as a spare. `print`'s `write` is the first user (task [270](../plans/tasks/270-c-calls-as-stops.md)); compiled code's calls into C take the same path with FFI ([130](../plans/tasks/130-ffi-c-abi.md)).
- **The runtime's own code has no stops** (the runtime subset, `runtime-subset.md`): it runs inside stops and during a stop-the-world, so a stop there would recurse. The rule that keeps G2 is that its loops stay short: a hole scan is at most a block's 128 lines, a refill zeroes at most one 32 KiB block, a print copies into a chunk and writes in C. The exception is the stack move, which copies the used stack and walks every frame, so it grows with the stack, as Go's copy does. Checked by `tools/stopbench.py` modes 2–6 and the suite case `stw-runtime`.
- **Parked-fiber stack scanning: global live-fiber registry + present-as-parked syscalls.** Every suspension goes through `park()` (a non-leaf call → statepoint), so a parked fiber's top Nomu frame has a stackmap and its stack is walkable from the saved `ucontext` (build a `unw_context_t` from saved registers; libunwind unwinds out through the gc-leaf C frames). Fiber enumeration is an intrusive lock-guarded doubly-linked registry (O(1) insert/remove, off the hot path; STW iterates it) — one source of truth, chosen over gathering from wait-lists (a missed list = missed roots). A fiber in a call into C records its scannable context as it enters (`rtEnterC`); STW scans from that context and does not wait for the call (the C code holds no Nomu roots). Invariants: all suspension via `park()`; STW quiesces before iterating the registry; the saved `ucontext` captures the full callee-saved set (arm64 x19–x28). *(Deferred, profile-guided: alternative registry structures — sharded/lock-free/epoch — only on a measured win over the intrusive-DLL baseline.)*

These were gating runtime engineering; the shipped runtime (`src/runtime/`, `src/gcbinding/`) is the implementation record.

---

## 7. Open questions

- **Scheduler internals** — the parallelism knob, stack-growth strategy, task-locals, poller implementation (§1, §2).
- **Platform syscall strategy** — how far to push no-libc; per-platform coverage (§4).
- **FFI** — foreign-thread attach + moving-GC pinning; deferred with FFI, protected by the context-free rule (§5).
- **Waking a wait for `select`** — how a poller-backed read or timer takes part in a `select` (`concurrency.md` §7). The scheduler has no cancellation of its own.

---

## 8. Implementation status (M4, C backend)

The scheduler is implemented in the C preamble emitted by the codegen for every compiled program. This section documents what exists, the API contract, and what remains deferred.

### What's built

**M4.1–M4.2 — Fiber context switch + single-carrier scheduler**
Context switching uses `ucontext`/`swapcontext` (POSIX, deprecated on macOS but functional). Each fiber gets a heap-allocated fixed stack (`RT_STACK_SIZE = 128KB`). The scheduler is a loop that pops from the run queue and switches into the next fiber; when the fiber yields control (by parking or finishing), it switches back to the per-carrier scheduler context (`rt_sched_ctx`).

**M4.3a — Multiple carriers**
`N` OS pthreads each run `rt_scheduler_run()` against a single shared run queue protected by `rt_queue_mu`. The carrier count is hardcoded at 4 (`RT_MAX_CARRIERS = 16` cap exists but the knob is not yet wired). Each carrier has thread-local `rt_current` and `rt_sched_ctx`.

**M4.3b — Idle carrier sleep**
Carriers sleep on `rt_queue_cond` (a `pthread_cond_t`) when the queue is empty but `rt_active > 0`. `rt_rq_push` calls `pthread_cond_signal`; `rt_fiber_trampoline` calls `pthread_cond_broadcast` on completion so all carriers re-check the exit condition.

**M4.4 — I/O poller (macOS only)**
A dedicated poller thread runs a `kqueue` loop. `rt_wait_readable(fd)` registers a one-shot `EVFILT_READ` kevent with `rt_current` as `udata`, then parks the fiber (`FIBER_PARKED` + `swapcontext` back to scheduler). The poller thread pushes the fiber back onto the run queue when the fd fires. Currently used for stdin; wires up to any readable fd.

**M4.5 — Timer heap**
A min-heap of `(expiry_ns, Fiber*)` pairs, ordered by `CLOCK_MONOTONIC` nanosecond timestamp. Protected by `rt_timer_mu` / `rt_timer_cond`. A dedicated timer thread sleeps with `pthread_cond_timedwait` until the nearest deadline, fires expired entries by pushing their fibers onto the run queue, then loops. `rt_sleep_ms(ms)` inserts into the heap and parks the calling fiber.

### Internal API contract

These functions are runtime-internal (emitted into the C preamble, not Nomu surface):

| Function | Lock requirement | Notes |
|---|---|---|
| `rt_rq_push(f)` | Must hold `rt_queue_mu` | Signals `rt_queue_cond` after push |
| `rt_rq_pop()` | Must hold `rt_queue_mu` | Returns NULL if empty |
| `fiber_spawn(fn, arg)` | None (acquires `rt_queue_mu` internally) | Increments `rt_active`; pushes fiber |
| `spawn_join(h)` | None (acquires `rt_queue_mu` internally) | Parks caller if fiber not yet DONE |
| `rt_sleep_ms(ms)` | None (acquires `rt_timer_mu` internally) | Parks caller; woken by timer thread |
| `rt_wait_readable(fd)` | None | Parks caller; woken by poller thread (macOS only) |
| `rt_timer_push(expiry, f)` | Must hold `rt_timer_mu` | Signals `rt_timer_cond` after push |

### Fiber lifecycle

```
fiber_spawn()
     │
     ▼
FIBER_RUNNABLE ──── carrier picks up ──→ running (rt_current)
     ▲                                        │
     │                                   park / join / sleep
     │                                        │
     └──── unpark (poller/timer/joiner) ── FIBER_PARKED
                                              │
                                         fiber fn returns
                                              │
                                          FIBER_DONE ──→ joiner unparked (if any)
```

Transitions:
- `RUNNABLE → running`: carrier calls `swapcontext` into fiber
- `running → PARKED`: fiber calls `spawn_join` (target not done), `rt_sleep_ms`, or `rt_wait_readable`; sets status, switches back to scheduler
- `PARKED → RUNNABLE`: timer thread, poller thread, or completing fiber calls `rt_rq_push`
- `running → DONE`: fiber function returns; `rt_fiber_trampoline` sets status, decrements `rt_active`, unparks joiner if any

### `rt_active` invariant

`rt_active` counts all fibers that are not yet `FIBER_DONE`. It is incremented under `rt_queue_mu` in `fiber_spawn` and decremented under `rt_queue_mu` in `rt_fiber_trampoline`. Carriers exit `rt_scheduler_run` when the queue is empty **and** `rt_active == 0`. This is the only program-exit condition.

### Cross-thread wake safety (satisfies §3)

`rt_rq_push` is always called under `rt_queue_mu`, which provides the release fence; carriers pop under the same lock (acquire). This satisfies the happens-before requirement from §3 — the woken fiber's result is visible to whichever carrier resumes it. The poller and timer thread are both Nomu-managed threads (§3 Tier 1); neither assumes `rt_current` is set, satisfying the context-free resume rule.

### Deferred from M4

- **Stack growth** — fixed 128KB stacks; growable **contiguous** (copy-on-grow) stacks scheduled with the dynamic spawn group (see the §1 stack-growth item and task `plans/tasks/104-fiber-stack-strategy.md`).
- **Parallelism knob** — carrier count hardcoded at 4; `GOMAXPROCS`-equivalent not yet wired.
- **Work stealing** — M4.3c; single shared queue used instead.
- **Blocking-syscall offload** — M4.6; `nanosleep` / file reads block the carrier.
- **Task-locals** — open; no implementation.
- **Linux I/O poller** — kqueue is macOS-only; epoll path not yet written.
- **Actor mutex → fiber-aware mutex** — actors still use `pthread_mutex_t`; should use the park/unpark primitive to avoid blocking a carrier when a handler is held.
