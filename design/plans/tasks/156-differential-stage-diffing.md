# Differential stage-diffing (`nomuc-diff` — every pipeline stage differentiable against a baseline)

**Avenue:** Infra · **Type/Lifecycle:** `tooling · observability · needs-design` · **Size:** L ·
**Status:** needs-design (build-soon; the refactor tracks 154 / 147 / 148 need it now) ·
**Source:** grounded during 150.4.2 — `tools/ir-golden.sh` is a hand-rolled capture/compare of exactly
this, and 154 is already "golden-verifying" extractions by hand.

Make any compiler pipeline stage differentiable: pick an input, a stage, and a baseline (a git ref /
version tag), and get a definitive answer to "is this stage's output identical to the baseline?" — with no
one-off scripts and no tracking where baseline artifacts live. This is what lets us refactor fearlessly:
a behavior-preserving change (source-tree decomposition, IR cleanups, an optimizer rewrite) should produce
byte-identical stage output, and this tool proves it.

## Target UX

```
nomuc-diff --baseline v0.4.2 examples/gc_stress.nomu --stage=ssair
nomuc-diff --baseline HEAD~1 examples/gc_stress.nomu --stage=auto      # infer from staged edits
nomuc-diff --baseline main examples/                  --stage=all      # whole corpus, every stage
```

- `--baseline <ref>` — any git sha, tag, or branch. The tool materializes it (below); the user never
  names an artifact path.
- `--stage=<name>` — `ast | noir | ssair | llvm | run` (final program stdout), a pass (`ssair:inline`),
  `all` (diff every stage, report the first divergence), or `auto` (infer the affected stage(s) from which
  source dirs changed vs the baseline — edits under `src/midend/ssairgen/` ⇒ `ssair`, etc.).
- Exit 0 = identical, nonzero = diverged, with a structured diff.

## Why now

Three active tracks are refactors whose whole safety argument is "output unchanged":
[154 source-tree decomposition](154-source-tree-decomposition.md) (moving code between files),
[147 compiler cleanups](147-compiler-cleanups.md), [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md).
Today that argument is defended by `tools/ir-golden.sh` — capture a snapshot dir before, capture after,
`diff`. It works but is manual: you remember to capture the "before", you manage the snapshot directories,
it covers only NOIR + SSAIR, and it has no notion of a git baseline (you must stash/checkout by hand).
154 is doing this verification by hand right now. Systematize it so a refactor's proof is one command.

## What — the pieces

1. **Canonical per-stage artifacts.** Each stage emits a deterministic, normalized serialization — stable
   ordering, no addresses, no timestamps, stable temp/value naming. The stage-dump surfaces already exist
   (`--emit-ast/-noir/-ssair/-llvm`, `--stop=`); this depends on their output being *canonical*, which is
   [142 IR + pipeline hardening](142-ir-pipeline-hardening.md)'s format discipline. Determinism is the
   hard prerequisite: any nondeterminism (hashmap iteration order, address-derived names) makes a diff
   noisy and the tool worthless. The `run` "stage" is the compiled program's stdout (the object/binary is
   not byte-stable, so behavior is diffed there instead of bytes).

2. **Baseline materialization from a git ref.** Given `--baseline <ref>`, build that ref's compiler once
   (a git worktree at the ref), then run the input through it and the current compiler, writing each
   side's stage artifacts into a plain named build folder the tool owns (e.g.
   `build/diff/<ref>/<input>.<stage>` vs `build/diff/working/<input>.<stage>`) and diffing the two. The
   folder is derived from the ref + input, so the user never names or tracks a path — but it is an ordinary
   directory, inspectable and `rm`-able, not an opaque store.
   - Keep it low-tech: no bespoke content-addressed store for nomuc outputs. If output caching/reuse across
     runs becomes worth it, that is bazel's job — instrument `nomuc` as a bazel action and let bazel's
     cache handle it — rather than hand-rolling a CAS here.
   - Cache only the built baseline **compiler** per ref (a worktree build is the expensive part); re-run
     the cheap stage-emit each invocation.
   - **Committed golden files** per input+stage stay available for CI-pinned expectations, written by the
     same emit path (`--bless`), for cases that want a checked-in baseline rather than a git-ref one.

3. **Stage / pass selection + auto-inference.** `--stage=all` diffs stage-by-stage and localizes the
   first divergence (a regression in `ssair` shows there, not smeared across `llvm` output). Per-pass
   granularity (`ssair:inline`) diffs before/after one pass. `--stage=auto` maps changed source directories
   to affected stages so the common case ("I edited SSAIRGen, prove SSAIR is unchanged") needs no stage
   argument.

4. **Input scope.** A single fixture, a glob, or the whole `examples/` corpus (for "affects all stages"
   changes). Corpus runs share the case discovery + parallel scheduling with
   [155 the integration harness](155-integration-suite-harness.md).

5. **Diff + report.** Identical: green, per stage. Diverged: a unified diff with IR context, the exact
   reproduce commands for both sides, and the first-diverging stage. `--json` for CI. An `--accept` /
   `--bless` path to promote the current output to the committed golden when a change is intentional.

6. **Expected-divergence handling.** Some changes legitimately alter a stage's text (a temp-naming scheme
   changed). Normalization knobs (strip value numbering, sort independent lists) and a way to scope/accept
   a known diff keep the signal clean — otherwise noise defeats the tool.

## Design forks to settle

- **Rebuild-the-ref vs committed goldens** as the primary baseline (see piece 2; lean: rebuild the ref
  into a plain tool-owned build folder, cache only the built baseline compiler; bazel for output caching
  if ever needed, no bespoke CAS).
- **Determinism budget.** How much stage output is deterministic today, and what it costs to make the rest
  so. This gates which stages are differentiable first (NOIR/SSAIR likely already close — `ir-golden.sh`
  relies on it; LLVM IR needs normalization; `run` stdout is already the suite's currency).
- **Auto-stage inference source→stage map.** A maintained mapping from source dirs to pipeline stages;
  cheap to start (a table), needs upkeep as the tree moves (itself a 154 client).
- **Where it lives.** A subcommand of `nomuc` (`nomuc diff …`) vs a sibling tool (`nomuc-diff`). Lean: a
  sibling that drives `nomuc`, so the compiler binary stays a compiler.

## Relationship to 142 and 155

- [142](142-ir-pipeline-hardening.md) is the **prerequisite**: versioned, canonical, round-trippable
  per-stage serialization and stable stage boundaries. This task consumes that to diff; it does not
  re-solve the format.
- [155](155-integration-suite-harness.md) is the **whole-program run harness** (compile + run + expected
  stdout, parallel, tiered). This task is about **intermediate-artifact equality across baselines**. They
  compose: `--stage=run` here is 155's expected-output check, and both share corpus discovery + parallel
  scheduling. Build 155's runner core first; 156 adds the baseline-materialization + stage-artifact engine
  on top.

## Refs

Prior art: `tools/ir-golden.sh` (the manual capture/compare this replaces + extends).
[142 IR + pipeline hardening](142-ir-pipeline-hardening.md) (canonical per-stage format — prerequisite);
[155 integration-suite harness](155-integration-suite-harness.md) (shared corpus + parallel runner);
clients: [154 source-tree decomposition](154-source-tree-decomposition.md),
[147 compiler cleanups](147-compiler-cleanups.md), [148 SSAIR optimizer tier](148-ssair-optimizer-tier.md).
