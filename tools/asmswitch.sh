#!/bin/zsh
# Task 128.2 · asm floor — arm64 context-switch isolation test. Compiles examples/asmswitch.nomu and
# checks that the hand-written context switch round-trips: `RawPtr.asmSelfTest()` seeds a fiber, switches
# into it (rtSwitch over the rtFiberInit-seeded stack), the fiber records its argument and switches back,
# and the recorded value survives → 1. This is the design's "test the asm floor in isolation first" step,
# before any scheduler rides it. A second leg runs it under the moving collector: the switch touches only
# off-heap/static memory, so the result is unchanged.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/asmswitch.nomu
BIN=$ROOT/build/examples/asmswitch
STRESS=${NOMU_GC_STRESS:-512}
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile"
out=$("$BIN" 2>/dev/null)
[[ "$out" == "1" ]] || fail "context-switch round-trip: got '$out', want 1 (rtSwitch/rtFiberInit)"

evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$evac" == "1" ]] || fail "result differs under the moving collector (got '$evac')"

echo "PASS: asm floor — arm64 rtSwitch/rtFiberInit round-trip preserves the fiber (isolation test); GC-independent"
