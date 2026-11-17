# Fiber and task surface

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** L ·
**Status:** done. `task` in compiled-once generic bodies is [251](251-erased-generic-objects.md) 251.2.4; the switch follow-ups are [254](254-scheduler-performance.md) 254.4 · **Source:** the concurrency surface redesign

**Depends on:** [251](251-erased-generic-objects.md), for 250.2 onward: `Channel<T>` and `Task<T>` are public generic classes.

## What

Detached fibers as the default, with joinable tasks over channels. This replaces `spawn let` and its scope-exit
joins.

## Steps

- **250.1** `fiber f(x)` as a detached statement. A fiber's record is freed at exit, and `main` returning ends
  the program. **Done.** The statement takes a call; arguments and receiver are evaluated at the statement and
  must be shareable. A detached fiber's thunk drops the result, and the
  carrier frees the record when the fiber ends: 2,000,000 fibers peak at 34 MiB. `main` finishing raises the
  stop flag, after actor drains, and the first carrier out of its loop joins the GC coordinator, writes the GC
  report and calls `exit` (`rtSchedFinish`, `Runtime.exit`); nothing joins carriers, which may be in a running
  fiber. The coordinator skips a collection when the stop flag ends its wait for acks. Boot starts the
  coordinator before any second carrier. The active-fiber count is gone. The carrier now clears its
  current-fiber word between fibers. Tests: `fiber-detached`, `fiber-exit-running`, `fiber-not-call`,
  `fiber-not-shareable`. The suite passes plain, at `stack_move=1`, `stack_move_checks=3` and `=1`.
- **250.2** Basic channels: [102](102-channels.md), which holds the design and the steps.
- **250.3** `Task` in the stdlib over a one-shot channel, and the `task f(x)` keyword over it. Closing the
  channel wakes every joiner, which then read the stored result. The compiler builds the lifted body, so
  user-visible closures are not required.
  - **250.3.1** The runtime pair and `Task<T>`. **Done.** `Task<T>` is a struct over a channel buffer of capacity
    1, so it is shareable by the structural rule, as `Channel` is; a class holding the result would need the
    trusted shareability escape hatch (`concurrency.md` §10). `rtChanFulfill` stores the value and closes in one
    step under the lock, copying it into every parked waiter's slot; `rtChanAwait` waits for the close and copies
    the value out without taking it. A send followed by a close would hand the value to the first waiter only.
    Tests: `task-library`, `-nursery`, `-stack-move`.
  - **250.3.2** The `task` keyword. **Done.** A prefix expression over a call, binding like the other prefix
    operators: `task f(x).join()` is `task (f(x).join())`. Arguments and receiver are evaluated at the site, as
    for `fiber`; they and the result must be shareable. A call returning nothing gives a `Task<Void>`, `Void` an
    empty stdlib struct. A `task` used as a statement is an error that points to `fiber`. Sema builds the fiber's
    body as NOIR (`taskStart`: the `Task.make()` call, the call, and the `fulfill`), so monomorphization and
    dictionary recipes see the generic calls; the lowerer binds the `Task`, hoists the operands and lifts the
    body through the same path as `fiber`. Runtime-subset code may not start a `task`. Tests: `task-keyword`,
    `-nursery`, `-stack-move`, `task-not-call`, `task-not-shareable`, `task-result-not-shareable`, `task-unused`.
  - **250.3.3** `task` in generic functions. Specialized per use, **done** (`task-generic`). A compiled-once body
    fails with "no size for type parameter 'T'", as `fiber` does there: owned by [251](251-erased-generic-objects.md) 251.2.4.
  - **250.3.4** Verification. **Done.** Full tier 1400/1400; fast tier 514/514 under `stack_move=1` and
    `stack_move_checks=1`; the 30 task, channel, scheduler, fiber and actor cases 50× each plain and 10× with
    stacks moving, all passing.
