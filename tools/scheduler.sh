#!/bin/zsh
# Task 128.1.3 · single-carrier run queue + spawn / park / unpark / join, written in Nomu over the
# scheduler substrate. Compiles examples/scheduler.nomu with the scheduler functions designated
# runtime-subset — which also proves they are subset-legal (allocate only off-heap, call only substrate
# primitives + each other, no safepoint poll) — and checks the three scenarios:
#   1. three fibers each add to a shared accumulator, run to completion → 6   (spawn + run queue + trampoline)
#   2. a park/unpark handoff between two fibers                        → 111 (park + unpark)
#   3. one fiber computes a value, another joins and reads it          → 42  (join)
# A second leg runs under the moving collector: the scheduler touches only off-heap memory, so the output
# is unchanged.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler.nomu
BIN=$ROOT/build/examples/scheduler
SUB=enqueue,dequeue,schedRun,fiberMain,fiberSpawn,park,unpark,joinFiber
STRESS=${NOMU_GC_STRESS:-512}
want=$'6\n111\n42'
fail() { echo "FAIL: $1"; exit 1; }

# The subset designation must compile — the scheduler is runtime-subset code.
"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler is not subset-legal / did not compile"
out=$("$BIN" 2>/dev/null)
[[ "$out" == "$want" ]] || fail "scenarios: got '$(echo $out)', want '6 111 42'"

evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$evac" == "$want" ]] || fail "output differs under the moving collector (got '$(echo $evac)')"

echo "PASS: single-carrier scheduler (spawn/run/complete=6, park/unpark=111, join=42) — subset-legal, GC-independent"
