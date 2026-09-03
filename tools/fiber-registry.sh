#!/bin/zsh
# Task 128.1.6 · live-fiber registry (isolation). Compiles examples/fiber_registry.nomu with the registry
# ops designated runtime-subset — proving they are subset-legal (raw links only, no managed alloc, no
# safepoint), as a scheduler that maintains the registry on the carrier under the scheduler lock requires
# — and checks that intrusive insert, O(1) remove of an arbitrary node (middle / head / tail), and full
# iteration report the right live set at each step:
#   build 5      → 5 15
#   remove middle → 4 12
#   remove head   → 3 7
#   remove tail   → 2 6
# A second leg runs under the moving collector: the registry lives in off-heap raw memory the collector
# never relocates, so the output is unchanged.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/fiber_registry.nomu
BIN=$ROOT/build/examples/fiber_registry
SUB=regInsert,regRemove,regCount,regSum
STRESS=${NOMU_GC_STRESS:-512}
want=$'5 15\n4 12\n3 7\n2 6'
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "registry ops not subset-legal / did not compile"
out=$("$BIN" 2>/dev/null)
[[ "$out" == "$want" ]] || fail "live set: got '$(echo $out)', want '5 15 / 4 12 / 3 7 / 2 6'"

evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$evac" == "$want" ]] || fail "output differs under the moving collector (got '$(echo $evac)')"

echo "PASS: live-fiber registry — intrusive insert + O(1) remove (middle/head/tail) + iteration, subset-legal, GC-independent"
