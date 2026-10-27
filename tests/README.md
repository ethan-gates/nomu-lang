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
- `--where axis=value,…` — run only group runs with these dimension values (`--where gc=stress-major`).
- `--tier fast|full` — `fast` (the default) or `full` (fast plus the expensive legs). See "Tiers".
- `--repeat N` — run the selection N times and report each case's pass rate (for hunting flakes).
- `--compiler PATH` — the `nomu` to test, e.g. an older build to check that a case catches its bug.
- `--deadline SEC` — overall wall-clock backstop (default 300, scaled by `--repeat`).
- `--check-reproducible` — instead of compiling and running, build the selection twice from clean, the second time
  from a copy of the sources and a host cache at other paths, and compare every cached output byte for byte
  (objects, `.nmi`, `.bir`, the runtime archive, entry manifests; binaries are left out). About 6 s for the
  fast tier. Exit 1 on a difference, with each file and its first differing byte; the rounds are kept for
  inspection. `nomu build --verify-cache` checks one build against the host cache.

The manifest path is a required positional argument. List tokens match a case `name`; `all` is the
wildcard; a trailing `*` matches by prefix. The pool is 8 lanes; a case occupies `weight` of them.
Exit codes: 0 all pass · 1 a case failed/timed out · 2 usage · 3 deadline.

**Compiler:** the harness prefers a release build of `nomu` — it looks for a `bazel-out/*-opt/…`
build first (a debug compiler is ~10× slower to run), falling back to `bazel-bin` with a warning.
Build it once with `bazel build -c opt //src/nomu-cli:nomu`. Override with `--compiler`.
Each fixture builds with `nomu build <fixture dir>`, and each configuration (a fixture plus its compile
settings) keeps its own binary at `build/compiler-test/<fixture>-<hash>/<leaf>`, copied from the path the
build reports. The suite's settings are still environment variables, which leave the build's output path
unchanged, so configurations of one fixture compile one after another; different fixtures compile in
parallel. (Task 205 moves the run settings off environment variables and restores the parallel compiles.)

**Hermetic runs:** compiles and runs see only `PATH`, `HOME`, `TMPDIR` and the case's declared settings.
Any `NOMU_*` variable in your shell is dropped.

**Output:** on a terminal, a live status line pins the in-flight set and counts at the bottom
(`[42/68] running · gc-string, stw-collect  ✓40`) while finished cases stream above it. Piped or in
CI (not a TTY) it prints a sorted, deterministic batch at the end instead.

## Add a case