- **250.4** Move the files using `fiber let` to `task`, and remove `fiber let`, its scope-exit joins and
  `spawnJoin`. This completes [104](104-fiber-stack-strategy.md) 104.3.9. **Done.** 24 fixtures, 7 examples and
  6 benchmarks moved; `fiber let a = f(x)` became `let a = task f(x)` with `a.join()` at each read, and an
  unread binding got an explicit join. `fiber let` now parses to an error that names `task`
  (`fiber-let-removed`). Removed: the AST and NOIR `spawnLet`, SSAIR `spawnJoin` and the spawn binding, the
  lowerer's scope-exit joins, the joinable thunk that boxed a result, `__nomu_spawn_join`, and in the runtime
  `nomuSchedJoin`, the joiner wake, the result-box root in the stack walk and the registry's idempotence flag.
  Every fiber is freed when it ends except `main`, which the scheduler keeps to recognize it. The record's
  `result`, `joiner`, `registered` and `detached` words are unused; 250.8 packs the record. `task` checks its
  arguments' shareability, which `fiber let` did not: three fixtures now make their mutable `Box` on the
  task's side, and `examples/shareability` builds its closure there, since a closure type is not shareable
  until the `shared` closure spelling ([132](132-shared-spellings.md)). The GC cases that count roots each
  gained two per `Task`: one in the joining frame and one in the task's frame, which holds it until it
  stores the result.
- **250.5** `select`, Go's statement (`concurrency.md` §4): receive, send, `after(ms)` and `readLine()` cases
  and `default`; a random pick among ready cases. I/O deadlines and close-to-wake on connections moved to
  [255](255-networking.md), since there are no connections yet.
  - **250.5.1** The runtime: one fiber waiting on several channels. All the channels' locks taken in address
    order while the cases are polled and the waiters queued; the waiters off the stack, sharing a record whose
    claim one waker wins; a waker that loses skips the waiter; a second call after the wake unlinks the losers,
    given the channels' current addresses since the collector may have moved them. **Done**
    (`runtime/channel.nomu`: `rtSelectWait`, `rtSelectDone`). Every waker now takes a waiter through
    `rtChanDequeueLive`, which claims a select's record and drops a waiter whose select another case won, and
    wakes a select's fiber only after taking its record's lock, which the fiber's carrier releases once the
    context is saved. Cases are polled from a random one (a per-carrier xorshift, carrier record +168).
  - **250.5.2** The `select` statement and `default`. Sema rewrites it into runtime calls and a branch on the
    winning case, so no later stage gains a statement. **Done.** `select` is a keyword; `default` is
    recognized only inside it. Codegen stores every slot and channel address into the frame's area just before
    the wait, and the channels again after it as managed pointers, so neither a stack move nor the collector
    leaves one stale. Compiled once, a two-case select gives a frame addressed through a base pointer, which
    the runtime handles since 104.3.11. Tests: `select-basic` (and `-stack-move`),
    `select-stress` (`-nursery`, `-stack-move`), `select-generic` (`-stack-move`), `select-send-closed`,
    `select-empty`, `select-not-channel`, `select-send-binding`, `select-two-defaults`.
  - **250.5.3** `after(ms)`: a timer entry that takes part in the claim, removed when another case wins.
    **Done.** The entry holds the select waiter with its low bit set; the timer thread claims under the timer
    lock, and `rtSelectDone` removes an unfired entry under it. `after(0)` is ready at once. Tests:
    `select-after` (and `-stack-move`), which also checks the timer heap is empty after 2000 lost timers.
  - **250.5.4** `readLine()`: a stdin waiter that takes part in the claim. **Done.** A buffered line, or one
    stdin can give without waiting, makes the case ready; otherwise the select's waiter joins the stdin list
    and the poller claims it. Once woken, the fiber reads its line as `readLine` does, which can wait again if
    another reader took the line. Tests: `select-read-line` (and `-stack-move`).
  - **250.5.5** Verification. **Done.** Full tier 1417/1417; fast tier 531/531 under `stack_move=1`,
    `stack_move_checks=1` and `=3`; the select, task, channel, scheduler, fiber, actor, stdin and STW cases 30×
    each plain and 10× with stacks moving, all passing.
