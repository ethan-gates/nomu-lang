# Compiler cleanups (bucket)

**Avenue:** Infra · **Type/Lifecycle:** `refactor · observability · ready-to-build` · **Size:** S
(each) · **Status:** ready-to-build / opportunistic · **Source:** deferred.md (post-M9 raw list)

A bucket of small, mostly self-contained between-milestone tasks. Each is a pointer; promote to a full
entry if it grows.

## Near-term (small, no gate)

- **Clean up the LLVM experiments** `[small · anytime]` — remove throwaway bring-up scaffolding now
  that 8.x is green: `src/llvmgen/llvm_smoke.cpp`, the `llvmswift_smoke` binary + its `main.swift`,
  dead 8.1 smoke targets. Low risk; shrinks backend surface.
- **`nomuc` startup latency** `[profiled 2026-08-04; fix = opt build]` — `nomuc -h` is ~0.8 s with no
  compilation, path-independent, 99 % CPU: it runs *before* `main` (LLVM global constructors
  registering `cl::opt` + target/pass registries). Only the host target (AArch64) is linked — not
  target bloat. Dominant factor: both `nomuc` and libLLVM are built **fastbuild (unoptimized)**.
  **Fix:** ship/develop with `bazel build -c opt` (optimizes LLVM static-init + strips) — expected to
  cut startup several-fold; measure. No code change; a build-mode choice.
- **LLVM `-O` flag forwarding** `[partly done]` — the `-O`/`--release` toggle landed (8.5.3); remaining
  is finer control (`-O0/1/2/3`, forwarding to the link step) if wanted.

## Compiler infra / pipeline (medium, opportunistic)

- **Dead-code stripping** `[medium]` — strip unreachable functions/symbols (LLVM `internalize` +
  `globaldce`, and/or `-dead_strip` at link). `-O` does some; a deliberate pass would shrink binaries
  (relevant to the [self-hosting](128-self-hosting-runtime.md) < 999 KB ceiling).
- **Emission options** `[medium]` — broaden `--emit-*` / `--stop=` (emit LLVM IR, asm, object choices)
  beyond today's ast/noir/binary. Folds toward [IR/pipeline hardening](142-ir-pipeline-hardening.md).
- **LLVM sub-stage timing split** `[needs-grounding]` — the `codegen` bucket is the whole
  `emitObject` call; split with timing hooks inside `LLVMBridge`. (Note: the phase-categorized timing
  table landed 2026-08-20; this is the residual LLVM-internal split.)
- **Intermediate-based iso regression** `[medium]` — regression tests keyed on intermediate artifacts
  (NOIR / LLVM IR), not just stdout+exit, to localize where a change diverges. Generalized by
  [IR/pipeline hardening](142-ir-pipeline-hardening.md) axis 2.
- **Bazel usage** `[small–medium]` — build-ergonomics cleanup (target layout, incremental friction).
- **Compiler architecture review for perf** `[medium · ongoing]` — a pass over the compiler's own hot
  paths (startup, monomorphization, lowering); the `nomuc -h` latency is one entry point.

## Refs

deferred.md "Post-M9 backlog (raw)", "Compiler self-profiling"; [IR/pipeline hardening](142-ir-pipeline-hardening.md),
[self-hosting](128-self-hosting-runtime.md).
