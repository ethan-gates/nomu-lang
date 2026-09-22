# Integration-suite harness (one entry, rich output, source-declared env, no script sprawl)

**Avenue:** Infra · **Type/Lifecycle:** `tooling · observability` · **Size:** L ·
**Status:** Phase 1 (MVP) built and green — `src/compiler-test/` Swift tool (`bazel build //src/compiler-test:compiler-test`),
`tests/suite.json` manifest, `tests/README.md`, `tools/README.md`. 68 cases cover ~42 retired `tools/*.sh`
drivers (the run-and-check families: plan-differential golden, self-hosted GC oracle, scheduler/runtime stdout);
full run 68/68 green in ~49s with a release compiler (~78s with a debug one; the old serial loop was ~273s for a
smaller set). The harness prefers a release (`bazel-out/*-opt`) `nomuc` — a debug compiler is ~10× slower to run
(≈0.4s vs ≈4.5s per compile) — and warns when it falls back to `bazel-bin`. Features: compile-once/run-many
(shared by `(compile_env, compile_args)`), golden compare (`stdout`/`stdout_file`), `stderr_match`, negative
`compile.expect_error`, `compile_args` (subset-legality builds), `carriers` matrix (incl. `[]` = no
`NOMU_CARRIERS`), hardened process-group-kill timeouts (distinct TIMEOUT status), a fixed-8 pool that packs by
per-case `weight` (a self-parallelizing case declares more lanes; legacy `heavy` = weight 8) dispatched
longest-first (LPT) from an optional in-manifest `computed_order` (written back as a single line on a full run,
sorted by measured time; subset runs read but don't rewrite) so long tails start early and overlap,
`--enable`/`--disable`, `--deadline` backstop, and a live TTY status line (in-flight set + counts, finished
cases streaming above; batch sorted output off a TTY). Weighted packing + LPT cut the wall from ~52s
(all-exclusive) to ~31–42s. The config (manifest path) is a required positional argument. Source is split by
concern: `Ctx` (args/paths/manifest/selection), `CompileCache`, `CaseRunner`, `Suite` (pool + report),
`Ordering`, `Progress`, `Spawn`. The tail (~28 scripts: precise root-set assertions,
compiler-artifact inspection, perf/corpus matrices) stays in `tools/` by decision — a different testing layer or
needs a richer assertion; see `tools/README.md`. **Parked here, waiting on GC observability ([159](159-gc-observability.md))** —
that work unblocks the tail port (structured stats for the root-set assertions) and the configurable
release/debug mode. Phase 2 deferred by decision: the perf-regression gate is not worth building while upcoming
changes carry intentional (sometimes slower) perf shifts, and live-output level 3 is a nice-to-have we don't
need. Key forks resolved:
zero-dependency Swift runner, central JSON manifest, MVP-first phasing (see "Decisions" + "Plan"). ·
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
   on-the-fly scripting. `compiler-test [--tier=fast|all] [--filter=gc-*] [--jobs=N] [--json]` or equivalent.
   Adding a test is a case entry plus a `.nomu` fixture, never a new bash script.
2. **Rich output.** Per case: PASS/FAIL, compile time, run time. On failure: the got/want diff with
   context, the exact compile + run commands (copy-pasteable to reproduce), and stderr. Aggregate: pass/
   fail counts, total wall-clock, the slowest compiles and slowest runs (a standing perf watch), and a
   machine-readable (`--json`) mode for CI. Compile timing can reuse the compiler's existing `--timings`
   block; run timing is wall-clock around the binary.
3. **Env declared once, never forgotten.** Each case declares the env it needs in exactly one place, so a
   run can never forget or duplicate it (the silent-green hazard). **Resolved:** that place is the central
   JSON manifest (per-case `compile-env` / `run-env`). The in-fixture `//@` directive form below is the
   eventual ergonomic target, kept for a later migration; the manifest is the source of truth for now.
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

## Decisions (locked)

- **Runner — a zero-dependency Swift tool** (`src/compiler-test/`, beside the compiler; its own bazel target,
  one command to run the whole suite). Swift standard library + built-in JSON only — no external SPM
  packages. First choice for JSON is Foundation's `Codable`/`JSONDecoder` (ships with the toolchain, no
  dependency); if the bazel Swift sandbox does not expose Foundation, a small hand-rolled JSON reader keeps
  it strictly zero-dependency. Chosen over a bash+Python runner (perpetuates the scripting layer the task
  exists to remove) and a Nomu runner (the language is too young for the file/process/JSON surface today).