- **250.6** Fiber dumps and leak reports, matching current Go: goroutine dumps with wait reasons, SIGQUIT,
  the deadlock error, and the experimental goroutine-leak profile of Go 1.26.
  - **250.6.1** Fiber IDs and wait reasons. **Done.** Each fiber gets an ID at spawn (fib+216, from the counter
    at sched+32); a parking fiber records its reason (fib+224: chan receive, chan send, select, task join, sleep,
    IO wait) and what it waits on (fib+280: the channel's buffer, or the select's record, which lists its case
    channels). The wait's start (fib+328) is set by the first collection that finds the fiber parked.
  - **250.6.2** Dumps, in Go's format. **Done.** `fiber 7 [chan receive, 2 minutes]:`, then the frames from the
    frame the fiber parked in (`rtFiberDump`, `runtime/fault.nomu`), read from the registry without its lock as
    Go reads goroutines. SIGQUIT dumps every fiber and exits with status 2; the runtime unblocks SIGQUIT at
    startup, since a parent's blocked mask is inherited. `NOMU_TRACEBACK=all` adds the dump to a fault's report.
    `nomu run` symbolizes each fiber's frames under its header, whatever the exit status. Tests: `fiber-sigquit`,
    `fiber-traceback-all`.
  - **250.6.3** Deadlock. **Done.** The last carrier to go idle checks that no fiber is running or runnable, at
    least one is parked, and nothing can wake one (no timer, stdin waiter, actor work, collection, stop or exit);
    it confirms over a 100 ms wait with no wake, then the carrier that claims the exit prints "fatal error: all
    fibers are asleep - deadlock!" and a dump and exits with status 2. Tests: `fiber-deadlock`,
    `fiber-no-deadlock`. The harness gained `expect.exit_code`.
  - **250.6.4** Leak report. **Done** (`runtime/leak.nomu`). `NOMU_LEAK_REPORT=1`: when `main` returns, its fiber
    stops the world as an out-of-memory collection's requester does; the coordinator collects, then marks from
    the roots that can run into a set of its own, adds each blocked fiber whose wait object was reached, repeats,
    and reports the rest as `[chan receive (leaked)]`. Wait objects are root slots in collections, so they stay
    current; the collection cases whose `main` joins a task count one root more, and `stw-running` and
    `stw-inlined-loop` now wait for `main` to park before they collect, so their counts are fixed. Tests:
    `fiber-leak` (`-stack-move`), `fiber-no-leak-report`.
  - **250.6.5** Symbolizing outside the program. **Done.** Decided: no stdlib call returns a stack dump, unlike Go's
    `runtime.Stack`, so binaries never carry symbol names; reports keep raw addresses, and a tool names them,
    which is all an agent reading a crash needs. `nomu tool symbolize <binary> [report]` (219's command, for a
    binary at hand) reads a crash report or
    fiber dump (a file, or standard input), checks its build ID against the binary's, and prints it named from
    the binary's dSYM (release builds keep one) or its objects; `nomu run` shares the code. Test:
    `testSymbolizeFiberDump`. Looking debug info up by build ID, for a binary built elsewhere, stays with 219.
  - **250.6.6** Verification. **Done**: full tier 1427/1427; fast tier 541/541 under
    `stack_move=1`, `stack_move_checks=1` and `=3`; the fiber, select, task, channel, scheduler, actor, stdin, STW
    and base-pointer cases 20× each plain and 10× with stacks moving.
- **250.7** Decide whether `fiber` stays as the keyword, after the trial. Rename internal `spawn` names. **Done.**
  `fiber` stays: it pairs with `task`, and the runtime and tooling already say "fiber". "spawn" is gone from
  compiler and runtime names: the SSAIR instruction is `.fiber` (sink `.fiberCapture`), the lifted body
  `fiber:N` with env `fiber.N.env`, mangled `NC<module>[s<index>]5fiber`; the runtime entries are
  `nomuSchedStartFiber` and `rtSchedStartFiberSized`; the value box descriptor is `valuebox`
  (`valueBoxTypeId`). The `shape_matrix` cases `spawn_env` and `spawn_result` are now `task_env` and
  `task_result`. `posix_spawn` and the compiler-test subprocess runner keep the word. The suite passes plain,
  at `stack_move=1`, `stack_move_checks=1` and `=3`.
