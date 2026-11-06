# tools/

Integration drivers live in the declarative suite (`tests/suite/`), run by the `compiler-test`
harness (see `tests/README.md`). What remains here runs across the whole example corpus or measures
performance, which the per-case suite does not express.

## Run the suite

```
bazel build -c opt //src/nomu-cli:nomu //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test tests/suite
```

## Scripts

- `escape-diff.sh` — builds and runs every example module with escape analysis on and off
  (`-c no_escape`) and asserts identical output and exit status, on one carrier.
- `gc-baseline.py` — times the benchmark workloads on 1 and 4 carriers, under the `genimmix` and `immix` plans (best
  of N runs), and records each run's GC report metrics (cycles, pauses, time to safepoint, peak heap).
- `memcap.py` — runs a command under a memory cap and a time limit (default 2 GB, 60 s), killing it past
  either (`--stop` freezes it for a debugger instead); macOS does not enforce `ulimit -v`. For iterating
  on new tests and compiler features; the suite's steady-state cases run without it.
- `perf-tier.py` — times benchmark workloads under each optimizer-pass configuration (best of N runs)
  and flags any configuration whose output differs from the all-passes-off baseline.
- `frames-ir-cases/` — hand-written IR cases for task 243's claim 1 (stack addresses as tracked values
  through the statepoint rewrite and the arm64 backend); `run.sh` prints each case's code and records.
- `frames-ceiling.py` — builds the `frames_*` workloads (and a few others) under the `measure_*` configs,
  which remove a cost of finding roots unsoundly, and reports each one's change in time against the sound
  build (task 243.1), without the stack check (`--configs no-stack-checks`, task 104.2.5), or with libc
  called directly on fiber stacks (`--configs libc-direct`, task 104.3.3). Runs with a
  nursery large enough that nothing collects.
- `frame-depth.py` — reads a build's frame tables (the `<stem>.frames` beside each object: every function's
  frame size, direct calls, indirect callers and address-taken functions) and reports what the link's check
  measures (task 104): the deepest chains of unchecked frames below checked functions, the slow path's
  depth and the largest checked frame. `python3 tools/frame-depth.py build/<pkg>/<pkg>.frames
  build/_external/nomu.nomu/runtime/runtime.frames …`. `NOMU_FRAME_SIZES=1` also prints each table at build.
- `frame-stackaddr-asm.py` — scans linked arm64 binaries for stack addresses (computed from `sp`/`x29`) held
  in callee-saved registers across statepoint calls, and stores of stack addresses; a heuristic linear scan
  (task 241). `python3 tools/frame-stackaddr-asm.py <binaries…>`.
- `frame-stackaddr-ir.py` — classifies the non-GC pointers live across each statepoint in post-rewrite LLVM
  IR (`NOMU_DUMP_LLVM=1 nomu build --emit-llvm …` writes `<object>.post.ll`) by origin: alloca, parameter,
  load, call (task 241).
- `stackmap-count.py` — counts the stack-map records (statepoints) in a binary or object, per linked
  object and in total.
- `workspace_status.sh` — feeds the build's commit stamp (`.bazelrc`).

`install/` is unrelated tooling, left as-is.
