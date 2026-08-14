# Concurrency

**Status:** working draft. The detailed home for Nomu's concurrency model and runtime. Status tags: **Locked**, **Open**, **TODO**.

**API scope:** no concrete API here is committed. Any named or lowercase construct (channels, mutexes, `select`, task spawns, a self-synchronizing type) is **illustrative** until we explicitly agree to it, and each will be pinned as **language** or **standard library** at that point. What is Locked is the *model* and the *runtime primitive shape*, not surface API.

---

## 1. Model (Locked)

- **Colorless.** No function coloring, no `async`/`await` split. Drives an **M:N stackful** runtime — a fiber can suspend anywhere because it has a real stack.
- **No suspension marker (transparent, Go-style).** A blocking call looks like an ordinary call; there is no `await` or other marker showing where a fiber suspends. — **Decided (2026-07-16).**
- **Concurrency is never implicit in your control flow.** Without an explicit spawn/scope construct, your statements run in sequence and nothing you wrote runs overlapping. A call may block — and the runtime freely schedules *other* fibers while it does (poller, work-stealing, thread handoff) — but it never makes your *own* statements run concurrently, and structured concurrency guarantees a call leaks no background work past its return (stronger than Go, where detached goroutines can). This is what carries serial-vs-concurrent legibility without a suspension marker. — **Decided (2026-07-16).**
- **Structured concurrency + actors** as the model. Task lifetime is scoped; actors own isolated stateful concurrency.
- **Race-free by construction (the shareability rule).** Reference types are task-local by default; a value crossing a task boundary must be "shareable" (a value type, an immutable type, an actor handle, or — reserved, design deferred — a self-synchronizing type, §10). Shareability is auto-derived structurally and surfaces only as a bound on the concurrency APIs — Rust's `Send`/`Sync` without the borrow checker.
- **Actors** are owning GC handles with reference-driven lifetime (collected when unreferenced-and-idle). You interact through **one mechanism only: fire-and-forget message-send**, written as a method call (no suspension marker). An actor is a one-way message sink — a handler never returns a value to the sender, and there is no reply/ask/request-reply. To obtain a value produced by concurrent work, use `spawn let` results (§8) or a channel (§4), not an actor. Exact actor-access syntax open (§9). No `weak`, no dangling.

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

**Cancellation — Decided (2026-07-16), against the structured cancellation model (§7).** `withContinuation` is a **cancellation point**: cancellation unparks the fiber with a cancelled outcome, the fiber unwinds, and the in-flight external operation is **abandoned**. **resume-after-cancel is a safe no-op** — the atomic resume-once CAS (`runtime.md` §3) serializes cancellation against a late callback; the loser no-ops, so a callback firing into a gone fiber neither crashes nor corrupts. An optional **`onCancel` hook** (Swift `withTaskCancellationHandler` shape) lets the author tell the external world to stop; it races with `resume` and is serialized by the same token state. A **linear resumed value is consumed even on the no-op path** (its cleanup runs). This rides on the structured cancellation model (§7).

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

## 4. Channels — deferred library type (Decided 2026-07-16)

**Channels are a deferred library type: excluded from the initial language and stdlib surface, and designed so they can be added later as a plain library over the suspension core with no language change.** — **Decided.** "Trivial to include, unexposed to begin."

**Why deferred.** Actors (§9), the scope surface (§8), and the continuation (§3) cover the launch concurrency needs. The continuation already settled the "public suspension primitive" fork — the continuation is the blessed low-level tool, so a channel is one library consumer among many rather than *the* primitive. Channels add flow ergonomics that can arrive later without disruption.

**Role when added: flow.**
- **Actor** = an *addressed, stateful entity* — you send to *that* actor, it serializes messages against private state. Identity-centric (state).
- **Channel** = an *anonymous conduit* — put a value in, whoever is reading takes it; no identity beyond the pipe. Flow-centric (pipelines, fan-out/in, worker pools, streaming, `select`).
- Near-duals: an actor's mailbox is a channel + a loop + private state. Kept role-distinct (state → actor, flow → channel), they are two tools for two jobs — the boundary is documented, not left to taste.

