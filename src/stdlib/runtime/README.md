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
| `collect.nomu` | forwarding, evacuation, whole-heap and minor collection, the defrag trigger |
| `gcreport.nomu` | the collector's recorder and report |
| `scheduler.nomu` | the M:N scheduler, timers, actor mailboxes, the stop-the-world handshake, entry points |
| `io.nomu` | stdin line input and its poller, the array bounds trap |
| `verify.nomu` | the bump allocator and mark-verify tracer (early collector rungs) |

The compiler embeds these files (`src/runtime/embedded/embed.sh`) and the language workspace serves them
as the `runtime` package (`LanguageWorkspace.swift`). Struct-like layouts are byte offsets into raw
memory, documented where each is defined (the scheduler's at the top of `scheduler.nomu`).
