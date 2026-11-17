# Compiler dev loop: A/B benchmarks, `compiler-test` with snapshots, a faster suite

**Avenue:** Infra · **Type/Lifecycle:** `tooling · needs-design` · **Size:** M · **Status:** not started; 265.2 and 265.3 build on [257](257-toolchain-version-manager.md) (done) ·
**Source:** 250.8.2, whose acceptance needed every benchmark compared against the build before it, and every
comparison was set up by hand.

For compiler developers. Keeping compilers is [257](257-toolchain-version-manager.md) (the toolchain version manager);
this task compares them and speeds up the suite. Split from 257, which held both.

## Why

Comparing two compilers today takes these steps by hand:
- an opt rebuild of the compiler for each variant, after undoing or redoing the change;
- compiling each benchmark with it and copying the binaries into a scratch directory;
- an ad hoc script to run them, which differs per session.

Several things go wrong along the way:
- `bazel test` repoints `bazel-bin` to the fastbuild compiler, and a benchmark build picks it up.
- `compiler-test` takes the newest opt build. That build can predate the source, for example after a runtime
  edit without a rebuild, and nothing says so.
- Medians of 30 to 60 runs could not settle differences under about 0.5 ns. 250.8.2 needed a paired run with a
  control to resolve them.

The benchmark tools (`tools/pingpong.py`, `schedbench.py`, `perf-tier.py`, `gc-baseline.py`,
`frames-ceiling.py`) each build, run and summarize in their own way, and none compares two compilers.

The suite takes about 30 s for the fast tier and 120 s for the full tier. Nobody has measured where that time
goes.

"Faster" covers both setup (steps done by hand) and run time, where the runs stay as sound and as accurate as
they are now.

## The setup done by hand for 250.8.2

This is the work 257 and 265.3 to 265.4 replace. Each step was a scratch script written during the session.

1. **Keep the old source.** The changed runtime, assembly and compiler files were copied into snapshot
   directories (`src/stdlib/runtime/`, `rtasm_arm64.s`, `StackChecks.cpp`, `FrameTable.swift`,
   `LLVMGenRuntime.swift`). A list kept by hand chose which files, and a file left off it would have built a
   mixed variant without any error.
2. **Swap a variant in.** A script copied one snapshot over the tree, rebuilt, then copied the current files back.
   An interrupted run would have left the tree on the old variant.
3. **Rebuild the compiler.** `bazel build -c opt //src/nomu-cli:nomu`, once per variant, since the runtime is
   bundled into the binary.
4. **Build the benchmarks.** Five benchmarks, each with its own flags (`--config=runtime_tier
   --runtime-subset=…` for `ctx_swap`, `--config=rt_prelude` for `pingpong_fiber`), with the path to the opt
   compiler written out, and each binary copied from `build/benchmarks/<name>/` into a directory per variant.
   Fifteen such directories piled up in the session.
5. **Run them.** Four runners in turn:
   - `schedbench.py` and `pingpong.py`: best or median of 9, one variant at a time. Drift between the two runs
     exceeded the differences under study.
   - `ab.py`, then `abmulti.py`: interleaved runs of two or more directories, medians of 31 to 61. These could
     not settle differences under about 0.5 ns.
   - `paired.py`: paired samples with a bootstrap interval, plus a control of the old binary against a copy of
     itself.
6. **Parse results.** Each runner parses each benchmark's output with its own regular expression. Each benchmark
   prints a different line.
7. **Measure memory.** A separate loop of `/usr/bin/time -l` over `parked_fibers` for peak RSS.

Problems that cost time:
- A `bazel test` in between pointed `bazel-bin` at the fastbuild compiler, which hits the FCA assertion
  when it compiles the benchmarks.
- A leftover `fiber_leak` process spun on one core during several benchmark rounds and skewed them.
- The control showed intervals that exclude zero between identical binaries (`pingpong_channel` at 1 carrier
  −0.5 ns, `forkjoin_fiber` at 1 carrier −1.0 ns over 300 pairs). The cause is the file: each copy of a binary
  keeps a speed of its own, up to about 0.8 ns a hop on `pingpong_channel`, likely from where its pages land in
  physical memory. One byte-identical build measured +0.18 ns in one session and +0.71 in the next. Running
  every sample from a fresh copy of the binary removed the bias: the control's interval went to [−0.09, +0.07].
