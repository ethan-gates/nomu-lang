# Runtime fault handling — a signal handler that says where a program died

**Avenue:** Risk · **Type/Lifecycle:** `runtime · needs-design` · **Size:** S–M · **Status:** needs-design ·
**Source:** split from [159](159-gc-observability.md): its phase breadcrumbs need a fault handler, and the
runtime has none.

## Today

The runtime installs no signal handlers. Its own fatal paths print and stop: an out-of-range index
(`rt_bounds_trap`, `abort()`), out of memory in the C runtime (`exit(1)`), a binary without its GC frame index
(`abort()`). A real fault (`SIGSEGV`, `SIGBUS`, `SIGILL`) takes the operating system's default: the process
dies and macOS writes a crash report whose backtrace cannot unwind fiber or carrier stacks (frame #0 only).
Fiber stacks are 128 KiB blocks from `RawPtr.alloc` (`rtSchedFiberNew`) with no guard page, so a fiber stack
overflow overwrites the memory below it without faulting ([104](104-fiber-stack-strategy.md)).

## What

One fault handler for the runtime. On a fault it prints what the runtime knows (the signal, the faulting
address, the thread, and what each subsystem reports) and then dies with the signal's default action, so the
exit status and the system crash report are unchanged.

## Design

- **Constraints of a handler.** It runs on the faulting thread at an arbitrary instruction, possibly while
  that thread holds a lock or is midway through an update. So it takes no locks, allocates nothing, and calls
  only async-signal-safe functions: it prints with `write(2)`.
- **Its own stack.** Each carrier gets an alternate signal stack (`sigaltstack`), so a stack overflow can still
  be reported.
- **Reporters.** A subsystem registers a reporter that the handler calls; a reporter reads only data written
  so that an interrupted writer leaves it whole. The first is 159's recorder (each thread's last open
  interval); a fiber guard page (104) is the next.
- **Less C.** `sigaction`, `sigaltstack` and the handler are Nomu (runtime subset, through intrinsics), adding
  no C.

## Work

- **219.1** The handler: installed at startup, an alternate stack per carrier, the signal and faulting address
  printed, then the default action.
- **219.2** Reporters: the registry; 159's breadcrumbs as the first.
- **219.3** Tests: a deliberate fault in a fixture prints the signal and the last interval, and the exit
  status is the signal's.

## Refs

`rtBoundsTrap` (`src/stdlib/runtime/io.nomu`), `rtSchedFiberNew` (`src/stdlib/runtime/scheduler.nomu`);
[159 GC observability](159-gc-observability.md), [104 fiber stack strategy](104-fiber-stack-strategy.md),
[218 Linux support](218-linux-support.md) (signal numbers and `ucontext` differ).
