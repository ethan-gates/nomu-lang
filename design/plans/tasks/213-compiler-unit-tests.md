# Compiler unit tests and test organization

**Avenue:** Infra · **Type/Lifecycle:** `tests · needs-design` · **Size:** M–L · **Status:** needs-design ·
**Source:** `build_tests` takes about 125 s under `bazel test`; nobody has a map of which kinds of tests exist,
what each covers, or where they overlap.

## What

Tests that Bazel runs (`bazel test`), aimed at the pieces of the compiler: one library, or a few, exercised
directly, fast enough to run on every change. Alongside that, an organization of every test the repository has:
the kinds, what each kind is for, where a new test goes, and where two kinds cover the same thing.

## What exists today

- **Bazel unit tests:** 17 `swift_test` targets, about 670 test functions. The largest are `sema` (210),
  `yaml` (144), `ssairpasses` (61), `config` (60) and `planner` (49).
- **Bazel golden tests:** the planner's plan goldens and cfgresolver's goldens, each rewritten through
  `NOMU_UPDATE_GOLDENS`.
- **Bazel end-to-end tests:** `driver:build_tests` runs the fastbuild `nomu` on suite fixtures, each test
  with an empty host cache. A cold build there takes 6.7 s, against 0.9 s for an opt `nomu`. The target
  takes about 200 s with the 210–212 tests.
- **The integration suite:** `compiler-test` over `tests/suite.json` (181 entries, fast and full tiers), built
  and run outside `bazel test`, compiling `tests/fixtures/` and `examples/` and running the binaries.
- **Scripts:** `tools/escape-diff.sh`, `tools/perf-tier.py`, `src/bench`.
- **Libraries without tests:** `frontend/parse`, `frontend/ast`, `frontend/noir`, `llvmgen`, `midend`,
  `support`, `settings`, `buildinfo`, `runtime/embedded`.

## Work

- **213.1** Inventory: every test home, what it covers, how it runs and how long it takes. Mark overlap,
  e.g. `sema`'s unit tests against the suite's diagnostic fixtures, `build_tests` against suite cases that
  build the same fixtures, and the planner goldens against `build_tests`' planning checks.
- **213.2** Kinds and placement: a short definition of each kind (unit, golden, Bazel end-to-end, suite,
  script), what belongs in it, and the rule for where a new test goes. Written as `tests/README.md` and a
  pointer from each `src/*/tests/`.
- **213.3** Unit tests for the untested compiler pieces, by risk: the parser, NOIR, the LLVM egress
  (`llvmgen`), then the rest.
- **213.4** Speed: `build_tests` runs an opt `nomu` (a `compilation_mode=opt` transition on its data
  dependency), and tests that do not exercise a cold cache start from a shared warm one. A time budget for
  `bazel test //...`. The opt transition is done: `opt_binary` (`bazel/opt_binary.bzl`) gives
  `//src/nomu-cli:nomu_opt`, which lands in the same output directory as `bazel build -c opt` and so shares its
  actions; `build_tests` went from 325 s to about 70–80 s. Left: the shared warm cache, which belongs with the test layout
  (tests that run as one workspace over one cache warm it once; tests of an empty or damaged cache keep their
  own).
- **213.5** Act on 213.1's overlap: move, merge or drop tests that check the same thing twice.

## Refs

[155](155-integration-suite-harness.md) (the integration suite); `tests/README.md`;
`src/driver/tests/BuildTests.swift`; 207.4 (the determinism check runs with the suite).
