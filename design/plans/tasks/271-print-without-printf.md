# Print through a runtime buffer: no `printf`, one blocking call

**Avenue:** Risk (the "better than Go" concurrency thesis) · **Type/Lifecycle:** `runtime · compiler · designed`
· **Size:** M · **Status:** done · **Source:** [270](270-c-calls-as-stops.md)'s decisions; done as
[236](236-fiber-preemption.md)'s phase 236.6

## What

`print` and `putByte` go through libc's `printf` and `putchar`, whose stdout buffer decides when output
reaches the file. A `print` blocks only when libc flushes, inside a variadic call that cannot be a stop. Here
`print` copies its bytes into a stdout buffer the runtime owns, and the runtime writes the buffer out with
`write`: the one call that can block, which 270 marks as in C.

- **Formatting:** a `String`'s bytes copied (270's decision: a small payload is copied, so a collection may
  move the `String` while the write is under way); an `Int`, `UInt8`, `UInt64` or `Bool` formatted in Nomu; a
  `Double` formatted as today (`snprintf` and `strtod` into a frame buffer, a runtime leaf: it never blocks, so
  a variadic call there is no stop; shortest round-trip in Nomu is [227](227-double-formatting-in-nomu.md)).
- **The buffer:** one, for every fiber, under a lock, as libc's `stdout` is; written out when full, at a newline
  when stdout is a terminal (libc's line buffering), and at the program's end: its exit, a fatal error and a
  crash, as libc's was (the exit and fatal builtins and the fault handler call `nomuOutFlushAtExit`, which skips
  the flush if another thread holds the lock, so a crash inside a print cannot hang the end).
- **`putByte`** goes through the same buffer, so output keeps its order.
- **stderr** stays unbuffered (the crash and fatal reports).

## Built

`runtime/io.nomu` (the buffer, `nomuOutBytes`, `nomuOutByte`, `nomuOutInt`, `nomuOutUInt`, `nomuOutFlushAtExit`;
`Int` and `UInt64` formatted there); `EgressBuiltins.emitPrint` and `emitPutByte` call them, and the `Double` path
copies its formatted digits and newline in; `Runtime.isTerminal(fd:)` (`isatty`) for the line buffering.
Output byte for byte as before (`print_loop`'s whole output, the most negative `Int`, the largest `UInt64`,
`Double`, `Bool`, `UInt8`, `putByte`, UTF-8), line order on a terminal as before (a line, then a fatal error's
message). `print_loop`, stdout to /dev/null: 277 → 34 ms; to a pipe: 298 → 41 ms (`printf`'s formatting was
most of it). The suite passes.

## Done when

The suite passes with the same output; `print_loop` and the print-heavy benchmarks are no slower than with
`printf`; output reaches a pipe and a terminal as before (line-buffered on a terminal, ordered with
`putByte`, flushed before a fatal report).

## Refs

`src/llvmgen/EgressBuiltins.swift` (`emitPrint`, `emitPutByte`, `printDoubleFn`); [259](259-libc-or-own-per-routine.md)
(libc or Nomu's own, per routine); [270](270-c-calls-as-stops.md) (the in-C state the flush uses).
