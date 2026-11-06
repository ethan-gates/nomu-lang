# Concurrency

**Status:** working draft. The detailed home for Nomu's concurrency model and runtime. Status tags: **Locked**, **Open**, **TODO**.

**API scope:** no concrete API here is committed. Any named or lowercase construct (channels, mutexes, `select`, a self-synchronizing type) is **illustrative** until we explicitly agree to it, and each will be pinned as **language** or **standard library** at that point. What is Locked is the *model* and the *runtime primitive shape*, not surface API.

---

## 1. Model (Locked)

- **Colorless.** No function coloring, no `async`/`await` split. Drives an **M:N stackful** runtime — a fiber can suspend anywhere because it has a real stack.
- **No suspension marker (transparent, Go-style).** A blocking call looks like an ordinary call; there is no `await` or other marker showing where a fiber suspends. — **Decided (2026-07-16).**
- **Concurrency is never implicit in your control flow.** Without an explicit `fiber` or `task`, your statements run in sequence and nothing you wrote runs overlapping. A call may block, and the runtime freely schedules *other* fibers while it does (poller, work-stealing, thread handoff), but it never makes your *own* statements run concurrently. This is what carries serial-vs-concurrent legibility without a suspension marker. A call may leave a detached fiber running past its return, as in Go (§8).
- **Detached fibers + channels + actors** as the model. A fiber is detached by default; `task` gives a joinable result (§8); channels carry flow (§4); actors own isolated stateful concurrency (§9).
- **Race-free by construction (the shareability rule).** Reference types are task-local by default; a value crossing a task boundary must be "shareable" (a value type, an immutable type, an actor handle, or — reserved, design deferred — a self-synchronizing type, §10). Shareability is auto-derived structurally and surfaces only as a bound on the concurrency APIs — Rust's `Send`/`Sync` without the borrow checker.
- **Actors** are owning GC handles with reference-driven lifetime (collected when unreferenced-and-idle). You interact through **one mechanism only: fire-and-forget message-send**, written as a method call (no suspension marker). An actor is a one-way message sink — a handler never returns a value to the sender, and there is no reply/ask/request-reply. To obtain a value produced by concurrent work, use a `task` (§8) or a channel (§4), not an actor. Exact actor-access syntax open (§9). No `weak`, no dangling.

---

## 2. The suspension core (Locked)

The entire system rests on one runtime capability. Channels, mutexes, actor mailboxes, and blocking I/O are all the same pattern: **manage a wait-list of fiber handles, `park` when you can't proceed, `unpark` whoever you unblock.** The only difference between them is *who owns the wait-list and who calls `unpark`* — another fiber, an actor's sender, or the poller.

**Layer 0 — context switch.** Save/restore a fiber; for stackful fibers this is a stack switch. The scheduler's substrate, not an API anyone calls.

**Layer 1 — the core primitive.**

```
type Fiber             // runtime-internal handle to one fiber (not programmer-visible)
fun current() Fiber    // handle of the running fiber
fun park()             // suspend current fiber until it holds a permit
fun unpark(f Fiber)    // give f a permit and make it runnable
```

(This handle is runtime-internal; there is no programmer-visible `Fiber` or `Task` type — see `runtime.md` → Terminology.)

The correctness hazard is the **lost-wakeup race**: a fiber checks a condition, decides to park, but a producer calls `unpark` before the park commits, and the wakeup is lost. Two standard fixes:

- **Permit semantics** (Java Loom / `LockSupport`): `unpark` sets a permit; `park` consumes one and only blocks if none exists. Order-insensitive and composable — the general primitive.
- **Lock-coupled park** (Go's `gopark`): hold the lock guarding the condition; `park` atomically releases it and suspends, so a producer holding the same lock can't fire `unpark` until the park has committed. More efficient for hot built-ins (channels, mutexes) that already hold a lock.

Direction: permit-based pair as the primitive, with a lock-release-on-park variant for performance-critical stdlib types.

**Layer 2 — wakeup feeders** (what calls `unpark`):

1. **I/O poller** — epoll / kqueue / io_uring on a dedicated poller. `waitReadable(fd)` registers `current()` and parks; the poller unparks on readiness.
2. **Timer heap** — `sleep`/deadlines register `current()` with an expiry and park; the timer fires the unpark. Powers timeouts and `select`-with-timeout.
3. **Blocking-syscall offload** — syscalls that can't be made non-blocking run on a carrier OS thread so the scheduler keeps going; the fiber parks and is unparked when the carrier returns (Go's syscall handoff).