- A first layout check padded the runtime with an unused function. The function is stripped, so only the code
  after it and the data addresses moved.
- macOS places a benchmark thread on P or E cores as it chooses, and the share moves between runs (12–19% on
  E cores for `pingpong_channel` at 1 carrier). A change that is faster on P cores and slower on E cores reads
  as faster or slower by wall clock depending on that share. This decided 250.8.2's channel result.
- Instruments' CPU Counters instrument reads counters per process and per core type without root, from a
  template in Manual mode (sampling on `CORE_ACTIVE_CYCLE`; events `INST_ALL`, `BRANCH_MISPRED_NONSPEC`,
  `BRANCH_RET_INDIR_MISPRED_NONSPEC`). `L1D_CACHE_MISS_LD_NONSPEC` conflicts with that set on the M3 Max.
  `xctrace record --template … --launch` records a run; the `kdebug-counters-with-pmi-sample` table holds the
  core's raw counters at each sample, and deltas between consecutive samples of one thread on one core give
  exact counts for that window.

## Plan

- **265.1 Measure the loop.** Time each step of the procedure above and record which ones failed or were
  repeated. Split the suite's wall time into compiling, linking, running and the harness's own
  overhead, per tier. Time an opt rebuild after a runtime-only edit and after a compiler edit. Time a benchmark
  build per compiler. The results choose what 265.5 does.
- **265.2 `compiler-test` and snapshots** (snapshots from [257](257-toolchain-version-manager.md)):
  - `compiler-test --compiler <id|label|path>` accepts a snapshot.
  - `compiler-test` compares its compiler's identity with the working tree's. When they differ, it prints
    both and names the rebuild command.
- **265.3 One A/B benchmark runner.** `tools/bench --compilers a,b [cases]`:
  - builds each benchmark once per compiler, through the host cache;
  - runs paired samples: A and B back to back, order alternating, recording B − A, each sample from a fresh
    copy of its binary;
  - can build each side at several code layouts and compare across them, so one lucky layout cannot decide a
    verdict;
  - reports counter-based cycles and instructions per unit of work, per core type, beside wall time, for
    differences too small for wall time to settle, from a counters template checked in under `tools/`;
  - runs a control of A against a copy of itself, which measures the noise on this machine now;
  - checks for other busy processes before it starts and reports any it finds;
  - reports per case the medians, the median paired difference and its bootstrap 95% interval, plus a verdict:
    - faster: the interval lies below zero;
    - slower: the interval lies above zero;
    - equal: the interval lies inside the control's band;
    - unresolved: anything else.
  - Each benchmark prints one result line in a common format, so cases are listed in a table instead of parsed
    per benchmark.
  - The existing benchmark tools move onto this runner's build and run steps and keep their own sweeps.
- **265.4 Adaptive sample counts.** Sample each case until its verdict resolves or a cap is reached, instead of
  a fixed count. Quick cases finish early; close cases get the samples they need.
- **265.5 Suite run time.** Act on 265.1's findings and keep each change only if the suite still catches what it
  catches today (155's `--compiler` teeth check against a pre-fix build). Candidates to evaluate:
  - fixtures shared by several cases and tiers compile once through the host cache;
  - fewer links, where several runs differ only in run settings;
  - repack the pool by the measured split instead of whole-case weights.

## Relations

- [155](155-integration-suite-harness.md) owns the suite harness; 265.2's `--compiler` and staleness check
  land in it. 155's deferred perf gate stays deferred. 265.3's runner is the comparison it would build on.
- [256](256-host-cache-store-only.md): snapshots and the A/B builds rely on compiler identity in cache keys.
- [250](250-fiber-task-surface.md) 250.8.3 measures with 265.3's runner once it exists.
- [257](257-toolchain-version-manager.md) keeps the compilers this task compares.
