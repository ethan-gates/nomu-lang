# The `runtime` package

The privileged, self-hosted runtime tier: the scheduler, the collector and the allocator, written in Nomu.
It compiles into every program ahead of user code. Every function here is runtime-subset (task 149): it
may not trigger an implicit GC allocation, and it may call only subset functions and the raw-memory
allowlist. Privileged operations are spelled on `Runtime` (`design/internals/runtime-subset.md` §5).

One module over these files; a name declared in any file is visible in all of them.

| File | Contents |
|---|---|
| `startup.nomu` | startup globals: run settings, the scheduler, the heap |
| `carrier.nomu` | the carrier record (TLAB, mod-buffer) and the write barrier |
| `immix.nomu` | the Immix heap: regions, allocation, line marking, sweep, large objects |
| `descriptors.nomu` | GC type descriptors read by type-id |
| `stackwalk.nomu` | stack maps, the frame index, the pcsp walk, parked-fiber walks, the shadow stack |
| `stackmove.nomu` | moving a suspended fiber's stack (the copier) and its stress mode, `NOMU_STACK_MOVE` |
| `collect.nomu` | forwarding, evacuation, whole-heap and minor collection, the defrag trigger, the GC coordinator thread |
| `gcreport.nomu` | the collector's recorder and report |
| `scheduler.nomu` | the M:N scheduler, timers, actor mailboxes, the stop-the-world handshake, entry points |
| `io.nomu` | stdin line input and its poller, the array bounds trap |
| `msgpool.nomu` | the actor message pool: raw slabs by size class, per-carrier free lists, the root walk over queued messages |
| `channel.nomu` | the channel core under the prelude's `Channel<T>`: the buffer, the waiter queues, park and wake; the one-shot pair (fulfill, await) under `Task<T>`; and `select` (rtSelectWait, rtSelectDone) |
| `fault.nomu` | the fault handler: the crash report, each runtime thread's alternate signal stack; fiber dumps (SIGQUIT, `NOMU_TRACEBACK=all`); the out-of-memory report |
| `gcverify.nomu` | the heap verifier: the collector's invariants checked at every collection (`NOMU_GC_VERIFY=1`) |
| `leak.nomu` | the leak report: fibers that can never wake, found by a mark from the roots that can run (`NOMU_LEAK_REPORT=1`) |
| `verify.nomu` | the bump allocator and mark-verify tracer (early collector rungs) |

**The heap is one large reservation.** `rtHeapNew` (`startup.nomu`) reserves the heap and its side tables
once, sized by `NOMU_HEAP_MAX` or from physical RAM (64 GiB at least), and the heap's size is a soft limit
inside it (descriptor +160) that follows the live data, Go's `GOGC` rule (heap sizing, `immix.nomu`).
Untouched pages cost nothing, which holds only while two rules do:
- No pass reads or writes the blocks or side tables past the blocks ever used (`freeCursor`); on darwin a
  read alone makes a page resident. The suite's `heap-reservation-untouched` case bounds resident memory to
  catch a pass that strays.
- Anything the write barrier must see lives inside the reservation: its range test (`rtBarrierRange`:
  the start and length) and the log-bit table cover that range only. Large objects sit outside it and never move.

Under the generational plan the mutator allocates into clean (nursery) blocks only, never a mature block's
holes: nothing marks the lines it fills, so after the next minor the same holes would be handed out again
over live objects, and a new object there reads as logged, so the barrier would miss its nursery pointers.
`NOMU_GC_VERIFY=1` (`gcverify.nomu`) checks these rules and the collector's others at every collection.

**Every reader of a managed word masks it.** A managed word may carry a tag in its low 3 bits, which objects
(8-byte aligned) leave clear: an enum whose payload cases each hold a reference at the same offset keeps its
case there (spare bits). And any word below the first page holds no object (`rtNotObjectBound`): null, or an
enum's payload-free case. So code that reads a managed word to follow, mark, compare or hash it takes
`rtUntag` first and skips it when `rtNotObject`; code that writes a moved object back restores the word's tag
(`rtRefTag`). A new scan, root walk or verifier that reads the raw word would mistake a tagged reference for
an object three bytes in (`descriptors.nomu`).

**Recording costs nothing when off.** Every recording path is guarded by `Runtime.gcRecordLevel()` (0 off,
1 `limited`, 2 `full`), which folds to a constant when the runtime compiles, so a lower level's build has
none of the higher levels' code. Generated code follows the same rule through `LLVMGen.countsAllocations`
(the `full` level's allocation counting on the inline hit path). New recording code keeps to it. The
suite's `gc-record-*` cases check what each level reports; the cost of `full` is measured in task 159.6.

The compiler embeds these files (`src/runtime/embedded/embed.sh`) and the language workspace serves them
as the `runtime` package (`LanguageWorkspace.swift`). Struct-like layouts are byte offsets into raw
memory, documented where each is defined (the scheduler's at the top of `scheduler.nomu`).