- **250.8** Shrink the fiber record, 344 bytes today (a 168-byte context and 22 words). The words 250.4 freed
  (216, 224) now hold the ID and wait reason, and 280 and 328 the wait object and wait start, so every saving
  moves or packs a live field. No change may cost runtime performance; a change that trades for complexity is
  agreed first. Order: 250.8.1, then the 104.3.10 decision (it may move the fiber pointer out of x28, which
  250.8.2 rewrites), then 250.8.2. Measure each step with 250.8.3's measures.
  - **250.8.1** Move or pack fields; the context switch is unchanged. 344 → 288 (malloc's 288 bin; 352 before).
    **Done.** The layout is in `runtime/scheduler.nomu`'s "Fiber" comment.
    - `entry` and `sched` seed the fresh context's x21 and x22 slots (16, 24); each is read once, at start.
      Reading the `rtSched` global there instead trips an LLVM assertion in the debug config
      (`RewriteStatepointsForGC`, "support for FCA unimplemented"): a runtime global read in a function with
      statepoints. The slot needs no global and costs nothing.
    - `release` and `stack need` live in two words after each carrier's context buffer (168 → 184 bytes,
      `rtSchedCarrierCtxNew`). The parking fiber already loads `carrierCtx`; `rtStackMove` takes `need` as an
      argument.
    - `pool-next` shares the run-queue link (176): a pooled mailbox fiber is idle, and every readying targets a
      fiber parked on that event.
    - `drainer` and the wait reason are bytes 169 and 170 of the `state` word. Every access is a byte load or
      store, so no access gains a mask. Two fixtures read `main`'s state (`stw_running`, `gc_smoke_t6`) and
      now read the byte.
    - The four words past 280 moved into the freed slots: shadow-top 184, stack limit 200 (`StackChecks.cpp`,
      `runtimeSizedBuffer`), stack size 224 (the libc stubs in `rtasm_arm64.s`), wait start 256.
    - Kept: `carrierCtx` (moving it to the carrier record adds a thread-local lookup to every park);
      `stackBase` (`stack_move_checks` sets the limit to -1, so the base cannot be derived from it; the libc
      stubs read it too).
    - Measured against the old layout. `benchmarks/parked_fibers` (200,000 fibers parked at once): peak RSS
      498.8 → 485.0 MB, 69 bytes less per fiber. `forkjoin_fiber`: 250.5 → 242.2 ns/fiber at 1 carrier,
      494.3 → 477.2 at 4. `pingpong_actor` unchanged. `pingpong_fiber` and `pingpong_channel` read 0.2 to 0.6
      ns/hop slower (under 1%); an unused function added to the runtime, which the link strips, moved the same
      numbers by +0.5 (channel) and +3 ns (fiber, 4 carriers), so the difference is within code-layout noise.
      Moving the release word back into the record, the stack limit to its own word, and 64-byte alignment
      each left it unchanged.
  - **250.8.2** Save the callee-saved registers on the fiber's own stack; the record keeps the saved sp.
    288 → 128. Changes `rtSwitch`, `rtFiberInit`, the parked-fiber walk (x19 for base-pointer frames) and the
    mover (the saved fp and x19). A park needs 168 more bytes of stack, within the reserve.
    **Done.** The layout is in `runtime/scheduler.nomu`'s "Fiber" comment.
    - A context is one word, the saved SP. `rtSwitch` pushes x19–x28, fp, lr and d8–d15 at it, in a 224-byte
      block whose last 64 bytes are unused, so the saved set never shares a cache line with the switching
      frame: a sender on another core writes the parked receiver's waiter there, and sharing the line cost
      about 0.5 ns a hop in the four-carrier channel ping-pong. The restore loads the target's SP first, before
      the stores, reads the registers through x10 and sets SP last: loading through SP right after setting it
      cost about 6 ns a switch.
    - The carrier keeps no context of its own. Switching a fiber in, it saves its SP in the fiber's record
      (`fib+72`), which the fiber switches back through: the same chain of loads as 250.8.1's carrier context,
      and the libc stubs read it with one load less. The switch hands a message across in a register
      (`Runtime.ctxSwitch(from:to:message:)` returns the one its resumer passed): the mutex a parking fiber's
      carrier releases (`nomuSchedParkReleasing`), or a stack check's need as `-(need + 1)`. The carrier tests
      the message before anything else and releases the mutex first, since a waker waits on it; reading the
      fiber's state ahead of the release cost about 1 ns a hop.
    - Every field moved down 160 (state 8, next-link 16, shadow-top 24, arg 32, stack limit 40, …, wait object
      120); the record is 64-byte aligned, so its two lines are fixed.
    - A fresh fiber's registers are seeded at its stack top; the trampoline passes the seeded x21 and x22 as
      the entry's second and third arguments, so `rtSchedFiberMain(fib, sched, entry)` and
      `rtSchedMailboxFiberMain(fib, sched)` read nothing from the record. `Runtime.ofFunc` accepts an entry
      of one to three `RawPtr`s.
    - The stack reserve is 1152 bytes (1024 before): the stack check's slow path ends in a switch, and the
      link's frame check now counts the 224 bytes it pushes (`FrameTable.externalStack`), so the slow path's
      share grows from 256 to 384 and the largest checked frame stays 768. The stop is written out in
      `nomuSchedStackCheck`, so its frame does not depend on the inliner.
    - Found by the stress modes: the leak pass marked every root the walk returned, and a recorded slot can
      hold a stack address (an erased generic's buffer). It read that address's bytes as an object header:
      zeros before, harmlessly, and the seeded registers now. It skips non-heap roots as the collector does
      (`rtIsManaged`, shared with `rtKeepManagedSlots`).
    - Measured against 250.8.1 by paired runs (each sample runs both binaries back to back, order alternating,
      300 pairs per case, from a fresh copy of each binary per sample, with a control of 250.8.1 against
      itself): `ctx_swap` −0.06 to −0.10 ns; `pingpong_fiber` −0.3 to −0.4 (1 carrier) and −0.15 (4);
      `forkjoin_fiber` −3 to −4 ns/fiber (1) and −22 to −24 (4). Peak RSS of `parked_fibers` 485.0 → 446.1 MB
      (195 bytes less per fiber).
    - `pingpong_channel` read 0.06 to 0.9 ns slower by wall clock, varying by session. Hardware counters
      (Instruments CPU Counters, per process and per core type) explain it. All builds mispredict at the same
      rate, about 99% of it the switch's `ret`, and run the same instructions per hop within 1%. On P cores
      250.8.2 takes fewer cycles per hop than 250.8.1 (IPC 3.53 against 3.49); on E cores about 2% more. The
      benchmark thread spends 12–19% of its time on E cores, as macOS places it, and that share decides the
      wall-clock result. Accepted on the P-core result; the E-core gap is 250.8.4.
    - Ruled out on the way: data layout in the record and below the saved registers (four arrangements, none
      moved the cost), code layout (six paddings of each build), and the register message (worth at most
      0.2 ns).
  - **250.8.3** Measures: `tools/schedbench.py` (`forkjoin_fiber`) for start and switch cost; peak memory of
    the 2,000,000-fiber detached run (34 MiB at 250.1); the suite plain and at the stack-move settings.
    **Done.** Start and switch cost are 250.8.2's measurements. The detached run (2,000,000 `fiber work(i)`
    from `main`) peaks at 34 MiB at 4 carriers and at the default count, as at 250.1. At 1 carrier it peaks
    at 4.4 GB: `main` never parks, so every fiber waits with its record and first stack until `main` ends.
    The suite passes 1427/1427, and 541/541 at each stack-move setting.
    Small switch-cost differences are judged on P-core cycles from the counters (265), since wall time mixes
    in E-core time macOS chooses.
  - **250.8.4** The follow-ups from 250.8.2 (the E-core gap, the saved SP passed by value) moved to
    [254](254-scheduler-performance.md) 254.4.

## Dependents

- **[254](254-scheduler-performance.md)** (scheduler performance) waits on this task through 250.8: `Task`, `select`
  and the fiber record change the spawn, join, park and switch paths it tunes.

## Refs

`concurrency.md` §4, §7, §8; [104](104-fiber-stack-strategy.md) 104.3.9; [103](103-dynamic-spawn-group.md);
[117](117-for-in-iteration.md).
