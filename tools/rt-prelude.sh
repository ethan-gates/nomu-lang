#!/bin/zsh
# Task 150 · rung 1 slice B (foundation) — the runtime prelude. The bump allocator lives in
# src/stdlib/runtime.nomu, compiled into every program (like the core prelude) and runtime-subset by
# default (task 149's proper "designated file", replacing the interim flag). Checks:
#   1. examples/rt_prelude.nomu compiles with NO --runtime-subset flag and calls the prelude allocator
#      (rtArenaNew / rtBumpAlloc) — the prelude functions are designated automatically.
#   2. Output is correct: 7 / 11 (store+load) / 1 (bump adjacency).
#   3. Byte-identical under NoGC and Immix-evacuation (off-heap arena, untouched by the collector).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/rt_prelude
STRESS=${NOMU_GC_STRESS:-512}
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/rt_prelude.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "prelude allocator not clean / not auto-subset:\n$errs"

want="7
11
1"
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$base" == "$want" ]] || fail "baseline output: got '$(echo $base)', want '$(echo $want)'"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector"
echo "PASS: runtime prelude — allocator compiled in + auto-subset (no flag), callable from user code; byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