- **Case description — a single central JSON manifest** (`tests/suite.json`; not TOML — team preference;
  JSON parses zero-dependency in Swift; `snake_case` keys, `Codable`-friendly). One object per case
  (fixture, `compile_env`, `run_env`, `expect`, tier, iterations, carriers, `heavy`). The manifest is the
  single declared source of a case's env, so a run cannot silently forget or duplicate it (goal 3's
  silent-green hazard, closed via the manifest rather than in-fixture directives; those stay the eventual
  ergonomic target). Full schema in "Manifest schema" below.
- **Scope — MVP first, then layer** (see the plan below).

### Dropped / deferred

- **No differential diffing.** The GC oracle cases are deterministic (checksum-identical to MMTk by design),
  so the MMTk output is captured **once** as a golden value (`stdout` / `stdout_file`) and selfhost is
  compared against it — golden-file testing, no live second run. Golden is stricter for the collector under
  test (catches selfhost drift regardless of MMTk) and only needs re-capture when a fixture's correct output
  legitimately changes. A live `diff` mode returns only if a non-deterministic-but-cross-plan-identical case
  ever appears, which the suite does not have.
- **No tiering in the MVP.** `--enable`/`--disable` (below) already gives case selection; a `fast`/`all`
  tier split (curated quick subset vs the full carrier matrices for pre-commit/CI) reappears only when the
  suite is large enough to warrant it. The `tier` field is dropped until then.

### Remaining open axes (later phases)

- **Compiler build mode (release vs debug), configurable.** The harness prefers a release (`-c opt`) `nomuc`
  today (≈10× faster compiles). Make the mode selectable (a flag / manifest field), because GC observability
  ([159](159-gc-observability.md)) likely behaves differently under release vs debug — assertions, timing, and
  debug-only diagnostics all interact with optimization. Enumerate those release/debug × observability
  interactions when 159 is designed, then wire the chosen knobs here (a case may need to pin a mode, or run
  under both). Until then: release preferred, `COMPILER_TEST_NOMUC` overrides.
- **Perf output + gate.** _(Deferred by decision — a regression gate fights the intentional, sometimes-slower
  perf shifts in upcoming changes; revisit once the runtime stabilizes.)_ Per-case compile+run timing, slowest-N
  lists, machine-readable results for CI, and
  a recorded baseline that warns (or fails) on regression. Ties to the prelude-re-emit floor
  ([136](136-incremental-compilation.md)) — where a demand-driven-emission win would show up. Deferred; the
  MVP has no `--json` (every run reads the manifest).
- **Live progress output — level 2 built** (`src/compiler-test/sources/Progress.swift`). On a TTY a single
  self-updating status line pins the in-flight set + counts at the bottom (`[42/68] running · gc-string,
  stw-collect  ✓40 ✗2`), width-truncated, while finished cases stream above it; off a TTY (`isatty(1)` false)
  the batch sorted report drives output. Shows a compile phase then a run phase (Phase A builds all fixtures
  before any run). All writes go through one FileHandle under a lock so the status line and streamed lines
  never corrupt each other. State comes from the existing transitions: dispatch, `gate.acquire`, `runCase`
  return. Remaining (level 3, _not needed now_): a ~150 ms ticker showing per-case elapsed time (so a slow case
  like `stw-collect` shows progress, not a frozen line), and the slowest-N summary — folds in with the perf work.

## Plan — phased (MVP first)

**Phase 1 — MVP, the usable core.**
- Swift `compiler-test` tool + bazel target; one command runs the suite (`compiler-test [config]`, default
  `tests/suite.json`; `--enable`/`--disable`, see "Runner CLI").