**Addability — basic channels are a pure library.** Send/receive with buffered or unbuffered (rendezvous) capacity is ~30 lines over park/unpark + a wait-list (Rust `mpsc`, Kotlin, C# precedent). Plain methods, no `chan` keyword and no `<-` operator; the colorless model makes them read cleanly — a receive is a plain blocking call, no marker.

**`select` rides the exposed continuation — no runtime addition needed.** Waiting on several channels means "the first ready branch wins, the losers consume nothing." The exposed one-shot continuation (§3) already supplies exactly that: its **atomic resume-once is the claim**. A channel keeps a wait-queue of continuations and does **claim-before-handoff** — a sender tries to `resume` a waiter, and on a lost claim moves to the next, so its value is never given away; a `select` is one continuation registered across several channels' queues. So `select` is a **pure library over the exposed continuation**, the runtime stays single-wait and simple, and this composition doubles as validation of the continuation design. (This supersedes an earlier worry about reserving a runtime multi-wait primitive — the continuation covers it.)

**Residual (§10):** everything about channels is deferred until adopted — buffered/unbuffered API, `select` surface, and all spellings. The commitment now is only that they are a pure library over the exposed suspension primitives (park/unpark internally; the continuation for `select`), so nothing in the runtime or language must change to add them later.

---

## 5. Share analysis (shareable inference)

How the compiler decides which values must be "shareable" (the shareability rule, §1) with minimal annotation.

**Status (M5):** the **structural derivation** and the declared **`<shared T>` bound** are **built** (M5 5.3); the bottom-up *inference* of a shareable requirement (next bullet) is still **Leaning/deferred**, and the closure/existential `shared` spellings are **deferred** (no consumer under one compilation unit — `deferred.md`). Full as-built rule + the bound: `generics.md` §7.

- **A type's shareability is auto-derived structurally — built (M5 5.3.1).** Zero annotation. Implemented rule: primitives and **`String`** (immutable) are shareable; a value type (`struct`/`enum`) is shareable iff every stored field is; a **class is shareable only when deeply immutable** — every field `let`, recursively, and itself shareable; an **actor handle** is shareable; a **closure** is shareable iff its captures are. **Conditional conformance** falls out of the same check: a generic instance `Box<T>` is shareable iff its type arguments are. — **Decided; built.**
- **A function's *requirement* that a parameter be shareable is inferred bottom-up** from visible bodies: a body that forwards a value across a task boundary (spawn / channel / actor message) requires it shareable; the requirement propagates up through cached per-function summaries; callers discharge it. Module-internal code carries no annotation. Simpler than the retired ARC-era analysis — a boolean per parameter, no regions. — **Leaning; not yet built** (M5 ships the explicit `<shared T>` bound instead; this inference is the ergonomic follow-up that keeps `shared` unwritten for visible bodies).
- **Three boundaries where inference can't read a body:**
  1. **Public API (separate compilation)** — inferred at library-compile time and **materialized into the module's compiled interface** (binary now, textual option later). No human annotation.
  2. **Stored / forwarded function values** — reduce to "shareable is part of the function *type*"; inferred + materialized as in #1.
  3. **Dynamic dispatch (interface requirements, `any`)** — no body, open conformer set → the requirement is a **contract decision**, expressed as the parameter's *type*. Irreducible.
- **The dynamic-dispatch marker is narrow.** It appears only on **closure (and generic) parameters** an implementation might forward to a task — because a closure's shareability depends on its captures, unknown to the interface. **Concrete reference parameters need no marker** (shareability comes from their own type). Default is un-marked; a conformer that tries to forward a non-shareable closure gets a type error prompting the author to widen the requirement's type. This is Rust's `Send`-on-a-trait-method situation, and not the part of Rust that hurts. — **Decided.**
- **Keyword/spelling — `shared`, a prefix modifier** joining `any`/`some`. — Decided (2026-07-20). **Built (M5 5.3.2):** the declared bound `<shared T>` (`<shared T: Comparable>` combines with an interface bound), discharged at call sites — the type argument must be shareable, and a `shared T` counts as shareable inside the body. **Deferred (no M5 consumer):** the shareable *closure/existential* spellings `shared (A) -> B` and `shared any I` (`deferred.md`). Older text in this doc writing `shareable` predates this. Rationale and full form: `generics.md` §2, §12; it is a capability prefix, not an `&`-composed marker interface (`interfaces.md` §9).

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

## 7. Cancellation model (Decided 2026-07-16)

The spine is decided; the scope surface is settled in §8, and a few spellings remain residual (§10).

**Keystone — cancellation is not an error.** An error is a *value* describing how an operation failed (propagates via `Result`/`?`, `types.md` §4). Cancellation is a *control signal* to stop work. They are kept distinct: **cancellation is a runtime-level cooperative unwind, separate from errors-as-values** — it tears a fiber's stack down to the cancelled scope running cleanup, but it is **not** a user-catchable exception and **not** a `Result` threaded through signatures. This keeps error handling purely value-based while giving cancellation the automatic unwind it needs, and avoids the Go/Swift conflation (`ctx.Err()` / thrown `CancellationError`).

- **Cooperative, not preemptive.** No forced mid-instruction kill; a fiber unwinds itself at safe points. — **Decided.**
- **Propagation = the structured scope tree.** Cancelling a scope cancels its descendants automatically — no explicit `context` token threaded through calls. Triggers: parent cancelled, a scope deadline/timeout (timer heap, `runtime.md` §2), an explicit `.cancel()`, or a sibling error in a cancel-on-first-error scope. — **Decided.**
- **One cleanup mechanism.** Scope exit runs cleanup whether it is a normal return, an error `?`-return, or a cancellation unwind: the same machinery runs `defer`s (reverse order) and consumes live **linear resources** (files close, locks release, a continuation resume-noop-consumes — `memory-model.md` §6.2). **Cleanup runs shielded** — it cannot itself be cancelled, so releasing a resource can't be interrupted. — **Decided.**
- **Cancellation points = safe points, automatic by default (safepoint-based, hybrid).** Every suspension point (park) is a delivery point — anything that blocks or waits is cancellable for free. CPU-bound loops are covered by placing **safepoints at loop back-edges (plus call sites)** — the same safepoints the moving GC already needs (`compiler.md` §1, `memory-model.md` §3) and which also serve scheduler-preemption/fairness (`runtime.md`). So a cancelled fiber checks a per-fiber flag at each back-edge and unwinds; the check is near-free (a predicted branch, or a guard-page poll). **Most code needs no explicit signal** — automatic coverage is effectively total, since any loop polls on its back-edge and straight-line code between them is finite. Two escape hatches: an explicit **`checkCancellation()` / `isCancelled`** (rare — for a partial result before unwinding, or an unusually long straight-line computation), and a **shield / non-cancellable region** to suppress automatic checks (the same shield the shielded-cleanup rule above uses). — **Decided.**
- **Observation without catching.** No catch-and-resume; a fiber may *observe* cancellation only via `isCancelled` (voluntary, e.g. to return a partial result) and via cleanup / **`onCancel`** hooks (the continuation's `onCancel`, §3, generalizes to a scope-level "run this on cancel"). — **Decided.**
- **Actors sit outside the cancellation tree.** Actors are independent entities with reference-driven lifetime, not nodes in the structured scope tree. Cancelling a fiber that *sent* a message does **not** abort the actor's in-flight handler (that would corrupt actor state); the fire-and-forget send already returned, so there is nothing for the cancelled fiber to unwind on the actor's behalf (§9 — no reply to wait on). — **Decided.** Actor *shutdown* (drain-then-collect) is settled in the actor surface (§9).

**Residual (§10):** the exact **shield** semantics and its interaction with safepoints, scheduler-side propagation of a cancelled scope to its parked children (`runtime.md` §7), and the spellings of `checkCancellation`/`isCancelled`/`shield`/`onCancel`. (The scope surface is settled in §8, actor shutdown in §9.)

---

## 8. Structured concurrency — scope surface (Decided 2026-07-16)

Two shape-specific constructs, **no programmer-visible task/fiber/future handle** (Terminology, `runtime.md`). Structure is decided; spellings and exact join points are residual (§10).

- **Static fan-out — a binding form.** For a fixed, small set of concurrent children with *differently-typed* results: each child is bound to a name; **reading a name joins** (blocks until that child finishes) — no suspension marker (§1), no handle type. This is the common "run these two or three things and combine them" case. — **Decided (structure).**
- **Dynamic fan-out + background workers — a scope/group.** Spawn N children (N dynamic) into a scope; collect their results by **iteration**; the scope **joins all children on exit** (the structured guarantee). Long-lived background workers are the same construct — children that run until the scope ends. — **Decided (structure).**
- **No first-class future/handle.** Neither construct hands back a task handle or future; results are plain values you read (colorless — reading blocks). A future-based single construct was set aside as anti-colorless (a future exists mainly to avoid blocking, which Nomu makes cheap). — **Decided.**
- **Both error modes, per-scope.** A scope chooses **cancel-on-first-error** (fail-fast: the first child error cancels its siblings via the cancellation model §7, and the construct surfaces that error) or **run-to-completion** (collect: every child runs, you get all results including errors). Errors are values (`types.md` §4) — "a child errored" means it returned an error value. — **Decided (both supported).**

Why two constructs rather than one: static fan-out (fixed, heterogeneous, combined by name) and dynamic fan-out (N homogeneous, aggregated) are *different shapes*, not two ways to do the same thing — the same role-split that justifies keeping both actors (state) and channels (flow). A single construct makes the common static case awkward (improvised channels/captures).

**Residual (§10):** all spellings (the binding form, the scope/group, spawn), the exact join points (implicit at block exit vs. explicit), how collected results are typed/ordered, and how the error mode is selected. Some of this rides on generics (`types.md`).

**Sequencing (decided 2026-08-10).** Static fan-out (`spawn let`) ships. The **dynamic fan-out group is built in M8, after cancellation** (`roadmap.md`) — its fail-fast mode rides the structured-cancellation model (§7), and its motivating use (benchmarking highly concurrent workloads) can wait. Confirm the surface (handle-based vs. scoped; join point; error-mode selection) before building.

---

## 9. Actor surface (Decided 2026-07-16)

Actors own isolated stateful concurrency (§1); this section pins how you declare and interact with them. Spellings deferred (§10).

- **Declaration & isolation.** An actor is a reference type with isolated state — fields are reachable only from within the actor's own handlers (serial access). External code goes through the actor's message interface; internal helpers called from a handler run inline on the handler's fiber (a direct call, not a message-send). — **Decided (model).**
- **Interaction = method-call syntax, fire-and-forget message-send.** `account.deposit(amount)` reads like a call; underneath it enqueues a message on the actor's mailbox and **returns immediately** — the handler runs later on the actor's turn, and the sender does not wait for it. Handlers **do not return values to the sender**. Legibility comes from the variable's actor type, consistent with the markerless model (§1). — **Decided (fire-and-forget: revised 2026-08-12, was "blocks until the handler returns").**
- **One mechanism, no reply.** Fire-and-forget send is the *only* operation on an actor. There is no reply, no ask, no request-reply, no blocking-call form — not deferred, not a library helper, none. A handler is a one-way message sink. A value produced by concurrent work comes from `spawn let` results (§8, task parallelism) or a channel (§4, flow) — separate mechanisms with their own surfaces, never bolted onto the actor. This is the pure-actor model (Erlang's `!`; a "call"-style convenience is deliberately *not* provided). — **Decided 2026-08-12.**
- **The send is non-blocking.** The mailbox is unbounded to start (a send always succeeds); **bounded-mailbox backpressure** (a send blocks when full, Go-buffered-channel style) is a future option (§10), not the default. — **Decided (revised 2026-08-12).**
- **Consistency with §1 "no implicit concurrency."** A fire-and-forget send leaves the handler running past the send's return, but that is *the actor's* concurrency, not leaked background work in the sender's scope: addressing a named actor is itself the explicit concurrency act, and actors sit outside the structured scope tree (§7, §9) — their work is theirs, reference-driven, not scoped to the caller. So this holds §1 rather than bending it. — **Decided 2026-08-12.**
- **Slow handlers spawn to keep the actor responsive.** A handler that does slow work holds up the actor's drain (the next message waits — non-reentrant), so to stay responsive it **spawns** the work and returns. Since sends never block the sender, this is about the actor's own throughput, not the caller. — **Decided.**
- **Non-reentrant.** A handler runs to completion before the next message, so state is touched serially and invariants hold across the whole handler. A handler that blocks inline (I/O, a `sleep`) serializes the actor deliberately. — **Decided.**
- **An actor is a structured scope** for work its handlers spawn — that work lives with the actor and is drained/cancelled on shutdown. Consistent with actors being their own tree root, outside the caller's cancellation tree (§7). — **Decided.**
- **Arguments are shareable** — they cross the actor boundary, so the shareability rule requires it (§1, §5). No results ever cross back (handlers don't return to the sender). — **Decided (follows from the shareability rule).**
- **Lifetime & shutdown: pending messages root the actor; drain-then-collect.** A queued message keeps the actor reachable, so "collected when unreferenced-and-idle" means no external references *and* an empty mailbox. An actor with queued work drains it, then becomes collectable (the Swift ARC-driven drain precedent, achieved here via GC reachability). Fire-and-forget survives a sender dropping its reference; actor↔actor cycles with drained mailboxes collect together; a self-sustaining actor lives until program end (programmer-created, like an infinite loop). An explicit stop can offer drain-vs-drop. — **Decided.**

**Implementation model — async mailbox + pooled handler fibers (Decided 2026-08-12).** The runtime that backs this surface is the async, fire-and-forget message-send model above, not a shared lock. Pinned:

- **Message-send, not a mutex.** An actor owns a **mailbox** — an MT-safe FIFO of messages. A send enqueues a message and returns (fire-and-forget); the actor's drain runs the handler later — the sender is never parked. This is what makes fire-and-forget, offload, and non-reentrant run-to-completion expressible. A mutex gives none of them: it runs the handler on the caller's own fiber and deadlocks on re-entry. The M3.4 `{ header, fields…, mu }` mutex actor was a belief-milestone scaffold — now superseded.
- **A capped pool of mailbox fibers, no dedicated per-actor fiber.** An idle actor is just its state + mailbox; it holds no fiber and no OS stack. When a message arrives at an unscheduled actor, its mailbox is marked *scheduled* and appended to a **global scheduled-mailbox queue**. A **program-global pool of mailbox fibers** — reusable, capped in number — pulls mailboxes off that queue and drains each to completion (one mailbox at a time per fiber). A mailbox fiber loops: pull a mailbox, drain it, pull the next; when the queue is empty it parks on a free-list, and it is woken (or a new one is created, up to the cap) when work arrives. The **cap is the point** — a churn of many concurrently-busy actors can't spawn a 128 KiB-stack fiber each; excess mailboxes wait in the queue and a busy fiber picks them up as it frees. Over its life a mailbox is drained by whatever fiber happens to pull it; stacks are warm-reused, never owned by any actor. Serialization and non-reentrancy come from the **single-drain invariant** (a mailbox is *scheduled* — queued or draining — at most once at a time), not a lock; the pool parallelizes *across* actors, never within one. **The scheduled queue is a GC root** (its head is scanned, the `sched_next` links traced), so a scheduled mailbox whose actor is otherwise unreferenced — fire-and-forget outstanding work — stays live until drained rather than being collected mid-flight. Actors don't each own a thread-sized stack; the pool is sized (and bounded) to simultaneously-*busy* actors, not to how many exist. (Erlang/Akka dispatcher precedent.)
- **Ordering: per-sender FIFO.** A single sender's messages to an actor are handled in send order (they enter the one FIFO mailbox in the sender's program order). Cross-sender order — two fibers sending concurrently — is arbitrary, as in every actor system (concurrent sends have no defined order). Ordering and serialization come from the single FIFO mailbox + the single-drain invariant, not from which mailbox fiber does the draining. The drain's empty-check races a concurrent send under the scheduler lock: on seeing the mailbox empty the drainer clears *scheduled*; a send that arrives after that re-appends the mailbox to the scheduled queue, one that arrives before is seen by the in-flight drain — preserving both order and single-drain.
- **An inline-blocking handler holds its mailbox fiber parked** — on whatever it awaits (a timer, I/O); its roots are scanned via the live-fiber registry (6.2.2), like any parked fiber. That fiber is unavailable to drain other mailboxes until the handler completes; other mailboxes wait in the scheduled queue (bounded by the pool cap), so a handler that blocks long throttles actor throughput deliberately.
- **Park protocol: lock-handoff (M6 · 6.4, built).** A parking-heavy concurrency workload surfaced a latent M:N race: a fiber that unlocked the scheduler lock before `swapcontext` finished saving its context could be re-queued by a waker mid-save → SIGBUS / lost-wakeup deadlock. Fixed by holding the single scheduler lock (`rt_queue_mu`) across every fiber↔scheduler switch — the scheduler switches in with the lock held, a fiber releases it only after switch-in and re-acquires it to park, so a fiber becomes wakeable only once its context is fully saved. Applied uniformly to spawn/join, the timer sleep, the I/O poller, and mailbox-fiber parking — hardening the pre-existing park sites too.
- **Teardown falls out of the moving GC.** Actor state and mailbox are ordinary GC objects; pending messages root the actor (drain-then-collect, above). An unreferenced idle actor has no fiber and no mutex — nothing non-GC to release — so it is reclaimed structurally like any object, and actor↔actor cycles collect together. The pool's fiber stacks are runtime-lifetime, not per-actor. This **removes the per-actor weak-handle / `ReferenceGlue` teardown** that `m6-spec.md` §6.4 / §6.0.5 assumed (those rested on a dedicated per-actor fiber stack held through a weak handle; there is none).

**Residual (§10):** all spellings (the actor keyword, handler/message declaration, the `stop` form), and whether the mailbox is unbounded or bounded (backpressure). Some rides on generics and the error model.

---

## 10. Open questions (rollup)

- **Primitive exposure** — **Decided (§3):** closure-scoped one-shot checked continuation, a runtime intrinsic (not stdlib), token is a linear type; raw park/unpark stays internal. Cross-thread resume (`runtime.md` §3) and cancellation (§7) now decided; residual is only the deferred FFI variant + spelling.
- **Channels** — **Decided (§4):** deferred library type — unexposed at launch, a pure library over the suspension core (role = flow, distinct from actors); `select` rides the exposed continuation, so no runtime addition. Residual: the API when adopted.
- **Actor surface** — **Decided (§9), fire-and-forget revision 2026-08-12:** one mechanism only — **fire-and-forget** message-send; handlers never return to the sender; no reply/ask/request-reply of any kind (values come from `spawn let` results or channels, not actors); non-reentrant; slow handlers spawn to stay responsive; actor is a scope for spawned work; pending messages root the actor → drain-then-collect. **Implementation model (§9):** async mailbox + pooled on-demand handler fibers (no dedicated per-actor fiber, no mutex); the M3.4 mutex actor is a superseded scaffold; teardown falls out of the moving GC (no per-actor weak handle). Residual: spellings, mailbox bound.
- **Structured concurrency surface** — **structure Decided (§8):** a binding form for static fan-out + a scope/group for dynamic + background; no handle type; both error modes (fail-fast / collect). Residual: spellings, exact join points, result typing/ordering.
- **Cancellation model** — **spine Decided (§7):** cancellation ≠ error, a cooperative runtime unwind; structured-tree propagation; unified shielded cleanup; safepoint-automatic cancellation points; actors outside the tree. Residual: shield semantics, actor shutdown, scheduler-side propagation (`runtime.md` §7), and spellings.
- **Shared-mutable primitive** — **Deferred (design) 2026-07-16.** The "fourth shareable category" (a self-synchronizing type — atomics, a green `Mutex<T>`) is **reserved but unbuilt**. Adding it later is additive and low-risk: a green mutex rides the existing suspension core, atomics ride intrinsics the runtime already needs internally, and it can't precede generics anyway. The one thing kept open for it is a **trusted (`unsafe`) shareability escape hatch** — a way for a type to declare itself shareable despite mutable interior (Rust's `unsafe impl Sync`), likely exposed to library authors. Actors remain the default for shared mutable state until then. Design deferred; expected eventually.
- **"shareable" details** — spelling decided (2026-07-20): prefix modifier `shared` (§5, `generics.md` §3a).
- **Closures** — surface syntax locked Swift-shaped (§6, frontend-adjustable); autoclosures parked; shareable-closure spelling decided as prefix `shared` (§6).
- **Continuations** — decided: shape (§3, §6), cross-thread resume at the in-runtime tier (`runtime.md` §3), and the cancellation contract (§3). Residual: the deferred **foreign-thread/FFI** variant (`runtime.md` §5) and **surface spelling**. The cancellation contract assumes the structured (scope-tree) cancellation model (§7).
- **Scheduler internals** — work-stealing M:N, parallelism knob, stack growth, poller, task-locals, remote-wake primitive, platform/syscall strategy, FFI-readiness. All now homed in `runtime.md`.
