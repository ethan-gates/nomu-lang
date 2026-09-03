#!/bin/zsh
# Task 128.2 · asm floor driven from Nomu — single-fiber context round-trip. Compiles
# examples/fiberswitch.nomu, where the fiber entry is a Nomu function reached via RawPtr.ofFunc and main
# drives the switch through the RawPtr intrinsics (fiberInit / ctxSwitchTo). Proves the whole capability
# composes: a top-level function's C-ABI address (ofFunc) + the asm floor (rtFiberInit/rtSwitch), a
# Nomu-seeded fiber running on its own stack and returning control cleanly → 42. A second leg runs under
# the moving collector: all memory is off-heap, so the result is unchanged.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/fiberswitch.nomu
BIN=$ROOT/build/examples/fiberswitch
STRESS=${NOMU_GC_STRESS:-512}
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile"
out=$("$BIN" 2>/dev/null)
[[ "$out" == "42" ]] || fail "fiber round-trip: got '$out', want 42 (ofFunc + fiberInit + ctxSwitchTo)"

evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
[[ "$evac" == "42" ]] || fail "result differs under the moving collector (got '$evac')"

echo "PASS: fiber round-trip driven from Nomu — RawPtr.ofFunc entry + rtFiberInit/rtSwitch, GC-independent"
