# Runtime & Scheduler

**Status:** working draft. The home for Nomu's execution substrate — the M:N scheduler, the wakeup feeders, cross-thread mechanics, platform/syscall strategy, and FFI-readiness. Status tags: **Locked**, **Decided**, **Leaning**, **Open**.

**API scope:** this doc is about runtime *mechanism*, below the surface language. Nothing here is user-facing API. The user-facing concurrency *model* and the abstract suspension primitive (`park`/`unpark`/`current` + permit) live in `concurrency.md` (§1, §2); this doc is how the runtime realizes them.

**Runtime is mandatory.** Per `vision.md` → "Library tiers," there is no runtime-less configuration; the GC (MMTk) and this scheduler are the always-present floor.

---

## Terminology (settled 2026-07-16, not locked)

- **Fiber** — the lightweight, stackful execution context, many multiplexed M:N over OS threads. The scheduler-level unit: you *park*, *switch*, *schedule*, *steal* a fiber; a fiber *has its own stack*.
- **Carrier** — the OS thread a fiber runs on (the N in M:N). "Green thread" is used only in cross-language comparison, not as our own term.
- **Fiber handle** — the runtime-internal reference `park`/`unpark`/`current` operate on. **Not programmer-visible.**
- **Task** — a *concept*, not a type: the structured-concurrency unit (scope, lifetime, cancellation, task-locals, the shareability boundary), 1:1 with a fiber while it runs. "Task boundary" and "task-local" name the concept. **There is no programmer-visible `Task` or `Fiber` type right now**; exposing one is deferred (discuss later) in favor of keeping the surface small.

The doc set follows this vocabulary (pass done 2026-07-16): **fiber** for the runtime execution context (park / schedule / suspend / wait-lists / run queue), **task** only for the structured-unit concept (task boundary, task-local, the scope/cancellation tree). "Green thread" appears only in cross-language comparison. Spellings of any future user-visible type stay deferred.

---

## 1. Scheduler model

- **M:N stackful fibers** — many fibers multiplexed over few OS carrier threads; a fiber has a real stack and can suspend anywhere. — **Locked** (`concurrency.md` §1).
- **Work-stealing** across carriers, with per-carrier run queues and a shared overflow queue (Go/Tokio shape). — **Leaning.**
- **A parallelism knob** (`GOMAXPROCS`-equivalent) caps carrier count. — **Leaning.**
- **Stack growth** — growable **contiguous** stacks (copy-on-grow, Go's post-2014 model) so a fiber starts small and grows by copying to a larger buffer; segmented ("hot split") rejected. A copy relocates the stack, so every interior/frame-relative pointer and saved SP must be found and rewritten — this reuses the precise parked-fiber stack walk the moving GC already emits (statepoint stack maps + §6), extended from *scan* to *relocate*. Infrastructure is in place; **gated on the dynamic spawn group** (tasks `plans/tasks/104-fiber-stack-strategy.md`, `plans/tasks/103-dynamic-spawn-group.md`) so the payoff (massive fan-out shrinking the fixed-128 KiB footprint) is measurable on that workload's own concurrency benchmark the day it lands. — **Decided (contiguous copy-on-grow); scheduled with the dynamic spawn group.**
- **Task-locals** — per-task storage analogous to goroutine-locals / thread-locals. Shape open. — **Open.**

The abstract suspension primitive these rest on — `park`/`unpark(t)`/`current` with permit semantics — is Locked and specified in `concurrency.md` §2; this doc does not restate it.

---

## 2. Wakeup feeders

The concrete runtime components that call `unpark` (detailed as "Layer 2" in `concurrency.md` §2):

- **I/O poller** — epoll / kqueue / io_uring on a dedicated poller; registers a fiber and unparks it on readiness.
- **Timer heap** — sleeps/deadlines register a fiber with an expiry; the timer fires the unpark. Powers timeouts and `select`-with-timeout.
- **Blocking-syscall offload** — syscalls that can't be made non-blocking run on a carrier OS thread so the scheduler keeps going; the fiber parks and is unparked when the carrier returns (Go's syscall handoff).

