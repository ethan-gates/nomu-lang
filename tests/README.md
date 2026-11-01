# Integration suite (`compiler-test`)

One command runs the whole suite from a declarative manifest. Design and rationale:
`design/plans/tasks/155-integration-suite-harness.md`.

## Run

```
bazel build //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test tests/suite   # the manifest directory is required
```

Flags:
- `--enable a,b,gc-*` — run only these (base becomes empty, then these are added).
- `--disable a,b,gc-*` — run everything except these.
- `--where axis=value,…` — run only group runs with these dimension values (`--where gc=stress-major`).
- `--tier fast|full` — `fast` (the default) or `full` (fast plus the expensive legs). See "Tiers".
- `--repeat N` — run the selection N times and report each case's pass rate. The rounds share the pool, so
  cases load each other, and a case whose result changes between rounds fails as flaky. This is the
  determinism check: `--tier full --repeat 3` before a change that touches the runtime or the suite.
- `--compiler PATH` — the `nomu` to test, e.g. an older build to check that a case catches its bug.
- `--deadline SEC` — overall wall-clock backstop (default 300, scaled by `--repeat`).
- `--check-reproducible` — instead of compiling and running, build the selection twice from clean, the second time
  from a copy of the sources and a host cache at other paths, and compare every cached output byte for byte
  (objects, `.nmi`, `.bir`, the runtime archive, entry manifests; binaries are left out). About 6 s for the
  fast tier. Exit 1 on a difference, with each file and its first differing byte; the rounds are kept for
  inspection. `nomu build --verify-cache` checks one build against the host cache.

The manifest directory is a required positional argument. List tokens match a case `name`; `all` is the
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

The manifest is `tests/suite/`: `suite.yaml` holds the defaults, dimensions and groups, and
`cases/<area>.yaml` holds the cases, one file per area (gc, generics, modules, runtime, scheduler, language).
The harness loads every file in `cases/` and rejects a name used twice. Files are in the YAML subset of
`src/yaml/spec.md`: block collections only (a list is one `- item` per line; `[]` is the only flow form),
and a scalar on one line. Quote a string that would read as another type, or that holds `\n`.

