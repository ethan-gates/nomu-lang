#!/bin/zsh
# Task 150.4.5.1.1 — large-object-space remembered-set. A large Array<Box> buffer (>32 KiB) lives in the
# off-heap large-object space: never in the nursery, never moved, no write-barrier log bit. A young Box stored
# into it is a mature→young pointer the barrier's heap-range guard skips and the remembered set never captures,
# so the minor GC must treat every live LOS object as an old root and scan it. Without that scan the young Box
# (reachable only through the off-heap buffer) is reclaimed and the read is wrong.
# Checks: (1) examples/gc_los_gen.nomu compiles clean; (2) self-hosted generational == MMTk GenImmix oracle
# (777); (3) deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gc_los_gen
fail() { echo "FAIL: $1"; exit 1; }
errs=$($NOMUC "$ROOT/examples/gc_los_gen.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "gc_los_gen not clean:\n$errs"
want=$("$BIN" 2>/dev/null)
[[ "$want" == "777" ]] || fail "MMTk oracle != 777 (got '$want')"
for i in 1 2 3 4 5; do
  got=$(NOMU_RUNTIME=selfhost NOMU_GC_PLAN=nomu NOMU_SCHED=nomu NOMU_NURSERY_RESERVE=32 NOMU_CARRIERS=1 "$BIN" 2>/dev/null)
  [[ "$got" == "777" ]] || fail "self-hosted generational != 777: run $i got '$got' — the LOS remembered-set scan dropped a mature-LOS→young pointer"
done
echo "PASS: large-object-space remembered set (150.4.5.1.1) — a young Box stored into a mature off-heap LOS buffer survives repeated minor GCs via the LOS root scan, checksum-identical to MMTk GenImmix (777)"
