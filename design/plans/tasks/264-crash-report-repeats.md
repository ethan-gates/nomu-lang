# A trap's crash report repeats without end

**Avenue:** Risk (diagnostics) · **Type/Lifecycle:** `runtime · fault · llvmpasses · bug` · **Size:** S ·
**Status:** done ·
**Source:** [261](261-actor-follow-ups.md).4, where a runtime function compiled to `brk #0x1` trapped on a
mailbox fiber.

## What

The fault handler (`runtime/fault.nomu`) is installed with `SA_RESETHAND`, so after its report the signal's
default action should end the process. On a `brk` trap (SIGTRAP) on a carrier the report printed again and
again, the same carrier and registers each time, until the shell's 5 GB output limit killed the process: the
trapping instruction re-ran after the handler returned and the handler ran again.

## Cause

Darwin, as BSD, ignores `SA_RESETHAND` for SIGILL and SIGTRAP: the handler stays installed after it runs. The
handler's closing `raise` therefore ran the handler again, and so on without end. SIGSEGV, SIGBUS and SIGABRT
were reset as intended and gave one report. Reproduced with `Runtime.raise`: 353,954 reports in 5 seconds for
SIGTRAP, 352,960 for SIGILL.

## Work

- **264.1** Done. The handler restores the signal's default action (`sigaction` with a null handler,
  `SIG_DFL`) before its `raise`, so the raise ends the process after one report. Exit statuses are the default
  action's (133 for SIGTRAP, 132 for SIGILL). Cases `crash-sigtrap` and `crash-sigill` (one report, the
  signal, 5-second limit; both time out without the fix).
- **264.2** Done. Found reproducing 264.1 with a real trap: a function the optimizer proves undefined (a load
  through a pointer made from null, [263](263-raw-pointers-from-null.md)) is reduced to `unreachable`, its stack
  check with it, and the stack checks' verification failed the build ("lost its stack check"). A function that
  only traps uses no stack; the verification now accepts one (`onlyTraps` in `llvmpasses/StackChecks.cpp`).
  Case `trap-only-function` (fails without the fix with that error).

## Refs

`runtime/fault.nomu` (`rtFaultInstall`, `rtFaultHandler`, `rtFaultThreadStart`), `llvmpasses/StackChecks.cpp`
(`expandStackChecks`).
