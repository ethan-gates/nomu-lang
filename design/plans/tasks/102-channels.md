# Channels

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · done` · **Size:** M ·
**Status:** done; fan-in on several carriers trails Go because of the scheduler (102.6), which is [235](235-scheduler-run-queues.md)'s; it is [250](250-fiber-task-surface.md) 250.2, the base of the concurrency surface · **Source:** `concurrency.md` §4 (channels as a deferred library)

## What

The channels library — typed communication between fibers/tasks on the M:N runtime. Part of the concurrency-completion set.

## Why now

`Task` is written over a one-shot channel, and stop signals are closed channels (`concurrency.md` §7, §8),
so channels come first in the concurrency surface. Channels implement the iteration protocol
([117](117-for-in-iteration.md)).

## Dependencies & triggers

- **Ready:** M:N scheduler, poller, park/unpark, async actor runtime.
- **Interacts with:** `select`, intended to cover poller-backed reads and timers as well (`concurrency.md`
  §7), and shareability (values crossing a channel are a task boundary — the
  shareability rule applies).

## How

`concurrency.md` §4 holds the design:
- An untyped runtime core (`runtime/channel.nomu`): the lock, the waiter queues, a ring of elements stepped by the
  value witness's size, park and wake, and the close state.
- `Channel<shared T>` in the prelude, a struct whose one field is the channel's `ManagedBuffer`, calling the core
  through three builtins only the stdlib can name.
- `make(capacity:)`, `send`, `receive() -> Option<T>`, `close()`; send on closed and double close fault.

## Steps

- **102.1** The core and `Channel<T>`. **Done.**
  - **Layout.** A channel is a `ManagedBuffer<ChannelState, ChannelSlot<T>>` (both types in `core`): the state is
    the header, and the ring the elements. The collector scans and moves it as any buffer, and a fresh, zeroed
    buffer is an open, empty channel. `ChannelSlot<T>` wraps `T` in a struct, so the stride is whole 8-byte slots
    and equals the value witness's size, `UInt8` included. `rawStride` gave every struct and `String` 8 bytes, so it
    now gives their whole slots, which also fixes `Ptr<T>` and buffers of structs.
  - **Builtins.** `channelSend`, `channelReceive` and `channelClose` are methods on that `ManagedBuffer`; `core` is
    importable only from `std`, so only the stdlib reaches them. Each lowers to a runtime call taking the buffer,
    the value's address, its value witness (from the dictionary when compiled once) and a waiter in the caller's
    frame, so no operation allocates. `receive` hands the runtime the payload of a zeroed `Option<T>` and sets the
    tag from its result, in both modes.
  - **Compiled once.** Creating the buffer is a recipe's `object` need, filled with the buffer descriptor of the
    caller's instantiation; the body sizes it from the witnesses (`lowerErasedManagedBufferAlloc`).
  - **Parking.** The waker does all the work: it copies to or from the parked waiter's slot, sets the result and
    readies it, so the parked fiber never touches the channel again and the channel may move meanwhile. The
    waiter's slot is rooted through the fiber's shadow list while parked, since the stack maps record neither a
    destination not yet written nor a source already passed. The stack may move at the resume, after the copy, so
    the core finds its waiter again by its offset from the stack's top. A receive clears a buffer slot when `T`
    holds references; a send into the buffer remembers the channel for the next minor collection.
  - **Descriptors.** A value-layout descriptor is now kind 3, apart from a fixed object's kind 0. The prelude's
    compiled-once code made one of 8 bytes, which `rtCheckPayloadWord`, the check that every heap object has a
    payload word, took for an object.
  - Tests: `channel_values` in the stack-move matrix (two senders on buffered and rendezvous channels, struct values,
    receivers parked at close; 36 legs); `channel-local`, a channel declared over the builtins in the user's module,
    so its methods are specialized, in debug and release with moves and collections; both on four carriers, 30 of 30
    repeats; the three faults. The prelude's `Channel` is always compiled once from user code, even with
    `--config=mono_all`, since methods on generic types do not ship for specialization (253.4.3).
- **102.1.1** Enforce `<shared T>` on types. **Done.** It was parsed on any generic parameter list but checked only
  when a function call inferred its arguments, so `Box<Mut>` for `class Box<shared T>` compiled. Now every
  instantiation is checked (`Sema.checkSharedTypeArgs`): written in a type, written on a construction or static
  call (`Box<Mut>.make(…)`), and inferred at construction. Written types are checked while a declaration lowers,
  where its own `shared` parameters are known. A type parameter passes only when it is `shared` itself, bare or
  nested (`Box<Option<U>>`). Tests: `shared-type-arg` and four error cases.
- **102.2** A park that holds only the channel's lock. **Done.** `rtChanPark` took the global scheduler lock while
  holding the channel's, so with the scheduler lock contended a parker slept holding the channel's lock, and
  every sender queued behind it in the kernel. Now `nomuSchedParkReleasing` parks holding only the channel's
  lock, and the carrier releases it once the fiber's context is saved (`rtSchedSwitchedBack`), as Go's `gopark`
  does with its unlock function. The carrier still takes the scheduler lock to pick its next fiber, so a park
  takes it once either way; what changes is that the channel's lock is never held while anyone waits for it. A
  mailbox fiber keeps the old order, since its drainer bookkeeping needs it still parked. The fiber record grows
  a word, to 344 bytes. In the fan-in profile on 8 carriers, senders' waits on the channel's lock fell from about
  2,800 samples to 290; fan-in went from 122.7 to 102.5 ns per value, with one carrier unchanged. Test:
  `channel-actor`, handlers parked on channels, on 1 and 4 carriers.
- **102.3** Direct handoff. **Done** in 102.1, for every capacity: a sender gives its value straight to a parked
  receiver, a receiver takes a parked sender's value, and on a full buffer the freed place takes the parked sender's
  value. The channel's queues hold raw addresses into parked fibers' frames, so
  [104](104-fiber-stack-strategy.md) 104.4's shrinking must skip a fiber parked on a channel, as Go's
  `activeStackChans` does, or fix those addresses. A move at the resume is safe: the waker is done by then.
- **102.4** Measure. **Done.** Benchmarks `pingpong_channel`, `stream_channel` and `fanin_channel`, each with a Go
  counterpart in `tools/pingpong.py`. ns per hop or value, best of 7, default build:

  | | 1 carrier | 2 | 4 | 8 |
  |---|---:|---:|---:|---:|
  | `pingpong_channel` (unbuffered) | 48.5 | 53.0 | 67.0 | 70.0 |
  | `go chan` | 85.5 | 82.9 | 100.3 | 100.7 |
  | `stream_channel` (buffered 64) | 21.9 | 23.0 | 25.0 | 29.0 |
  | `go stream` | 21.2 | 26.8 | 27.6 | 29.3 |
  | `fanin_channel` (4 senders, 64) | 21.9 | 58.4 | 33.4 | 103.9 |
  | `go fanin` | 21.2 | 32.8 | 53.3 | 55.6 |

  Faster than Go's channels one to one, even with Go streaming, and slower in fan-in on several carriers, where
  the fan-in rows vary from run to run. The profile puts what remains in the scheduler lock: carriers waiting
  for it after a switch, and wakes readying fibers under it. That is [235](235-scheduler-run-queues.md)'s
  per-carrier run queues, which also serve actors and joins; the evidence is recorded there.
- **102.5** Decided on the measurements. **Done.**
  - A lock-free ring: not needed. Go's channels use a lock too, and after 102.2 the channel's lock accounts for
    little of the fan-in profile.
  - Spinning before sleeping on the channel's lock: kept (`rtChanLock`, 128 tries). It changed nothing measurable
    alone, and costs nothing uncontended.
  - Padding the state's words apart: no. Senders and receivers each write the lock and the count, so they share
    the line whatever the layout, as in Go.
  - A fixed-size copy for a specialized `T` by inlining the core's fast path: needs the prelude's `Channel`
    specialized, so it moves to 253.4.3.
  - Several waiters per fiber for `select`: with `select`, in [250](250-fiber-task-surface.md) 250.5. The
    caller's frame can hold them.

- **102.6** Why fan-in trails Go on several carriers. **Done:** understood; the fix is 235's. Counted in a
  build with event counters, 4 senders and 1 receiver, 4M values:
  - Parks are rare: senders park on a full buffer 0.07 times per value, and each park is one handoff.
  - With 128 tries, 4.7% of acquisitions of the channel's lock gave up spinning and slept (187,554 on 4
    carriers), and each sleep costs a system call on both sides. Spinning 2,000 to 20,000 times removes the
    sleeps but not the time: fan-in stays 80 to 120 ns per value, since the lock's cache line still moves
    between cores on every operation.
  - The single receiver is the bottleneck, and it pays for the scheduler on its own path: readying a parked
    sender takes the scheduler lock, which the senders' carriers hold while they pick after a park (the
    largest wait in the profile, `rtSchedSwitchedBack`), and each readying may wake an idle carrier with a
    futex system call (80,000 to 130,000 per run).
  - The rows are bimodal from run to run (2 carriers: 40.5 in one run, 107.6 in the next), as fibers land on
    the same or on different carriers.

  The channel itself is at parity with Go on one carrier and in streaming. Beating Go on fan-in needs a
  readying that takes no global lock and wakes a carrier only when one is needed, which is
  [235](235-scheduler-run-queues.md), where these numbers are recorded.

## Notes

`Channel` is shareable with no blessing because `ManagedBuffer` has no fields;
[181](181-array-managed-buffer.md) records what that means for `Array`.

## Refs

`concurrency.md` §4, §5 (shareability); `runtime/channel.nomu`; `PointerIntrinsics.swift` (the builtins);
`SSAIRToLLVM.swift` `lowerChannelOp`; `runtime.md` (scheduler, park/unpark).
