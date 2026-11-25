# Working in nomu-lang

How to build, run, test, measure and compare the compiler and runtime. Each section points to the document that
holds the detail.

## Layout

- `src/` — the compiler (Swift, C++ for the LLVM passes), the runtime and the standard library (Nomu, under
  `src/stdlib/`). Map: [src/README.md](src/README.md).
- `design/` — the language and internals specs, the near-term plan (`design/plans/horizon.md`) and the task
  backlog (`design/plans/tasks.md`). Map: [design/readme.md](design/readme.md).
- `tests/` — the integration suite: [tests/README.md](tests/README.md).
- `tools/` — measurement and maintenance scripts: [tools/README.md](tools/README.md).
- `benchmarks/` — workloads for the compiler and runtime: [benchmarks/README.md](benchmarks/README.md).
- `practice/` (gitignored) — benchmark programs with their Go twins (`practice/go/`): binary-trees, Richards
  (`practice/gen/richards`). `practice/bench.sh <depth> <runs>` times binary-trees against Go.
- `bin/nomu` — the installed compiler; `.envrc` puts `bin/` on `PATH` (direnv).

## Build the compiler

```
bazel run -c opt //:install        # build, then put the compiler at bin/nomu
```

- Always `-c opt`: a debug compiler runs about 10× slower.
- The runtime and the standard library are compiled into `nomu`, so an edit under `src/stdlib/` needs a rebuild
  and an install like any compiler change.
- Run the compiler from `bin/nomu` or from a snapshot (below). Read, copy or compare nothing under `bazel-bin` or
  `bazel-out`: they point into the shared Bazel cache, and the next build overwrites them.

## Build and run a program

A workspace is a directory with a `nomu.yaml` (`scope:` and `name:`); a package is a subdirectory of it with a
`pkg.json` (`{ "name": "…" }`) beside its `.nomu` files. A package cannot sit at the workspace root. This
repository is one workspace, so `benchmarks/`, `practice/` and `tests/fixtures/` hold packages.

```
nomu build -c release benchmarks/stream_channel    # → build/benchmarks/stream_channel/stream_channel
nomu run -c release <package>
```

- Configs (`-c`, comma-separated or repeated): `debug` (the default) and `release` are built in; the rest are
  in [cfg.yaml](cfg.yaml), e.g. `gc_immix` (the non-generational collector), `gc_record` (the collector's
  report), `no_barrier_elision`, `rt_prelude` (white-box benchmarks that reach the runtime).
- Output goes to `build/<package path>/`. `--emit-llvm`, `--emit-ssair`, `--emit-noir` and `--emit-ast` write
  the entry module's IR beside the binary. Each build's report is `build/_perf/report.json`.
- `--no-history` (hidden) leaves a build out of the build history; scripts use it.
- Compiled modules are cached per host (`~/Library/Caches/nomu`, or `NOMU_CACHE_DIR`).

**Runtime settings** are environment variables read at startup; `src/stdlib/runtime/startup.nomu` documents
each. The common ones: `NOMU_CARRIERS` (threads, 4), `NOMU_GC_PERCENT` (heap growth, 100), `NOMU_HEAP_MAX`,
`NOMU_NURSERY_RESERVE` (nursery blocks), `NOMU_GC_VERIFY=1` (check the collector's invariants), `NOMU_GC_STRESS`,
`NOMU_PREEMPT=0`. With `-c gc_record`, `NOMU_GC_REPORT_DIR=<dir>` writes the collector's report there (JSON:
each collection, its phases and counters, pauses, promotion, peak heap).

## Test

```
bazel build -c opt //src/nomu-cli:nomu //src/compiler-test:compiler-test
bazel-bin/src/compiler-test/compiler-test tests/suite                         # fast tier
bazel-bin/src/compiler-test/compiler-test tests/suite --tier full --repeat 3  # before a runtime change lands
```

`--compiler <path>` tests another compiler (a snapshot). Selection, tiers and adding cases:
[tests/README.md](tests/README.md). Unit tests are Bazel targets (`bazel test //src/...`); `bazel test` repoints
`bazel-bin` to a fastbuild compiler, one more reason to run compilers from `bin/` or a snapshot.

## Compare compilers

Keep each variant as a snapshot, then run each by its path ([tools/README.md](tools/README.md), task 257):

```
bazel run -c opt //:publish -- --label before --memo "what this variant tries"
# … make the change …
bazel run -c opt //:publish -- --label after --memo "…"
tools/snapshot.py list
$(tools/snapshot.py path before) build -c release practice/gen/richards && cp build/practice/gen/richards/richards /tmp/r-before
```

- A snapshot's identity is the commit plus a hash of uncommitted changes, so publish the tree as it stands; to
  set a change aside, `git stash push -- <path>`, publish, then `git stash pop`.
- Run the variants' binaries interleaved, many rounds, and compare best and median.
- The host cache keys every module by the compiler's identity, so snapshots never share cache entries. Variants
  switched inside one compiler (an environment variable read by the compiler) do share them: give each its own
  `NOMU_CACHE_DIR`.
- The scheduler workloads take a compiler directly: `SCHEDBENCH_NOMU=<path> tools/schedbench.py …`.

## Measure

- Scheduler: `tools/schedbench.py` (workloads × settings × carrier counts). Collector: `tools/gc-baseline.py`,
  and `-c gc_record` with `NOMU_GC_REPORT_DIR`. Optimizer passes: `tools/perf-tier.py`. Stops and preemption:
  `tools/stopbench.py`. Each is described in [tools/README.md](tools/README.md).
- Against Go: `practice/go/` holds the twins; `practice/bench.sh` runs binary-trees in both.

## Shell habits

- Join steps that depend on each other with `&&`, so a failed step stops the rest (a `;` chain runs on and
  can, for instance, overwrite a source file after the step meant to save it failed).
- Put scratch files outside the tree.
