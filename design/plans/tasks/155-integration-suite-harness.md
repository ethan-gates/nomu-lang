# Integration-suite harness (one entry, rich output, source-declared env, no script sprawl)

**Avenue:** Infra · **Type/Lifecycle:** `tooling · observability · needs-design` · **Size:** L ·
**Status:** needs-design (build-soon; the suite is run constantly during the self-hosting push) ·
**Source:** grounded during 150.4.2 — the suite is 64 hand-rolled `tools/*.sh`, run by a copy-pasted
serial shell loop, with per-invocation env flags duplicated by hand.

Make the integration suite a first-class tool: one command to run it, a declarative case list, env
baked into each fixture's source, and output that reports failures, compile cost, and runtime cost well.
Today each test is its own bash script and each run re-invents the runner.

## Why now

The suite is the primary feedback loop for the self-hosted runtime (task 150 / 128). It is run many times
a day, so its ergonomics and speed compound. Measured state (150.4.2):

- **64 scripts in `tools/`**, one per test, each re-deriving compile → run → diff → PASS/FAIL by hand.
- **Env duplicated in source-of-truth-by-convention:** `NOMU_GC_PLAN=` appears 73 times, `NOMU_NO_ESCAPE=`
  in 27 of the 64 scripts, `NOMU_CARRIERS=`/`NOMU_RUNTIME=`/`NOMU_GC_STRESS=` similarly. A test that needs
  `NOMU_NO_ESCAPE=1` (so its objects stay on the heap) passes for the wrong reason if the flag is
  forgotten — a silent-green hazard, since the fixture still compiles and runs.
- **No single entry:** running "the suite" means pasting a `for t in …; do tools/$t.sh; done` loop. The
  loop ran serially (~273s); the cases are independent and parallelize to ~49s at `-P8` (5.5×) with no
  other change — so the default invocation left a 5× speedup on the table.
- **No perf visibility:** compile time is ~2.9s/case, ~1.7s of it re-emitting the whole runtime prelude
  every compile. Nothing surfaces this or flags a regression.

Partial prior art already in `tools/`: `gc-smoke-tier.sh`, `gc-corpus-matrix.sh`, `perf-tier.py` — tiering
and matrix runs exist ad hoc. This task folds them into one harness.

## What — the four goals (from the request)

1. **One clear full-test entry.** A single command runs the whole suite (and subsets/filters), with no
   on-the-fly scripting. `nomu-test [--tier=fast|all] [--filter=gc-*] [--jobs=N] [--json]` or equivalent.
   Adding a test is a case entry plus a `.nomu` fixture, never a new bash script.
2. **Rich output.** Per case: PASS/FAIL, compile time, run time. On failure: the got/want diff with
   context, the exact compile + run commands (copy-pasteable to reproduce), and stderr. Aggregate: pass/
   fail counts, total wall-clock, the slowest compiles and slowest runs (a standing perf watch), and a
   machine-readable (`--json`) mode for CI. Compile timing can reuse the compiler's existing `--timings`
   block; run timing is wall-clock around the binary.
3. **Env baked into fixture source.** A fixture declares the env it needs, so a run can never forget it.
   A comment directive (a convention, not new language syntax) read by the harness — and, for
   compile-affecting flags, ideally by the compiler driver itself:
   - `//@ compile-env: NOMU_NO_ESCAPE=1` — flags that change codegen (`NOMU_NO_ESCAPE`, `NOMU_NO_INLINE`,
     `NOMU_NO_SCALAR`, `NOMU_NO_DEVIRT`).
   - `//@ run-env: NOMU_GC_PLAN=nomu NOMU_RUNTIME=selfhost` — flags that change runtime behavior.
   - `//@ expect: <stdout>` (or an expected-output file) and `//@ oracle: plan=genimmix` for the
     differential cases (below).
   Distinguishing compile-env from run-env matters: the same fixture is often compiled once and run under
   several run-envs.
