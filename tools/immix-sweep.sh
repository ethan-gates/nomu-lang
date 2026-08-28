#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.5 — sweep reclamation, the first functioning self-hosted
# collector (non-moving; evacuation is 150.3.7). A collection marks the live set (header + line marks),
# reclaims by line/block (dead blocks → free list, mixed → recyclable) and by whole LOS chunk, then the
# hole-aware allocator reuses reclaimed + recyclable space (selfhosted-gc.md §10.4/§10.5).
#
# NOMU_NO_ESCAPE=1 so garbage Boxes are heap-allocated. Runs under NOMU_GC_PLAN=nomu (the self-hosted heap).
# Checks:
#   1. examples/immix_sweep.nomu compiles clean (prelude auto-subset, task 149).
#   2. Reclamation + reuse + survival: 1 / 1 / 111 / 222 / 2 — blocks reclaimed, heap did not grow across a
#      second equal garbage batch, live objects survived and read back.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_sweep
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/immix_sweep.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_sweep not clean:\n$errs"

want="1
1
111
222
2"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: Immix sweep reclamation (150.3.5) — blocks reclaimed, heap reused (no growth across a second garbage batch), live objects survived; first functioning self-hosted collector"
