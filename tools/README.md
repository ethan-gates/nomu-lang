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
- `stackmap-count.py` — counts the stack-map records (statepoints) in a binary or object, per linked
  object and in total.
- `workspace_status.sh` — feeds the build's commit stamp (`.bazelrc`).

`install/` is unrelated tooling, left as-is.
