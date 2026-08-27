#!/bin/zsh
# Task 150 · rung 1 (NoGC), slice A — the bump allocator written in Nomu (over task-125 raw memory, under
# task-149's subset rules). Three checks:
#   1. Compiles under `--runtime-subset=bumpNew,bumpAlloc` with no violations — the allocator obeys the
#      runtime-subset rules (no implicit GC allocation; only raw-memory primitives), the 125↔149 interlock
#      exercised by a real client.
#   2. Output is correct: 42 / 99 (store+load round-trip), 1 (b is bump-adjacent to a), 1 (overflow → null).
#   3. Byte-identical under NoGC and Immix-evacuation — the arena is off-heap addrspace(0) memory the
#      moving collector never relocates.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/bump_alloc
STRESS=${NOMU_GC_STRESS:-512}
fail() { echo "FAIL: $1"; exit 1; }

# 1 — subset-legal (and produces the binary).
errs=$($NOMUC --runtime-subset=bumpNew,bumpAlloc "$ROOT/examples/bump_alloc.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "allocator is not runtime-subset-legal:\n$errs"

want="42
99
1
1"
# 2 + 3 — correct, and identical whether or not the moving collector is running.
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$base" == "$want" ]] || fail "baseline output: got '$(echo $base)', want '$(echo $want)'"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector (arena should be untouched)"
echo "PASS: NoGC bump allocator in Nomu (subset-legal; store/load + bump-adjacency + overflow→null) — byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
