# Actor follow-ups — shareable message arguments, and the send path's cost

**Avenue:** Risk (correctness, perf) · **Type/Lifecycle:** `sema · runtime · actors` · **Size:** M ·
**Status:** 261.1 ready to build; the rest to measure ·
**Source:** found while checking the removal of the value-type rule ([260](260-enum-layout.md).1): a
mutable class object can be sent to an actor handler.

## Today

- **Message arguments are not checked for shareability.** `concurrency.md` names an actor message as a
  task boundary, where a value must be shareable (a class only when deeply immutable). A `task` argument is
  checked (`NOIRGen`, "type 'Pair' is not shareable, so it cannot be passed to a 'task'"); a handler
  argument is not, so `on take(b: Box)` with `class Box { var v: Int }` compiles, and the sender and the
  actor then share a mutable object across fibers.
- **A send allocates a message.** Each handler call builds a managed message object `{ header, next,
  thunk, self, args… }` (`llvmgen/LLVMGenActor.swift`), enqueues it on the receiver's mailbox, and a pooled
  mailbox fiber drains it, calling each message's per-handler thunk indirectly.
- **[106](106-actor-fiber-aware-mutex.md) looks stale.** It replaces a `pthread_mutex_t` in actor
  objects; no such mutex appears in the actor codegen or the runtime now.

## Work

- **261.1** Check actor message arguments for shareability, as `task` arguments are, with the same
  diagnostic. Cases: a mutable class argument is an error; a struct holding one is an error; a deeply
  immutable class, an actor handle and plain values are accepted.
- **261.2** Confirm 106 is obsolete (the mailbox model replaced the mutex) and close it, or record what
  remains.
- **261.3** Measure the send path against Go channels and goroutines: the message allocation per send,
  the indirect thunk call, and the mailbox's enqueue and drain. Candidates once measured: messages
  allocated fiber-locally or pooled when they do not outlive the drain, and a direct call for a handler
  known at the send site.

## Refs

`design/internals/concurrency.md` (shareability, actor messages), `frontend/sema/sources/gen/Shareability.swift`,
`frontend/sema/sources/gen/NOIRGen.swift` (the `task` checks), `llvmgen/LLVMGenActor.swift`,
[106](106-actor-fiber-aware-mutex.md), [105](105-concurrency-hardening.md) (property tests for shareability
at task boundaries), [254](254-scheduler-performance.md).