These are all **Nomu-managed threads**. When one unparks a fiber, it is a cross-thread wake *within the runtime* (§3, in-runtime tier) — the normal case, needed regardless of FFI.

---

## 3. Cross-thread resume & wakeup — **Decided (2026-07-16)**

Waking a parked fiber from a different thread than the one that parked it is the runtime's core job. It has two tiers that share one contract.

**The shared contract (locked at the in-runtime tier):**

- **`resume`/`unpark` is context-free** — it operates only on the fiber/continuation handle plus the global scheduler, via thread-safe primitives, and never assumes it runs on a Nomu fiber (no `current()`, no task-locals). This single rule is what keeps a future foreign-thread resume (§5) low-friction.
- **MT-safe run queue** — enqueuing a woken fiber is a multi-producer / multi-consumer operation (poller, timer, offload carriers, and later foreign threads are all producers).
- **Remote-wake** — if every carrier is asleep in the poller, the waker must be able to wake one via a cross-thread signal (eventfd / self-pipe / futex — Go's netpoller trick). The exact primitive is scheduler-internal. — **Open (mechanism).**
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
- **Safepoint poll form: branch-on-flag.** `__nomu_poll` (emitted only at the header of call-and-alloc-free loops) loads a per-carrier stop-requested flag, tests, branches past a slow-path call that parks. The slow-path call is a statepoint, so the poll frame is precisely scannable through the existing call-keyed walker. *(Deferred, profile-guided: protected-page faulting load, the JVM model — needs poll-PC stackmaps our call-keyed pipeline doesn't emit.)*
- **Safepoint density: the placement is the invariant.** Safepoints sit at non-leaf call returns + call-and-alloc-free loop back-edges + the alloc slow path. Every loop iteration reaches one, so time-to-safepoint is bounded by one loop body. The real rule is a **pass-pipeline constraint: `-O` transforms must not delete the last safepoint from a loop or create an unbounded safepoint-free region.** Scheduler preemption is a separate signal mechanism (`loops.md`), so there is no fairness motive to go denser.
- **Parked-fiber stack scanning: global live-fiber registry + present-as-parked syscalls.** Every suspension goes through `park()` (a non-leaf call → statepoint), so a parked fiber's top Nomu frame has a stackmap and its stack is walkable from the saved `ucontext` (build a `unw_context_t` from saved registers; libunwind unwinds out through the gc-leaf C frames). Fiber enumeration is an intrusive lock-guarded doubly-linked registry (O(1) insert/remove, off the hot path; STW iterates it) — one source of truth, chosen over gathering from wait-lists (a missed list = missed roots). A blocking-syscall fiber checkpoints its scannable context at the offload handoff and is marked parked-in-syscall; STW scans from that context and does not wait for the offload carrier (it holds no Nomu roots). Invariants: all suspension via `park()`; STW quiesces before iterating the registry; the saved `ucontext` captures the full callee-saved set (arm64 x19–x28). *(Deferred, profile-guided: alternative registry structures — sharded/lock-free/epoch — only on a measured win over the intrusive-DLL baseline.)*

These were gating runtime engineering; the shipped runtime (`src/runtime/`, `src/gcbinding/`) is the implementation record.

---

## 7. Open questions

- **Scheduler internals** — work-stealing details, the parallelism knob, stack-growth strategy, task-locals, poller implementation (§1, §2).
- **Remote-wake primitive** — eventfd vs. self-pipe vs. futex (§3).
- **Platform syscall strategy** — how far to push no-libc; per-platform coverage (§4).
- **FFI** — foreign-thread attach + moving-GC pinning; deferred with FFI, protected by the context-free rule (§5).
- **Cancellation propagation through the scheduler** — how a cancelled scope unwinds parked children (interacts with the cancellation model, `concurrency.md` §7).

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