Add a case to the area file it belongs to, with a fixture directory under `tests/fixtures/` — no new shell
script. A fixture is a
package: a `pkg.json` declaring its `name` (the directory's name, matching `[a-z][a-z0-9_]*`) beside its
`.nomu` files. A fixture that is its own workspace (a `nomu.yaml`) keeps its packages in subdirectories,
since no package may sit at a workspace root. Fields:

- `name` (unique), `fixture` (a module directory, path from the project root).
- `compile_args` — extra `nomu build` flags, e.g. `- "--runtime-subset=enqueue,dequeue"` for a
  subset-legality build. Part of the compile key.
- `compile_settings` / `run_settings` — named settings (see "Settings"), declared here and nowhere else,
  so a run cannot silently forget or duplicate one. Compilation is shared: a fixture is built once per
  distinct compile configuration; a case's runs vary only `run_settings` / `carriers`. Two cases sharing a
  fixture and compile settings (e.g. a default leg and a stress leg) compile once.
- `expect` — `stdout: "…"` (literal, exact) or `stdout_file: tests/expected/x.txt`
  (golden file, for computed/large output). A golden is captured once and refreshed only when the
  correct output legitimately changes. Omit `expect` to
  only require a clean exit. `signal: SIGSEGV` (or `SIGABRT`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGKILL`) is
  for a case that crashes on purpose: each run must die from that signal, and `stdout` and `stderr_match`
  are still checked (the `crash-*` cases, the fault handler's report).
- `iterations` (repeat; all must pass), `carriers` (one run per count, sets `NOMU_CARRIERS`). Set
  `carriers: []` to run once without setting `NOMU_CARRIERS` — for fixtures that manage their own
  threads (the self-hosted scheduler/actor cases).
- `stderr_match` — entries of `pattern: "nomu-gc: report"`, `min: 1`, a per-line substring count over the
  run's stderr. `min` / `max` both optional.
- `collections` — entries of `kind: minor`, `min: 10`, a count of the run's collection cycles, read from the
  collector report. Each field narrows the cycles counted: `kind` (`minor`, `major`), `trigger` (a name from
  the report's `names.triggers`, e.g. `program request`), `roots` (exactly this many stack roots); an absent
  field matches every cycle. A case with it compiles with `gc_record` and runs with `NOMU_GC_REPORT_DIR` set
  to a directory of its own, which the runner reads after each run. `min` / `max` both optional.
- `report_metrics` — entries of `path: allocation.objects`, `equals: 200009`, values from the same report's
  `metrics` by dot-separated path: `equals`, or `min` / `max`, or `"absent": true` for a path the report must
  not have. Like `collections`, it turns on `gc_record` (a case compiled with `gc_record_full` keeps `full`).
  `gc-record-full` and its stress leg pin the allocation counts exactly.
- `object_symbols` — entries of `pattern: _nomu_fn_rt`, `max: 0`, a count of defined symbols (`nm -U`)
  containing the substring in the fixture's own object (`<binary>.o`), checked once after compile. `min` /
  `max` both optional. Pins what the program's object defines, e.g. no duplicated runtime / `std` copies.
- `object_references` — the same shape over undefined symbols (`nm -u`): what the object calls out to,
  e.g. `__nomu_gc_poll_slow` absent from runtime-subset code.
- `stdin_file` / `stdin_after` — a repo-relative file fed to the program's stdin through a pipe, then closed
  (end of input). Without it stdin is `/dev/null`. With `stdin_after`, the file is written once the
  program's stderr shows that text (stdout is buffered on a pipe, stderr is not). A case that observes a
  program waiting on input builds with `rt_prelude` and writes the text when the wait is certain, e.g. once
  `rtStdinWaiters()` counts its readers (`read-line`, `read-line-readers`, `read-line-gc`).
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

Unknown keys are an error, at every level of the manifest, reported with the file, line and column.

Unset fields fall back to `defaults`.

## Settings

A case changes how its fixture is compiled or run only through named settings. The table, with each
setting's stage and its mechanism, is `src/compiler-test/sources/Settings.swift`; an unknown name, or a
setting at the wrong stage, is an error. Compile settings select configs declared in the repository's root
`cfg.yaml`; run settings are still environment variables (task 205 moves them).
- Compile: `optimize` (`-c release`), `inline`, `escape`, `scalar`, `devirt` (each default `true`; `false`
  selects `no_inline` and the like, turning the pass off), `rt_prelude` (fixtures that call `rt*` directly),
  `runtime_tier` (fixtures that call the `Runtime` intrinsics without the runtime prelude),
  `gc_record` (the collector's recorder at `limited`; `collections` turns it on), `gc_immix` (the `immix`
  collector plan: whole-heap collection only, no write barrier).
- Run: `gc_stress_bytes` (a
  collection every N bytes a carrier allocates), `nursery_blocks` (a minor collection when the nursery
  fills N 32 KiB blocks), `mature_floor` (every collection major below this mature size).

A case that needs a collection at an exact point builds with `rt_prelude` and calls `rtGcRequest(kind)`
from the fixture: the request goes through the coordinator, and the caller stops at its next safepoint poll.
It returns a ticket; a loop that spins until `rtGcCollected(ticket)` holds the caller in the loop until the
collection has run. Assert the requested cycle with `"trigger": "program request"` (`stw-collect`,
`stw-running`, `stw-inlined-loop` and the `module-generic-*` evacuation cases).

## GC legs

Every program runs on the Nomu runtime (the Nomu scheduler and collector). A fixture's plain case runs it
with no setting; its collecting legs force collections and check with `collections` (on the case or a
dimension value) that they ran: `-evac` cases use `gc_stress_bytes`, `-nursery` cases
`nursery_blocks`. The `gc` dimension's `immix-stress` value (full tier) builds under the `immix` plan
(`gc_immix`) and asserts major collections only.

## Dimensions and groups

A matrix is declared once. `dimensions` names axes; each value carries `compile_settings`, `run_settings`,
`collections` (as on a case) and a `tier`:
- `pipeline` — `debug`; `release` (`optimize`) and `noinline` (`inline: false`), both `full`.
- `gc` — `default`; `nursery` (64 blocks); `nursery-tight` (1 block: collections land at points the larger
  nursery never reaches); `stress-minor` (a collection every 4 KiB); `stress-major` (the same, every
  collection major), `full`.

A `group` names fixtures by a directory glob (`dir/*`, every subdirectory), the axes it spans (`across`),
shared settings and a default `expect`. It expands to one run per fixture and combination of values, named
`group/fixture/value/…` (`shape/local_string/release/stress-major`). A fixture's own `expected.txt`, beside
its source, wins over the group's `expect`. A run's tier is the highest of its group's and its values'.
`exclude` lists subdirectories the glob leaves out, by name; each must exist, and the manifest says why it is
excluded.
- `shape` — `tests/fixtures/shape_matrix/*` across `pipeline` × `gc`: a heap `String` held in every
  position a program can hold one, read back across collections (task 176.5). Each prints `bad 0`.
- `layout` — `tests/fixtures/layout_matrix/*` across `pipeline`: value layouts a mono caller and an erased
  body must agree on.
- `examples` — `examples/*`, the user-facing demos, each against its `expected.txt`, so they keep working.

## Bundles

A bundle is one fixture holding several small programs, so they cost one build, one link and one first
run. Each program is a module of the bundle's package, and its `main` is `package fun bundleMain()`; the
bundle's own `main` runs them in turn, each after a `== <module>` line, so a failing diff names the part that
broke. `bundle-plain`, `bundle-rt-prelude` and `bundle-core-import` are the bundles today, one per set of
compile settings.

A program fits a bundle when it shares the bundle's compile settings, compile arguments and run settings,
checks only its stdout, runs in a few milliseconds, and its output does not depend on what ran before it in
the process. Programs that print heap addresses, fingerprints or live counts (the mark-verify and root-walk
fixtures), that print while globals initialize, or whose module layout is the thing under test keep a
fixture of their own, as does a fixture another case also uses with other settings.

## Tiers

`fast` is the default run: every flat case, plus group runs on the debug pipeline with the `default`,
`nursery` and `stress-minor` legs. Budget about 60 s wall. `full` (`--tier full`) adds the `release` and
`noinline` pipelines and `stress-major`; budget about 5 minutes. A whole-tier run reports when it exceeds
its budget, and every run lists its five slowest cases.

## Scheduling order

The runner dispatches longest-first (LPT), so the long tails start early and overlap instead of
draining the pool at the end. The order is a local cache, `build/compiler-test/order.txt`: the case names
longest first, one per line, failures and timeouts included, so a slow-failing case keeps its
front-of-line slot. Never-measured cases sort first (run early, get ranked next time). It is rewritten only
on a whole-tier run (no `--enable`, `--disable` or `--where`; cases outside the tier keep their earlier
ranking after the measured ones), sorted by that run's measured times, so a subset run reads the order but
never rewrites it from partial data. Timings belong to the machine, so the file stays out of git; deleting
it costs one unordered run.

## Golden files

`tests/expected/*.txt` — captured oracle output for `stdout_file` cases. Recapture only when a
fixture's correct output legitimately changes, e.g.:

```
nomu build -c no_escape tests/fixtures/gc_string && build/no_escape/tests/fixtures/gc_string > tests/expected/gc_string.txt
```

## Status

Phase 1 (MVP) is built: compile-once/run-many, golden compare, `stderr_match`, hardened timeouts,
a weight-packed 8-lane pool with longest-first dispatch, live TTY output, `--enable`/`--disable`.
The cases cover the retired `tools/*.sh` drivers (the run-and-check families: captured golden, GC
root-walk and collection checks, scheduler/runtime stdout).
The remaining `tools/` scripts are the tail the schema does not yet express (precise root-set
assertions, artifact inspection, perf/corpus matrices) — see `tools/README.md`. Phase 2 (perf
output, slowest-N, machine-readable/CI, regression gate) is pending.