4. **Less script proliferation.** The 64 `tools/*.sh` collapse into case entries in a declarative
   manifest (or the directives above, if the fixture is self-describing). One runner interprets them.

## Design axes / forks to settle

- **Case description home — manifest vs self-describing fixture.** (a) A central manifest (a simple table
  / TOML) with one row per case: fixture, expected output, compile-env, run-env, tier, oracle, iteration
  count. (b) Self-describing fixtures — all of the above as `//@` directives in the `.nomu` file, the
  harness discovers cases by scanning `examples/`. (c) Hybrid: directives in-fixture for env/expectation
  (goal 3 wants this anyway), a thin manifest only for cases that reuse a fixture under several configs.
  *Lean: (c)* — env/expectation live with the fixture (satisfies goal 3 and kills most of the manifest),
  a small manifest covers multi-config reuse (e.g. run at 1/2/4/8 carriers).
- **Differential oracle as data, not code.** Many GC cases run the fixture under two plans and assert
  byte-identical output (self-host vs MMTk NoGC/GenImmix). Today each script hand-rolls the diff. Encode
  it: `//@ oracle: diff plan=nomu vs plan=genimmix` — the runner compiles once, runs both, diffs, and on
  mismatch shows both outputs. Replaces the most-copied bash pattern.
- **Runner language.** Bash is the sprawl. Options: a single parameterized bash+Python runner, a small
  Swift tool in `src/` beside the driver, or (dogfooding) a Nomu program. *Lean: a Swift tool* — it links
  the same code the compiler uses, gets real argument parsing + JSON + parallel scheduling, and stays in
  one language with the rest of the toolchain. A Nomu runner is a longer-term dogfood once the language is
  richer.
- **Parallelism + oversubscription.** The runner schedules cases across cores (bounded `--jobs`). Some
  cases self-parallelize (multi-carrier, stress loops); tag those `//@ heavy` so the scheduler gives them
  a lane rather than stacking them. Default `--jobs` ≈ cores, heavy cases serialized among themselves.
- **Tiering.** `fast` (every run, correctness) vs `all`/`stress` (pre-commit/CI: the carrier matrices,
  high iteration counts, flake-hunts). The long-pole cases (selfhost-gc, sched-integration, stw-*) drop
  to their fast slice for the default run; the full matrix moves behind `--tier=all`. Folds in the
  existing `*-tier.sh` / `gc-corpus-matrix.sh`.
- **Perf regression gate.** Since the harness measures compile + run time per case, it can record a
  baseline and warn (or fail under `--strict`) on regression. Ties to the prelude-re-emit floor: this
  harness is where a demand-driven-emission win (task 100 / a prelude-emission change) would show up.

## Migration

Incremental. Stand up the runner + directives, convert a handful of cases (the 150.4 GC set is a good
first batch — they share the compile-env + oracle-diff shape), keep the remaining `tools/*.sh` working
until each is ported, then retire the scripts. A thin compatibility shim (`tools/<name>.sh` → the runner
with a filter) can bridge muscle memory during the transition.

## Non-goals

- Not the compiler's own unit tests (`bazel test //…`, already a clean single entry) — this is the
  integration/driver layer that compiles and runs real programs.
- Not the per-stage IR-injection testing in [142](142-ir-pipeline-hardening.md) (that hardens stage
  boundaries); this harness runs whole-program fixtures. They compose — 142's `--start-from` could become
  another case kind here.

## Refs

[142 IR + pipeline hardening](142-ir-pipeline-hardening.md); [136 incremental compilation](136-incremental-compilation.md)
(the prelude re-emit floor this harness measures); [149 runtime-subset](149-runtime-subset.md) and
[150 GC ladder](150-selfhosted-gc-ladder.md) (the suite's heaviest clients). Prior art: `tools/perf-tier.py`,
`tools/gc-corpus-matrix.sh`, `tools/gc-smoke-tier.sh`.
