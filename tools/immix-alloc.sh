#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.2 — the region-structured allocator (rtImmixAlloc), routed
# behind the codegen self-hosted-alloc seam under NOMU_GC_PLAN=nomu. Bump within a 32 KiB block, refill a
# fresh block from the pool on overflow (selfhosted-gc.md §10.3). Non-collecting; the heap only grows.
# Checks:
#   1. examples/immix_alloc.nomu compiles clean (the prelude allocator is auto-subset, task 149).
#   2. Output is correct: 12497500 / 42 / 7 — 5000 allocations spanning three blocks (two refills) plus
#      two post-crossing allocations, all distinct and readable.
#   3. Byte-identical under MMTk NoGC (oracle) and the self-hosted Immix allocator — the differential.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_alloc
fail() { echo "FAIL: $1"; exit 1; }

# 1 — compiles clean (and produces the binary).
errs=$($NOMUC "$ROOT/examples/immix_alloc.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_alloc not clean:\n$errs"

want="12497500
42
7"
# 2 + 3 — correct under the oracle, and identical under the self-hosted Immix allocator.
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
self=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$base" == "$want" ]] || fail "baseline (MMTk NoGC) output: got '$(echo $base)', want '$(echo $want)'"
[[ "$self" == "$base" ]] || fail "self-hosted Immix allocator differs from oracle: got '$(echo $self)'"
echo "PASS: Immix region allocator (150.3.2) — bump + block refill across 3 blocks; byte-identical under MMTk NoGC and self-hosted Immix"
