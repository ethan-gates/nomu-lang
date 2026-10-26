# tools/

Integration drivers live in the declarative suite (`tests/suite.json`), run by the `compiler-test`
harness (see `tests/README.md`). What remains here runs across the whole example corpus or measures
performance, which the per-case suite does not express.

## Run the suite

```
bazel build -c opt //src/nomu-cli:nomu //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test tests/suite.json
```

## Scripts

- `escape-diff.sh` — builds and runs every example module with escape analysis on and off
  (`-c no_escape`) and asserts identical output and exit status, on one carrier.
- `perf-tier.py` — times benchmark workloads under each optimizer-pass configuration (best of N runs)
  and flags any configuration whose output differs from the all-passes-off baseline.
- `workspace_status.sh` — feeds the build's commit stamp (`.bazelrc`).

`install/` is unrelated tooling, left as-is.