Add an object to `cases` in `tests/suite.json` and a fixture directory — no new shell script. A fixture is a
package: a `pkg.json` declaring its `name` (the directory's name, matching `[a-z][a-z0-9_]*`) beside its
`.nomu` files. A fixture that is its own workspace (a `nomu.yaml`) keeps its packages in subdirectories,
since no package may sit at a workspace root. Fields:

- `name` (unique), `fixture` (a module directory, path from the project root).
- `compile_args` — extra `nomu build` flags, e.g. `["--runtime-subset=enqueue,dequeue"]` for a
  subset-legality build. Part of the compile key.
- `compile_settings` / `run_settings` — named settings (see "Settings"), declared here and nowhere else,
  so a run cannot silently forget or duplicate one. Compilation is shared: a fixture is built once per
  distinct compile configuration; a case's runs vary only `run_settings` / `carriers`. Two cases sharing a
  fixture and compile settings (e.g. a default leg and a stress leg) compile once.
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
- `tier` — `fast` (default) or `full`; a `full` case runs only under `--tier full`.
- `full_iterations` — repetitions under `--tier full`, when more than `iterations`: a case repeated to catch
  a timing-dependent race runs `iterations` times in the fast tier and `full_iterations` in the full tier.
  Groups take it too.
- `timing_sensitive` — run the case alone after the rest, with the pool otherwise idle (a delayed stdin
  feed racing other fibers, an external driver thread that must fire before a short program exits). There are no automatic retries; use `--repeat` to measure a flake.

Unknown keys are an error, at every level of the manifest.

Unset fields fall back to `defaults`.

## Settings

A case changes how its fixture is compiled or run only through named settings. The table, with each
setting's stage and its mechanism, is `src/compiler-test/sources/Settings.swift`; an unknown name, or a
setting at the wrong stage, is an error. Compile settings select configs declared in the repository's root
`cfg.yaml`; run settings are still environment variables (task 205 moves them).
- Compile: `optimize` (`-c release`), `inline`, `escape`, `scalar`, `devirt` (each default `true`; `false`
  selects `no_inline` and the like, turning the pass off), `rt_prelude` (fixtures that call `rt*` directly).
- Run: `gc_log` (log each collection: `nomu-gc-sync: collection N (minor|major)`), `gc_stress_bytes` (a
  collection every N bytes a carrier allocates), `nursery_blocks` (a minor collection when the nursery
  fills N 32 KiB blocks), `mature_floor` (every collection major below this mature size),
  `gc_trigger_reserve`, and the external driver threads `gc_pressure_driver` (heap-pressure defrag),
  `stw_collect_driver` (timed forced evacuation) and `stw_selfhost_driver` (timed root-walk STW).

## GC legs

Every program runs on the Nomu runtime (the Nomu scheduler and collector). A fixture's plain case runs it
with no setting; its collecting legs force collections and check with `stderr_match` (or a dimension's
`require_collections`) that they fired: `-evac` cases use `gc_stress_bytes`, `-nursery` cases
`nursery_blocks`.

## Dimensions and groups

A matrix is declared once. `dimensions` names axes; each value carries `compile_settings`, `run_settings`,
`require_collections` (at least N collections logged; turns on `gc_log`) and a `tier`:
- `pipeline` — `debug`; `release` (`optimize`) and `noinline` (`inline: false`), both `full`.
- `gc` — `default`; `nursery` (64 blocks); `nursery-tight` (1 block: collections land at points the larger
  nursery never reaches); `stress-minor` (a collection every 4 KiB); `stress-major` (the same, every
  collection major), `full`.

A `group` names fixtures by a directory glob (`dir/*`, every subdirectory), the axes it spans (`across`),
shared settings and a default `expect`. It expands to one run per fixture and combination of values, named
`group/fixture/value/…` (`shape/local_string/release/stress-major`). A fixture's own `expected.txt`, beside
its source, wins over the group's `expect`. A run's tier is the highest of its group's and its values'.
- `shape` — `tests/fixtures/shape_matrix/*` across `pipeline` × `gc`: a heap `String` held in every
  position a program can hold one, read back across collections (task 176.5). Each prints `bad 0`.
- `layout` — `tests/fixtures/layout_matrix/*` across `pipeline`: value layouts a mono caller and an erased
  body must agree on.

## Tiers

`fast` is the default run: every flat case, plus group runs on the debug pipeline with the `default`,
`nursery` and `stress-minor` legs. Budget about 60 s wall. `full` (`--tier full`) adds the `release` and
`noinline` pipelines and `stress-major`; budget about 5 minutes. A whole-tier run reports when it exceeds
its budget, and every run lists its five slowest cases.

## Scheduling order

The runner dispatches longest-first (LPT), so the long tails start early and overlap instead of
draining the pool at the end. The order lives in the manifest as an optional top-level
`computed_order` (the longest-first list of case names), written back as a single line — failures and
timeouts included, so a slow-failing case keeps its front-of-line slot. Never-measured cases sort
first (run early, get ranked next time). It is rewritten only on a whole-tier run (no `--enable`, `--disable` or `--where`; cases outside the tier
keep their earlier ranking after the measured ones),
sorted by that run's measured times, so a subset run reads the order but never rewrites it from partial
data. Safe to commit (CI/fresh checkouts inherit the order) or to delete (a full run rebuilds it).

## Golden files

`tests/expected/*.txt` — captured oracle output for `stdout_file` cases. Recapture only when a
fixture's correct output legitimately changes, e.g.:

```
nomu build -c no_escape examples/gc_string && build/no_escape/examples/gc_string > tests/expected/gc_string.txt
```

## Status

Phase 1 (MVP) is built: compile-once/run-many, golden compare, `stderr_match`, hardened timeouts,
a weight-packed 8-lane pool with longest-first dispatch, live TTY output, `--enable`/`--disable`.
The cases cover the retired `tools/*.sh` drivers (the run-and-check families: captured golden, GC
root-walk and collection checks, scheduler/runtime stdout).
The remaining `tools/` scripts are the tail the schema does not yet express (precise root-set
assertions, artifact inspection, perf/corpus matrices) — see `tools/README.md`. Phase 2 (perf
output, slowest-N, machine-readable/CI, regression gate) is pending.
