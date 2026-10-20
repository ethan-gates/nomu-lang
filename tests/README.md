# Integration suite (`compiler-test`)

One command runs the whole suite from a declarative manifest. Design and rationale:
`design/plans/tasks/155-integration-suite-harness.md`.

## Run

```
bazel build //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test tests/suite.json   # the manifest path is required
```

Flags:
- `--enable a,b,gc-*` — run only these (base becomes empty, then these are added).
- `--disable a,b,gc-*` — run everything except these.
- `--deadline SEC` — overall wall-clock backstop (default 300).

The manifest path is a required positional argument. List tokens match a case `name`; `all` is the
wildcard; a trailing `*` matches by prefix. The pool is 8 lanes; a case occupies `weight` of them.
Exit codes: 0 all pass · 1 a case failed/timed out · 2 usage · 3 deadline.

**Compiler:** the harness prefers a release build of `nomu` — it looks for a `bazel-out/*-opt/…`
build first (a debug compiler is ~10× slower to run), falling back to `bazel-bin` with a warning.
Build it once with `bazel build -c opt //src/nomu-cli:nomu`. Override with `COMPILER_TEST_NOMU`.
Each fixture builds with `nomu build <fixture dir>`; its binary is at `<workspace>/build/<module path>/<leaf>`,
under the `build/` of the workspace holding the fixture (the nearest `nomu.yaml`).

**Output:** on a terminal, a live status line pins the in-flight set and counts at the bottom
(`[42/68] running · gc-string, stw-collect  ✓40`) while finished cases stream above it. Piped or in
CI (not a TTY) it prints a sorted, deterministic batch at the end instead.

## Add a case

Add an object to `cases` in `tests/suite.json` and a `.nomu` fixture — no new shell script. Fields:

- `name` (unique), `fixture` (a module directory, path from the project root).
- `compile_args` — extra `nomu build` flags, e.g. `["--runtime-subset=enqueue,dequeue"]` for a
  subset-legality build. Part of the compile key.
- `compile_env` / `run_env` — the env is declared here, in exactly one place, so a run cannot
  silently forget or duplicate a flag. Compilation is shared: a fixture is built once per distinct
  `(compile_env, compile_args)`; a case's runs vary only `run_env` / `carriers`. Two cases sharing a
  fixture and compile config (e.g. a default leg and a `NOMU_GC_STRESS` leg) compile once.
- `expect` — `{ "stdout": "…" }` (literal, exact) or `{ "stdout_file": "tests/expected/x.txt" }`
  (golden file, for computed/large output). A golden is captured once and refreshed only when the
  correct output legitimately changes. Omit `expect` to
  only require a clean exit.
- `iterations` (repeat; all must pass), `carriers` (one run per count, sets `NOMU_CARRIERS`). Set
  `"carriers": []` to run once without setting `NOMU_CARRIERS` — for fixtures that manage their own
  threads (the self-hosted scheduler/actor cases).
- `stderr_match` — `[ { "pattern": "(minor)", "min": 10 } ]`, a per-line substring count for
  "collection actually fired" checks. `min` / `max` both optional.
- `object_symbols` — `[ { "pattern": "_nomu_fn_rt", "max": 0 } ]`, a count of defined symbols (`nm -U`)
  containing the substring in the fixture's own object (`<binary>.o`), checked once after compile. `min` /
  `max` both optional. Pins what the program's object defines, e.g. no duplicated runtime / `std` copies.
- `object_references` — the same shape over undefined symbols (`nm -u`): what the object calls out to,
  e.g. `__nomu_gc_poll_slow` absent from runtime-subset code.
- `stdin_file` / `stdin_delay_ms` — a repo-relative file fed to the program's stdin through a pipe, written
  `stdin_delay_ms` after launch and then closed (end of input). Without it stdin is `/dev/null`. The delay
  lets a case observe a program waiting on input (`read-line`: other fibers run meanwhile).
- `timeout_sec` / `compile_timeout_sec` — per-run and per-compile caps (defaults 60 / 120). Every
  run is bounded; on expiry the whole process group is killed and the case reports `TIMEOUT`.
- `weight` — lanes the case occupies in the fixed-8 pool (default 1). A self-parallelizing case
  (a carrier matrix, or a fixture that spawns its own threads) declares more, so the pool packs cases
  without oversubscribing — e.g. an 8-carrier case is `8` (near-exclusive), a 4-carrier case `4`, a
  couple of which then overlap. The legacy `heavy: true` still works and maps to weight 8.
- `compile: { "expect_error": "<substring>" }` — a negative case: the compile must fail with that
  substring, and no run happens.

Unset fields fall back to `defaults`.

## GC legs

Every program runs on the Nomu runtime (the Nomu scheduler and collector). A fixture's plain case runs it
with no knob; its collecting legs force collections and check with `stderr_match` that one fired
(`NOMU_GC_DEBUG_PRESSURE=1` prints each collection):
- `-evac` — `NOMU_GC_STRESS=<bytes>`: a collection every N bytes a carrier allocates, so every
  allocation site is a collection point (minor; `NOMU_MATURE_FLOOR` above the heap size makes it major).
- `NOMU_NURSERY_RESERVE=<blocks>` — minor collections when the nursery fills that many 32 KiB blocks.
- `NOMU_GC_PRESSURE` / `NOMU_STW_COLLECT` / `NOMU_STW_SELFHOST` — external driver threads (heap-pressure
  defrag, timed forced evacuation, timed root-walk STW).

## Scheduling order

The runner dispatches longest-first (LPT), so the long tails start early and overlap instead of
draining the pool at the end. The order lives in the manifest as an optional top-level
`computed_order` (the longest-first list of case names), written back as a single line — failures and
timeouts included, so a slow-failing case keeps its front-of-line slot. Never-measured cases sort
first (run early, get ranked next time). It is rewritten only on a full run (every manifest case ran),
sorted by that run's measured times, so a subset run reads the order but never rewrites it from partial
data. Safe to commit (CI/fresh checkouts inherit the order) or to delete (a full run rebuilds it).

## Golden files

`tests/expected/*.txt` — captured oracle output for `stdout_file` cases. Recapture only when a
fixture's correct output legitimately changes, e.g.:

```
NOMU_NO_ESCAPE=1 build/examples/gc_string > tests/expected/gc_string.txt
```

## Status

Phase 1 (MVP) is built: compile-once/run-many, golden compare, `stderr_match`, hardened timeouts,
a weight-packed 8-lane pool with longest-first dispatch, live TTY output, `--enable`/`--disable`.
The cases cover the retired `tools/*.sh` drivers (the run-and-check families: captured golden, GC
root-walk and collection checks, scheduler/runtime stdout).
The remaining `tools/` scripts are the tail the schema does not yet express (precise root-set
assertions, artifact inspection, perf/corpus matrices) — see `tools/README.md`. Phase 2 (perf
output, slowest-N, machine-readable/CI, regression gate) is pending.
