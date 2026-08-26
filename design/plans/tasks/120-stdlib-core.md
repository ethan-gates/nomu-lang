# Standard library — core types + basic I/O

**Avenue:** Usability · **Type/Lifecycle:** `user-facing · needs-design` (language + stdlib + runtime)
· **Size:** L · **Status:** needs-design (GC gate lifted, M6 done) · **Source:** deferred.md
(2026-08-18)

The named stdlib track. High-stakes sub-decisions are split into their own docs:
[String / UTF-8 model](121-string-utf8-model.md), [numeric semantics](122-numeric-semantics.md),
[copy-on-write](123-copy-on-write.md).

## What — two clusters

- **Core data types:** strings (the UTF-8 decisions), numbers, collections. Decide where each belongs
  (C `core` floor vs Nomu — M4.13), then create or polish.
- **Basic I/O to get programs started:** file I/O and network I/O on the colorless blocking model
  (syscall offload, `runtime.md` §5). Likely also env, process, time, stdio.

## Cross-cutting — where does it belong

Each primitive sits somewhere on the C `core` floor ↔ pure-Nomu axis. That placement couples with
[self-hosting](128-self-hosting-runtime.md) (removing the C floor pulls these into Nomu) and
[modules](100-modules.md) (the stdlib as modules with interfaces). Decide per-primitive, consistent with
those directions.

## Dependencies

- Collections + strings want **[raw-memory / byte-buffer primitives](125-unsafe-raw-memory.md)** and the
  GC (done).
- I/O wants the async runtime (done), the **syscall-offload path** (`runtime.md` §5), and
  **[error handling](115-error-handling.md)** (`Result` — I/O fails). Syscalls are already reachable: the
  privileged C runtime can expose a blessed I/O primitive set as builtins (like `print`), so I/O
  needs **no general first-class FFI** — [FFI](130-ffi-c-abi.md) enters only under the self-hosting path
  or for user bindings.

## Discipline

Drive priorities by language benchmarks: build the lowest primitives first (String, byte buffers, raw
memory, collections), measure, and let real programs set the order.

## Roadmap assessment (three-head)

**Yes — a named stdlib track.** Architecture (C-floor-vs-Nomu placement + module packaging),
performance envelope (the stdlib *is* the perf floor), programmer expectations (the daily surface).
Call out **String/UTF-8** and **numeric overflow** as their own high-stakes decisions.

## Refs

deferred.md "Standard library: core types + basic I/O"; `runtime.md` §5 (syscall offload);
M4.13 (C `core` floor); `arr_*.nomu`, `double_core.nomu`.
