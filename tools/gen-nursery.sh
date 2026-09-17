#!/bin/zsh
# Task 150 · rung 4 (GenImmix), increment 150.4.1 — nursery substrate. Under NOMU_GC_PLAN=nomu a clean block
# a mutator TLAB pulls is tagged NURSERY and counted in nurseryUsed (selfhosted-gc.md §11.1); the bounded
# reserve is 1/4 of the pool. This increment is non-collecting (the minor GC keying off the tag is 150.4.3),
# so the nursery only grows.
# Checks:
#   1. examples/gen_nursery.nomu compiles clean (prelude auto-subset, task 149).
#   2. Young allocation lands in the nursery and stays bounded: 1 / 1 / 1 / 199990000 — nurseryUsed > 0,
#      equals the blocks handed out (all young before any collection), and is under the reserve; the
#      computation reads back.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gen_nursery
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/gen_nursery.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "gen_nursery not clean:\n$errs"

want="1
1
1
199990000"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: nursery substrate (150.4.1) — young allocation tagged NURSERY + counted, bounded by the reserve; non-collecting"
