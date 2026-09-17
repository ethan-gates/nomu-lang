#!/bin/zsh
# Task 150 · rung 4 (GenImmix), increment 150.4.2 — self-hosted log-bit table + write-barrier activation.
# Under NOMU_GC_PLAN=nomu the alloc seam arms the object-remembering barrier (points the inline fast path's
# globals at the descriptor's log-bit side table, sets __nomu_barrier_active) and the C seam routes the slow
# path to the Nomu remembering routine, filling the per-carrier mod-buffer (selfhosted-gc.md §11.2/§11.3).
# Still non-collecting — the minor GC that drains the buffer is 150.4.3.
# Checks:
#   1. examples/gen_barrier.nomu compiles clean (prelude auto-subset, task 149).
#   2. The barrier fires on an old→young store and the fast path elides an already-logged object:
#      1 / 1 / 1 / 3 — the remembered set is empty before the store, grows by exactly one on the store,
#      stays one on a second store to the same object (elided), and the computation reads back.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gen_barrier
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/gen_barrier.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "gen_barrier not clean:\n$errs"

want="1
1
1
3"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: write-barrier activation (150.4.2) — barrier fires on old→young stores, fast path elides an already-logged object, per-carrier mod-buffer fills; non-collecting"
