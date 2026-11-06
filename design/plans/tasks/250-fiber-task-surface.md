# Fiber and task surface

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · ready-to-build` · **Size:** L ·
**Status:** 250.1 done; 250.2 waits on [251](251-erased-generic-objects.md) · **Source:** the concurrency surface redesign

**Depends on:** [251](251-erased-generic-objects.md), for 250.2 onward: `Channel<T>` and `Task<T>` are public generic classes.

## What

Detached fibers as the default, with joinable tasks over channels. This replaces `spawn let` and its scope-exit
joins.

## Steps

- **250.1** `fiber f(x)` as a detached statement. A fiber's record is freed at exit, and `main` returning ends
  the program. **Done.** The statement takes a call; arguments and receiver are evaluated at the statement and
  must be shareable (`fiber let` still has no such check). A detached fiber's thunk drops the result, and the
  carrier frees the record when the fiber ends: 2,000,000 fibers peak at 34 MiB. `main` finishing raises the
  stop flag, after actor drains, and the first carrier out of its loop joins the GC coordinator, writes the GC
  report and calls `exit` (`rtSchedFinish`, `Runtime.exit`); nothing joins carriers, which may be in a running
  fiber. The coordinator skips a collection when the stop flag ends its wait for acks. Boot starts the
  coordinator before any second carrier. The active-fiber count is gone. The carrier now clears its
  current-fiber word between fibers. Tests: `fiber-detached`, `fiber-exit-running`, `fiber-not-call`,
  `fiber-not-shareable`. The suite passes plain, at `stack_move=1`, `stack_move_checks=3` and `=1`.
- **250.2** Basic channels: send, receive and close over park/unpark ([102](102-channels.md)).
- **250.3** `Task` in the stdlib over a one-shot channel, and the `task f(x)` keyword over it. Closing the
  channel wakes every joiner, which then read the stored result. The compiler builds the lifted body, as it
  does for `fiber let`, so user-visible closures are not required.
- **250.4** Move the 44 files using `fiber let` to `task`, and remove `fiber let`, its scope-exit joins and
  `spawnJoin`. This completes [104](104-fiber-stack-strategy.md) 104.3.9.
- **250.5** `select` ([135](135-cancellation-continuations.md)), I/O deadlines and close-to-wake on
  connections; `select` over poller-backed reads and timers.
- **250.6** Fiber dumps and leak reports.
- **250.7** Decide whether `fiber` stays as the keyword, after the trial. Rename internal `spawn` names.
- **250.8** Shrink the fiber record, 336 bytes today. 250.4 removes `result`, `joiner`, `registered` and
  `detached` (304). Then `sched`, `carrierCtx`, `entry`, `arg` and `stack need` can move elsewhere, `pool-next`
  can share the run-queue link, and `drainer` can pack with `state` (about 248). Saving the callee-saved
  registers on the fiber's own stack leaves about 88; that changes the context switch and the stack walker, and
  a park then needs 168 more bytes of stack, within the reserve. Measure each change.

## Refs

`concurrency.md` §4, §7, §8; [104](104-fiber-stack-strategy.md) 104.3.9; [103](103-dynamic-spawn-group.md);
[117](117-for-in-iteration.md).