- Reads the JSON manifest; per case: compile the fixture with `compile_env` (once, shared across its runs),
  run with `run_env` × `carriers` × `iterations`, compare stdout to `expect` (golden), check any
  `stderr_match`, and enforce a **per-case timeout** — the no-timeout hazard that turned a collector deadlock
  into a silent multi-minute hang during 150.4.5.3 — across a parallel pool (fixed 8; `heavy` cases do not
  stack).
- Rich failure output: got/want diff with context, the exact compile + run commands (copy-pasteable to
  reproduce), and captured stderr. Aggregate: pass/fail counts + total wall-clock.
- Port the current GC/gen drivers into the manifest, capturing each oracle output as a golden value; keep
  `tools/*.sh` working alongside until each is ported, then retire.

**Phase 2 — rich perf + CI output.** Per-case compile+run timing, slowest-N lists, machine-readable results,
perf-regression baseline/gate, and live progress output (the pending/running/done status above). This is the
harness the GC-benchmarking step (horizon "after GenImmix") and tasks 158/159 report through. (Tiering and a
live `diff` mode fold in here only if the suite ever needs them.)

## Manifest schema (the config)

One file, `tests/suite.json`, `snake_case` keys. The schema is defined whole here; the runner honors fields
in the phase noted (P1 = MVP).

```json
{
  "defaults": { "timeout_sec": 60, "compile_timeout_sec": 120, "iterations": 1, "carriers": [1], "heavy": false },
  "cases": [
    {
      "name": "gc-anybox",
      "fixture": "examples/gc_anybox.nomu",
      "compile_env": { "NOMU_NO_ESCAPE": "1" },
      "run_env":     { "NOMU_RUNTIME": "selfhost" },
      "expect":      { "stdout": "10432\n" },
      "iterations": 6
    }
  ]
}
```

**Case fields.** `name` (unique). `fixture` (path). `compile_env` / `run_env` (string→string). `expect`
(below). `iterations` (repeat; all must pass). `carriers` (list; expands to one run per count, setting
`NOMU_CARRIERS`). `timeout_sec` (per run) / `compile_timeout_sec` (per compile) — see "Timeouts". `heavy`
(`true` = does not stack in the parallel pool — for cases that self-parallelize, like the carrier matrices).
`compile` (below). `stderr_match` (below). Unset fields fall back to `defaults`.

**Compilation is shared.** Keyed by `(fixture, compile_env)` and done once; a case's runs vary only
`run_env` / `carriers`, reusing the one binary. Compile-clean is the default; a negative case declares
`"compile": { "expect_error": "<substring>" }`.

**`expect` variants** (mutually exclusive):

| form | meaning | phase |
| --- | --- | --- |
| `{ "stdout": "…" }` | stdout equals the literal (empty string = a self-checking fixture that prints only on failure) | P1 |
| `{ "stdout_file": "tests/expected/x.txt" }` | stdout equals a golden file (large/unwieldy output, e.g. an oracle output captured once) | P1 |

Oracle cases (former "diff against MMTk") use a captured golden value — the deterministic MMTk output stored
as `stdout` or `stdout_file`, refreshed only when a fixture's correct output legitimately changes. No live
second run.

**`stderr_match`** (P1) — assert the run's stderr contains a pattern at least/at most N times, for
"collection actually fired" checks (e.g. `gen-major` needs the debug env in `run_env`):

```json
"run_env": { "NOMU_RUNTIME": "selfhost", "NOMU_NURSERY_RESERVE": "8", "NOMU_GC_DEBUG_PRESSURE": "1" },
"stderr_match": [ { "pattern": "(minor)", "min": 10 }, { "pattern": "(major)", "min": 2 } ]
```

This greps debug output for now; when [159](159-gc-observability.md) lands structured stats, these migrate to
a `stats` assertion (`{ "minors_min": 10 }`) reading the machine-readable record instead of the print format.

