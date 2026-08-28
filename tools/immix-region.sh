#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.1 — the region substrate. The block/line geometry, the side
# metadata tables (line marks, block state), the addr↔index math, and the block/line state transitions,
# written in the runtime prelude over 125 raw memory (selfhosted-gc.md §10.1/§10.2). No allocation policy
# or collection yet. Checks:
#   1. examples/immix_region.nomu compiles with NO --runtime-subset flag — the prelude functions
#      (rtImmixNew / rtAcquireBlock / rtBlockIndexOf / …) are auto-designated runtime-subset (task 149).
#   2. Output is correct: block pool adjacency, addr→block/line index math, block-state + line-mark
#      transitions, pool exhaustion → null.
#   3. Byte-identical under NoGC and Immix-evacuation — the region is off-heap addrspace(0) memory the
#      moving collector never relocates.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_region
STRESS=${NOMU_GC_STRESS:-512}
fail() { echo "FAIL: $1"; exit 1; }

# 1 — subset-legal (and produces the binary).
errs=$($NOMUC "$ROOT/examples/immix_region.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "region substrate not clean / not auto-subset:\n$errs"

want="1
1
2
261
5
2
1
0
1
0
0
1"
# 2 + 3 — correct, and identical whether or not the moving collector is running.
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$base" == "$want" ]] || fail "baseline output: got '$(echo $base)', want '$(echo $want)'"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector (region should be untouched)"
echo "PASS: Immix region substrate (150.3.1) — blocks/lines + side tables + addr↔index math + state transitions; auto-subset; byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