**Layer 3 — library abstractions** built on Layers 1–2 (illustrative — none of these are committed as a Nomu language or stdlib API yet): channels, mutexes, semaphores, wait-groups, the actor mailbox, `select`. The point is that all of them are ordinary code over park/unpark + a wait-list.

**A channel in these terms** (sketch):

```
fun (c Chan<T>) receive() T {
    lock(c.mu)
    if v, ok := c.take(); ok { unlock(c.mu); return v }
    c.recvQ.push(current())
    unlockAndPark(c.mu)          // lock-coupled: no lost wakeup
    return c.slotFor(current())  // a sender handed us a value before unparking us
}
fun (c Chan<T>) send(v T) {
    lock(c.mu)
    if r, ok := c.recvQ.pop(); ok { c.handoff(r, v); unlock(c.mu); unpark(r); return }
    // else buffer, or push current() to sendQ and park
}
```

Blocking I/O (`poller.register(fd, current()); park()`) and the actor mailbox (`mailbox.recvQ.push(current()); park()`, a send does the `unpark`) are the identical shape. `select` is the one piece that needs a touch more: register `current()` on several wait-lists, first waker wins, deregister the rest via a claimed-flag.

---

## 3. Exposure of the primitive — the continuation (Decided 2026-07-16)

The core primitive is locked runtime-internal; the exposed form for library authors and FFI is a **closure-scoped, one-shot, checked continuation**. The spectrum and rationale below record how that was reached; the decision itself:

- **Exposed form** — a **closure-scoped one-shot continuation** (Swift `withCheckedContinuation` model): the token is handed to you inside a scope so it can't be lost, resume-*once*, checked. Its job is to turn an external callback-shaped API into a plain colorless blocking call — the everyday programmer never sees it, only the blocking function it manufactures.
- **Tier** — a **runtime intrinsic**, compiler-blessed, **not stdlib**. Available whenever the runtime is (which is always — `vision.md` → "Library tiers"). This keeps the stdlib pure: nothing that needs privileged `park`/`unpark` access lives in a library function user code couldn't call.
- **The token is a linear type** — resume-once and must-resume are enforced by the general linear-types mechanism (shared with `memory-model.md` §6.2 resource cleanup, not a bespoke checker). Enforcement is **compile-time on the Nomu side**; across the **FFI boundary** the compiler loses sight of the token, so double- and forgotten-resume there are **runtime-checked** (this is what "checked" buys). *Contingency:* linear types are still to design (`memory-model.md` §6.2); until they land, resume-once is runtime-checked throughout — so the continuation is not blocked by them.
- **Value / error handoff** — `resume(value)`, plus a failable form carrying a `Result` so errors arrive as values (`types.md` §4); no `throws` on resume.
- **Raw `park`/`unpark`, the poller, and timers stay runtime-internal** — not user surface. Option 4 (raw exposed) rejected as too sharp.
- **Surface spelling deferred** — keyword (`suspend { cont in … }`) vs. function (`withContinuation { cont in … }` over `Continuation<T>`) is a spelling choice in the deferred bucket; both are language-blessed and keep the stdlib pure, so the semantics above don't depend on it.

**Cross-thread resume safety — Decided (2026-07-16), mechanics in `runtime.md` §3.** The token and result type cross a task boundary, so **`T: shareable`** and **`Continuation<T>` is shareable-by-construction** (its `resume` is internally synchronized). `resume` is **context-free** (no `current()`), does an **atomic resume-once** (double-resume traps at runtime), enqueues on the **MT-safe run queue**, and remote-wakes an idle scheduler; the queue provides happens-before for the value. This is locked at the in-runtime tier (the resumer is a Nomu poller/timer/offload thread); the **foreign-thread/FFI variant** (attach + GC pinning) is deferred with FFI and adds no new continuation semantics.