**Worked examples** (the shapes the current drivers reduce to):

```json
{ "name": "gen-major", "fixture": "examples/gen_major.nomu",
  "run_env": { "NOMU_RUNTIME": "selfhost", "NOMU_NURSERY_RESERVE": "8", "NOMU_MATURE_FLOOR": "8176",
               "NOMU_GC_DEBUG_PRESSURE": "1" },
  "expect": { "stdout": "77\n4242\n94950" }, "iterations": 5,
  "stderr_match": [ { "pattern": "(minor)", "min": 10 }, { "pattern": "(major)", "min": 2 } ] }

{ "name": "gc-string", "fixture": "examples/gc_string.nomu",
  "compile_env": { "NOMU_NO_ESCAPE": "1" }, "run_env": { "NOMU_RUNTIME": "selfhost" },
  "expect": { "stdout_file": "tests/expected/gc_string.txt" }, "carriers": [1, 2, 4], "iterations": 4 }
```

`gc-string`'s expected hash is whatever the MMTk baseline produces (computed, not a hand-written constant),
so its golden is captured once from an MMTk run into `tests/expected/gc_string.txt`; the case then asserts
selfhost reproduces it across 1/2/4 carriers. All cases port in P1 this way — a fixed literal where the value
is obvious (`gen-major`, `gc-anybox`, the smokes), a captured golden file where it is a computed checksum.

## Runner CLI (MVP)

`compiler-test [config]` — `config` defaults to `tests/suite.json`. Every invocation reads a manifest (there is
no caseless/ad-hoc mode).

- `--enable a,b,c` — run only these cases. Implies `--disable all` first (base becomes empty, then these are
  added).
- `--disable a,b,c` — run everything except these.
- Neither flag → all cases run.
- List entries match a case `name`; `all` is the wildcard token; a trailing `*` matches by prefix
  (`--disable gc-*`).
- Resolution: base = all cases (or `{}` if `--enable` is given); add the `--enable` list; remove the
  `--disable` list.
- Concurrency is fixed at 8 (no `--jobs`); `heavy` cases do not stack. No `--json`, no `--tier` in the MVP.

## Timeouts & hang handling

Hangs have been the dominant failure mode during the GC bring-up — a collector deadlock presented as a silent
multi-minute stall with no output, indistinguishable from "still running." The runner treats a timeout as a
first-class outcome, not an edge case:

- **Every run is bounded, always.** Each individual run (one `run_env` × carrier × iteration) is capped at
  `timeout_sec` (default 60). There is no unbounded mode — an unset or absurd value falls back to the default
  rather than disabling the cap.
- **Compilation is bounded too.** `nomuc` gets its own cap (`compile_timeout_sec`, default 120); a compiler
  infinite loop hangs just as silently as a wedged binary.
- **On expiry, kill the whole process group.** Each compile/run is launched in its own process group and
  SIGKILLed as a group on timeout, so a wedged binary and every thread/child it spawned (carriers, the GC-sync
  thread) is reaped rather than orphaned. (A bare per-process kill can leak the runtime's helper threads/
  processes; the group kill is why this is called out.)
- **A timeout is its own result.** Reported as `TIMEOUT`, distinct from `FAIL`, with the phase (compile vs
  run), the carrier/iteration, elapsed time, the partial stdout+stderr captured up to the kill, and the
  copy-pasteable repro command. During 150.4.5.3 a hang cost minutes precisely because it looked identical to
  a slow pass; a distinct status + partial output makes it legible at a glance.
- **Suite-level backstop.** An overall wall-clock deadline (generous default, `--deadline` to override)
  guarantees the whole invocation terminates even if a single case's own cap somehow fails to fire.

## Migration

Incremental. Stand up the runner + manifest, convert a handful of cases (the 150.4 GC set is a good first
batch — they share the compile_env + golden-output shape), keep the remaining `tools/*.sh` working until each
is ported, then retire the scripts. A thin compatibility shim (`tools/<name>.sh` → `compiler-test --enable <name>`)
can bridge muscle memory during the transition.

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
