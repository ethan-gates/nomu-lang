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
- **Stack growth** — growable/segmented or copy-on-grow stacks so a fiber starts small. Strategy open. — **Open.**
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

The scheduler and the collector are co-designed at a few seams (details in `compiler.md` §1–2, `memory-model.md` §3):

- **Safepoints & precise stack maps** — a moving collector (Immix/LXR) needs fibers to reach safepoints and needs to scan fiber stacks precisely.
- **Write barriers** — inserted by codegen; the runtime honors them.
- **Root scanning across fibers** — every parked fiber's stack is a root set; the runtime exposes them to the collector.

These are gating runtime engineering, tracked with the backend work, not restated here.

---

## 7. Open questions

- **Scheduler internals** — work-stealing details, the parallelism knob, stack-growth strategy, task-locals, poller implementation (§1, §2).
- **Remote-wake primitive** — eventfd vs. self-pipe vs. futex (§3).
- **Platform syscall strategy** — how far to push no-libc; per-platform coverage (§4).
- **FFI** — foreign-thread attach + moving-GC pinning; deferred with FFI, protected by the context-free rule (§5).
- **Cancellation propagation through the scheduler** — how a cancelled scope unwinds parked children (interacts with the cancellation model, `concurrency.md` §7).