**Cancellation.** The runtime has no cancellation concept (§7), so `withContinuation` is an ordinary wait. A library that wants a wait to end early resumes the continuation itself. **Resume-once is checked at runtime:** the atomic resume-once CAS (`runtime.md` §3) makes a second resume a safe no-op or a trap, with no linear type, in keeping with the rule that the type system does not carry concurrency behavior.

---

**Rationale — the spectrum this resolves.** Channels alone already let you build most synchronization (semaphore, mutex, wait-group, futures — Go proves it), so exposure is about what channels handle poorly.

**What exposing a low-level primitive buys:**
1. **FFI / callback bridging (decisive).** Turning an external "call me back later" API (a C library, io_uring completion, a GUI/hardware callback) into a colorless park/resume. Channels do this clumsily (a channel plus a bridging task); a continuation is the natural, zero-overhead tool.
2. **Performance for simple wait/signal** — a one-shot continuation is lighter than a full channel; lets library authors build tight mutexes/futures. (Go's own `sync.Mutex` avoids channels internally for exactly this.)
3. **Patterns channels can't express** — priority/fairness wait queues, custom wakeup order, barriers, reader-writer locks; a channel dictates FIFO value handoff.
4. **Extending the async I/O layer** — a library author integrating a new event source needs to plug into suspend/resume; otherwise only the runtime can add blocking primitives.

**Cost:** raw park/unpark is sharp — lost wakeups, double-resume, forgotten-resume leaks, untyped handles. This is why Go hides it.

**The spectrum:**
- **Hide it (Go):** channels + `Cond` + atomics only; FFI bridging is clumsy or privileged-stdlib-only.
- **Safe one-shot continuation (Swift `withCheckedContinuation`):** closure-scoped so it can't be lost, resume-*once*, "checked" traps double-resume and no-resume. Captures nearly all the value with guardrails.
- **Raw reusable park/unpark (Loom `LockSupport`):** maximum power, maximum footgun.

**The tiers (Decided, per the block above):**
- **Everyday users:** actors (state) + channels (flow, if adopted) + whatever shared-mutable/sync types we agree to add — plus plain blocking stdlib calls, which cover file/net/timer I/O via the poller with no continuation in sight.
- **Library authors / FFI:** the safe **checked one-shot continuation**.
- **Runtime only:** raw park/unpark, the poller, timers.

Reference points — Go hides the primitive and makes the *channel* the public suspension tool; Swift and Loom expose a continuation / park to library authors. Nomu takes the Swift-shaped continuation but, being stackful, it is a plain (uncolored) runtime intrinsic rather than an `async` function.

---

## 4. Channels — a library type, the base of the concurrency surface

**`Channel<T>` is a stdlib type over the suspension core, with no `chan` keyword and no `<-` operator.** They are the first concurrency library to build, because `Task` (§8) and stop signals (§7) are written over them.

**Role: flow.**
- **Actor** = an *addressed, stateful entity* — you send to *that* actor, it serializes messages against private state. Identity-centric (state).
- **Channel** = an *anonymous conduit* — put a value in, whoever is reading takes it; no identity beyond the pipe. Flow-centric (pipelines, fan-out/in, worker pools, streaming, `select`).
- Near-duals: an actor's mailbox is a channel + a loop + private state. Kept role-distinct (state → actor, flow → channel), they are two tools for two jobs — the boundary is documented, not left to taste.

**Addability — basic channels are a pure library.** Send/receive with buffered or unbuffered (rendezvous) capacity is ~30 lines over park/unpark + a wait-list (Rust `mpsc`, Kotlin, C# precedent). Plain methods, no `chan` keyword and no `<-` operator; the colorless model makes them read cleanly — a receive is a plain blocking call, no marker.

**`select` rides the exposed continuation — no runtime addition needed.** Waiting on several channels means "the first ready branch wins, the losers consume nothing." The exposed one-shot continuation (§3) already supplies exactly that: its **atomic resume-once is the claim**. A channel keeps a wait-queue of continuations and does **claim-before-handoff** — a sender tries to `resume` a waiter, and on a lost claim moves to the next, so its value is never given away; a `select` is one continuation registered across several channels' queues. So `select` is a **pure library over the exposed continuation**, the runtime stays single-wait and simple, and this composition doubles as validation of the continuation design. (This supersedes an earlier worry about reserving a runtime multi-wait primitive — the continuation covers it.)

**Residual (§10):** buffered/unbuffered API, the `select` surface, and all spellings. Channels stay a library over the suspension primitives (park/unpark internally; the continuation for `select`).

---

## 5. Share analysis (shareable inference)

How the compiler decides which values must be "shareable" (the shareability rule, §1) with minimal annotation.

**Status (M5):** the **structural derivation** and the declared **`<shared T>` bound** are **built** (M5 5.3); the bottom-up *inference* of a shareable requirement (next bullet) is still **Leaning/deferred**, and the closure/existential `shared` spellings are **deferred** (no consumer under one compilation unit — `plans/tasks/132-shared-spellings.md`). Full as-built rule + the bound: `generics.md` §7.

- **A type's shareability is auto-derived structurally — built (M5 5.3.1).** Zero annotation. Implemented rule: primitives and **`String`** (immutable) are shareable; a value type (`struct`/`enum`) is shareable iff every stored field is; a **class is shareable only when deeply immutable** — every field `let`, recursively, and itself shareable; an **actor handle** is shareable; a **closure** is shareable iff its captures are. **Conditional conformance** falls out of the same check: a generic instance `Box<T>` is shareable iff its type arguments are. — **Decided; built.**
- **A function's *requirement* that a parameter be shareable is inferred bottom-up** from visible bodies: a body that forwards a value across a task boundary (spawn / channel / actor message) requires it shareable; the requirement propagates up through cached per-function summaries; callers discharge it. Module-internal code carries no annotation. Simpler than the retired ARC-era analysis — a boolean per parameter, no regions. — **Leaning; not yet built** (M5 ships the explicit `<shared T>` bound instead; this inference is the ergonomic follow-up that keeps `shared` unwritten for visible bodies). **Direction affirmed** (`plans/tasks/100-modules.md`): pursue the inference — no `shared` annotation on visible bodies — to hold the "programmers don't annotate memory" tenant, accepting its parallelism cost. Because it is a caller-relevant fact inferred from bodies, it forces a call-graph fixpoint before intra-module body-checking can run in parallel (the same reason the `mutating` keyword is being left out, `types.md`); type shareability, being structural, has no such cost. Revisit only if measured parallelization after modules land makes the fixpoint worth trading the tenant for.
- **Three boundaries where inference can't read a body:**
  1. **Public API (separate compilation)** — inferred at library-compile time and **materialized into the module's compiled interface** (binary now, textual option later). No human annotation.
  2. **Stored / forwarded function values** — reduce to "shareable is part of the function *type*"; inferred + materialized as in #1.
  3. **Dynamic dispatch (interface requirements, `any`)** — no body, open conformer set → the requirement is a **contract decision**, expressed as the parameter's *type*. Irreducible.
- **The dynamic-dispatch marker is narrow.** It appears only on **closure (and generic) parameters** an implementation might forward to a task — because a closure's shareability depends on its captures, unknown to the interface. **Concrete reference parameters need no marker** (shareability comes from their own type). Default is un-marked; a conformer that tries to forward a non-shareable closure gets a type error prompting the author to widen the requirement's type. This is Rust's `Send`-on-a-trait-method situation, and not the part of Rust that hurts. — **Decided.**
- **Keyword/spelling — `shared`, a prefix modifier** joining `any`/`some`. — Decided (2026-07-20). **Built (M5 5.3.2):** the declared bound `<shared T>` (`<shared T: Comparable>` combines with an interface bound), discharged at call sites — the type argument must be shareable, and a `shared T` counts as shareable inside the body. **Deferred (no M5 consumer):** the shareable *closure/existential* spellings `shared (A) -> B` and `shared any I` (`plans/tasks/132-shared-spellings.md`). Older text in this doc writing `shareable` predates this. Rationale and full form: `generics.md` §2, §12; it is a capability prefix, not an `&`-composed marker interface (`interfaces.md` §9).

---

## 6. Closures

First-class and central (Swift-style). The GC pivot removes Swift's two closure taxes: **no `[weak self]`** (cycles collect) and **no `@escaping`** (lifetime is automatic).

**Semantics — Decided (2026-07-16):**
- **Reference types**, first-class, sharing a type with named functions. Copying a closure value shares its captured environment.
- **Capture by reference by default** — the closure shares the captured variable's storage and sees later mutations.
- **Granular by-value opt-in** via a capture list; a by-value capture is a **mutable** local copy.
- **Per-iteration loop bindings** — each iteration binds a fresh variable, so by-reference capture in a loop doesn't share one mutating variable (dodges the Go-1.22 footgun from the start).
- **No `[weak]`/`unowned`, no `@escaping`.**
- **Shareability is a local structural check** on the captured environment (treated as a synthesized struct of the captures): a closure is shareable iff its captures are shareable and it holds no shared mutable state. A mutable-capture closure is reference-like → not shareable; snapshot immutably to send. The "can be sent" capability is the shareable bound at signatures (§5).
- **Failability rides in the return type** (errors-as-values) — no `throws`/effect on the function arrow.

**Surface syntax — Decided (2026-07-16), Swift-shaped:**
- Trailing-closure syntax `foo { … }`.
- Shorthand argument names `$0`, `$1`.
- Capture list `{ [x] in … }`, plus a rename/bind form `[y = expr]`.

(These are frontend surface derived from the semantics above; exact spelling stays adjustable later without semantic impact.)

**Parked:**
- **Autoclosures** — kept as an idea; no implementation for now.
- **Shareable-closure type spelling** — decided (2026-07-20): prefix `shared` on the function type, e.g. `shared (Int) -> Bool` (§5, `generics.md` §3a).

**Continuations (Decided 2026-07-16, §3):** the stackful model *decouples* continuations from closures — a continuation is a **fiber resume-token, not a CPS closure** — so it's a narrow runtime concept, not the foundation of control flow. The exposed form (closure-scoped one-shot checked continuation, a runtime intrinsic whose token is a linear type) is decided in §3; the callback closure that captures the token must be **shareable** (it fires on a foreign OS thread), which is resolved by the cross-thread resume contract in `runtime.md` §3.

---

## 7. Cancellation

**Cooperative, by convention, with no concept in the language or the runtime.** A signal is a request to stop, sent over a channel. The function that hears it decides what to do: stop, finish its current item, return a partial result, or ignore it.

- **Nothing is interrupted.** A function ends only by returning. There is no unwinding and no delivery at safepoints. Cancelling every function implicitly would let any function stop midway through an update (Java deprecated `Thread.stop` for this; Rust's "cancel safety" is the same problem), would need shielded cleanup, and would turn each safepoint into a function exit, which limits optimization.
- **A signal first, perhaps an error after.** A closed channel is a signal; nothing has failed. A function that observes it may report that as an ordinary error ([115](../plans/tasks/115-error-handling.md)) or return normally. To the caller it is a normal return either way.
- **Generic signalling.** Go's `context` bundles a stop signal, a deadline and request values for server call chains. That is one convention, so it belongs in a library. A closed channel is the generic signal, and `select` is its receive.
- **Waits.** `select` covers channels, and is intended to cover poller-backed reads and timers too, so a blocked network read can wait on a stop channel. I/O deadlines and closing a connection also wake a blocked read. Blocking file calls and foreign calls run to completion.
- **Compute.** A long loop stops only where its author checks.
- **Request context.** A library class holding a stop channel, a deadline and values, passed as a parameter or held on a request struct, is an ordinary user or library choice.
- **Reach.** Actors are unaffected: a cancelled sender has no bearing on a handler already running.

**Possible later additions.** If programs show the need, a per-fiber flag with explicit observation points can be added without breaking code. Whether a function must declare that it listens stays open; a signature marker belongs on the input side, because a return type describes what a function produces.

---

## 8. Fibers and tasks

Two forms, both taking only a call, with arguments evaluated at the call:

```
fiber f(x)            // detached: a statement, nothing comes back
let t = task f(x)     // joinable: gives a Task
let v = t.join()
```

- **`fiber` is detached and has no left side.** It always means one thing, like Go's `go`. No join exists, so a fiber's record is freed when it exits.
- **Types may be concurrency objects.** `Channel<T>` and `Task<T>` are real stdlib types: objects that do a job, like a file. A type may never mark how other data behaves (`Arc<T>`, `Send`, `Pin`), which keeps memory and concurrency strategy out of data modeling. Both are shareable by a stdlib-only blessing, the trusted escape hatch of §10. There is no `Fiber` type: `fiber f(x)` returns nothing, so it would have no operations.
- **`task` is a keyword over a library type.** `Task` is an ordinary stdlib class over `fiber` and a one-shot channel, so the compiler knows one library name, as `for` knows the iterator protocol. `join()` can repeat and can come from several fibers. A dropped `task` result is rejected in favor of `fiber`.
- **No closures are passed to `fiber` or `task`.** A multi-step body is a named function. Closures in Go mostly return results and signal completion, which `task` covers.
- **Fan-out is an array of tasks and a loop.** A `Group` type waits until programs show which need is common: completion order, stop on first error, or a concurrency limit.
- **`main` returning ends the program.** Detached fibers stop with it. Actor drains finish first: messages already sent are delivered.
- **A fault in any fiber ends the process.**
- **Captures stay checked.** Arguments crossing into a fiber must be shareable (§5).
- **Leaks are a tooling matter.** Detached fibers can leak, so the tools need fiber dumps and leak reports.

**Why detached by default.** Mainstream languages all keep a detached form, because background work and servers need one, and concurrency gains little from novelty here. The languages that forbid it are specialized (Cilk, occam). The earlier design had implicit joins at scope exit and a `spawn let` binding; this replaces both. Task [250](../plans/tasks/250-fiber-task-surface.md) tracks the build, and `fiber let` stays until `Task` exists.

**Residual (§10):** `select` surface and how far it generalizes, and all spellings.

---

## 9. Actor surface (Decided 2026-07-16)

Actors own isolated stateful concurrency (§1); this section pins how you declare and interact with them. Spellings deferred (§10).

- **Declaration & isolation.** An actor is a reference type with isolated state — fields are reachable only from within the actor's own handlers (serial access). External code goes through the actor's message interface; internal helpers called from a handler run inline on the handler's fiber (a direct call, not a message-send). — **Decided (model).**
- **Interaction = method-call syntax, fire-and-forget message-send.** `account.deposit(amount)` reads like a call; underneath it enqueues a message on the actor's mailbox and **returns immediately** — the handler runs later on the actor's turn, and the sender does not wait for it. Handlers **do not return values to the sender**. Legibility comes from the variable's actor type, consistent with the markerless model (§1). — **Decided (fire-and-forget: revised 2026-08-12, was "blocks until the handler returns").**
- **One mechanism, no reply.** Fire-and-forget send is the *only* operation on an actor. There is no reply, no ask, no request-reply, no blocking-call form — not deferred, not a library helper, none. A handler is a one-way message sink. A value produced by concurrent work comes from a `task` (§8) or a channel (§4, flow) — separate mechanisms with their own surfaces, never bolted onto the actor. This is the pure-actor model (Erlang's `!`; a "call"-style convenience is deliberately *not* provided). — **Decided 2026-08-12.**
- **The send is non-blocking.** The mailbox is unbounded to start (a send always succeeds); **bounded-mailbox backpressure** (a send blocks when full, Go-buffered-channel style) is a future option (§10), not the default. — **Decided (revised 2026-08-12).**
- **Consistency with §1 "no implicit concurrency."** A fire-and-forget send leaves the handler running past the send's return, but that is *the actor's* concurrency, not leaked background work in the sender's scope: addressing a named actor is itself the explicit concurrency act, and their work is theirs, reference-driven, not scoped to the caller. So this holds §1 rather than bending it. — **Decided 2026-08-12.**
- **Slow handlers spawn to keep the actor responsive.** A handler that does slow work holds up the actor's drain (the next message waits — non-reentrant), so to stay responsive it **spawns** the work and returns. Since sends never block the sender, this is about the actor's own throughput, not the caller. — **Decided.**
- **Non-reentrant.** A handler runs to completion before the next message, so state is touched serially and invariants hold across the whole handler. A handler that blocks inline (I/O, a `sleep`) serializes the actor deliberately. — **Decided.**
- **Work a handler starts is an ordinary fiber or task.** It runs independently of the actor's drain.
- **Arguments are shareable** — they cross the actor boundary, so the shareability rule requires it (§1, §5). No results ever cross back (handlers don't return to the sender). — **Decided (follows from the shareability rule).**
- **Lifetime & shutdown: pending messages root the actor; drain-then-collect.** A queued message keeps the actor reachable, so "collected when unreferenced-and-idle" means no external references *and* an empty mailbox. An actor with queued work drains it, then becomes collectable (the Swift ARC-driven drain precedent, achieved here via GC reachability). Fire-and-forget survives a sender dropping its reference; actor↔actor cycles with drained mailboxes collect together; a self-sustaining actor lives until program end (programmer-created, like an infinite loop). An explicit stop can offer drain-vs-drop. — **Decided.**

**Implementation model — async mailbox + pooled handler fibers (Decided 2026-08-12).** The runtime that backs this surface is the async, fire-and-forget message-send model above, not a shared lock. Pinned:

- **Message-send, not a mutex.** An actor owns a **mailbox** — an MT-safe FIFO of messages. A send enqueues a message and returns (fire-and-forget); the actor's drain runs the handler later — the sender is never parked. This is what makes fire-and-forget, offload, and non-reentrant run-to-completion expressible. A mutex gives none of them: it runs the handler on the caller's own fiber and deadlocks on re-entry. The M3.4 `{ header, fields…, mu }` mutex actor was a belief-milestone scaffold — now superseded.
- **A capped pool of mailbox fibers, no dedicated per-actor fiber.** An idle actor is just its state + mailbox; it holds no fiber and no OS stack. When a message arrives at an unscheduled actor, its mailbox is marked *scheduled* and appended to a **global scheduled-mailbox queue**. A **program-global pool of mailbox fibers** — reusable, capped in number — pulls mailboxes off that queue and drains each to completion (one mailbox at a time per fiber). A mailbox fiber loops: pull a mailbox, drain it, pull the next; when the queue is empty it parks on a free-list, and it is woken (or a new one is created, up to the cap) when work arrives. The **cap is the point** — a churn of many concurrently-busy actors can't spawn a 128 KiB-stack fiber each; excess mailboxes wait in the queue and a busy fiber picks them up as it frees. Over its life a mailbox is drained by whatever fiber happens to pull it; stacks are warm-reused, never owned by any actor. Serialization and non-reentrancy come from the **single-drain invariant** (a mailbox is *scheduled* — queued or draining — at most once at a time), not a lock; the pool parallelizes *across* actors, never within one. **The scheduled queue is a GC root** (its head is scanned, the `sched_next` links traced), so a scheduled mailbox whose actor is otherwise unreferenced — fire-and-forget outstanding work — stays live until drained rather than being collected mid-flight. Actors don't each own a thread-sized stack; the pool is sized (and bounded) to simultaneously-*busy* actors, not to how many exist. (Erlang/Akka dispatcher precedent.)
- **Ordering: per-sender FIFO.** A single sender's messages to an actor are handled in send order (they enter the one FIFO mailbox in the sender's program order). Cross-sender order — two fibers sending concurrently — is arbitrary, as in every actor system (concurrent sends have no defined order). Ordering and serialization come from the single FIFO mailbox + the single-drain invariant, not from which mailbox fiber does the draining. The drain's empty-check races a concurrent send under the scheduler lock: on seeing the mailbox empty the drainer clears *scheduled*; a send that arrives after that re-appends the mailbox to the scheduled queue, one that arrives before is seen by the in-flight drain — preserving both order and single-drain.
- **An inline-blocking handler holds its mailbox fiber parked** — on whatever it awaits (a timer, I/O); its roots are scanned via the live-fiber registry (6.2.2), like any parked fiber. That fiber is unavailable to drain other mailboxes until the handler completes; other mailboxes wait in the scheduled queue (bounded by the pool cap), so a handler that blocks long throttles actor throughput deliberately.
- **Park protocol: lock-handoff (M6 · 6.4, built).** A parking-heavy concurrency workload surfaced a latent M:N race: a fiber that unlocked the scheduler lock before `swapcontext` finished saving its context could be re-queued by a waker mid-save → SIGBUS / lost-wakeup deadlock. Fixed by holding the single scheduler lock (`rt_queue_mu`) across every fiber↔scheduler switch — the scheduler switches in with the lock held, a fiber releases it only after switch-in and re-acquires it to park, so a fiber becomes wakeable only once its context is fully saved. Applied uniformly to spawn/join, the timer sleep, the I/O poller, and mailbox-fiber parking — hardening the pre-existing park sites too.
- **Teardown falls out of the moving GC.** Actor state and mailbox are ordinary GC objects; pending messages root the actor (drain-then-collect, above). An unreferenced idle actor has no fiber and no mutex — nothing non-GC to release — so it is reclaimed structurally like any object, and actor↔actor cycles collect together. The pool's fiber stacks are runtime-lifetime, not per-actor. This **removes the per-actor weak-handle / `ReferenceGlue` teardown** an earlier design assumed (it rested on a dedicated per-actor fiber stack held through a weak handle; there is none). Built as the M6 actor runtime (2026-08-12).

**Residual (§10):** all spellings (the actor keyword, handler/message declaration, the `stop` form), and whether the mailbox is unbounded or bounded (backpressure). Some rides on generics and the error model.

---

## 10. Open questions (rollup)

- **Primitive exposure** — **Decided (§3):** closure-scoped one-shot checked continuation, a runtime intrinsic (not stdlib), resume-once checked at runtime; raw park/unpark stays internal. Cross-thread resume (`runtime.md` §3) now decided; residual is only the deferred FFI variant + spelling.
- **Channels** — **Decided (§4):** a library type over the suspension core, the base of the concurrency surface (role = flow, distinct from actors); `select` rides the exposed continuation. Residual: the API.
- **Actor surface** — **Decided (§9), fire-and-forget revision 2026-08-12:** one mechanism only — **fire-and-forget** message-send; handlers never return to the sender; no reply/ask/request-reply of any kind (values come from tasks or channels, not actors); non-reentrant; slow handlers start fibers to stay responsive; pending messages root the actor → drain-then-collect. **Implementation model (§9):** async mailbox + pooled on-demand handler fibers (no dedicated per-actor fiber, no mutex); the M3.4 mutex actor is a superseded scaffold; teardown falls out of the moving GC (no per-actor weak handle). Residual: spellings, mailbox bound.
- **Fibers and tasks** — **Decided (§8):** detached `fiber f(x)`, joinable `task f(x)` over a library `Task`, fan-out through arrays. Residual: `select` and spellings.
- **Cancellation** — **Decided (§7):** cooperative, by convention over channels, with no language or runtime concept. Residual: whether a per-fiber flag is ever added.
- **Shared-mutable primitive** — **Deferred (design) 2026-07-16.** The "fourth shareable category" (a self-synchronizing type — atomics, a green `Mutex<T>`) is **reserved but unbuilt**. Adding it later is additive and low-risk: a green mutex rides the existing suspension core, atomics ride intrinsics the runtime already needs internally, and it can't precede generics anyway. The one thing kept open for it is a **trusted (`unsafe`) shareability escape hatch** — a way for a type to declare itself shareable despite mutable interior (Rust's `unsafe impl Sync`), likely exposed to library authors. Actors remain the default for shared mutable state until then. Design deferred; expected eventually.
- **"shareable" details** — spelling decided (2026-07-20): prefix modifier `shared` (§5, `generics.md` §3a).
- **Closures** — surface syntax locked Swift-shaped (§6, frontend-adjustable); autoclosures parked; shareable-closure spelling decided as prefix `shared` (§6).
- **Continuations** — decided: shape (§3, §6), cross-thread resume at the in-runtime tier (`runtime.md` §3), and the cancellation contract (§3). Residual: the deferred **foreign-thread/FFI** variant (`runtime.md` §5) and **surface spelling**. Resume-once is checked at runtime.
- **Scheduler internals** — work-stealing M:N, parallelism knob, stack growth, poller, task-locals, remote-wake primitive, platform/syscall strategy, FFI-readiness. All now homed in `runtime.md`.
