#!/bin/zsh
# M6 stdlib · Slice 4 — arrays under the moving collector. Compiles examples/arr_gc.nomu (builds a
# live Array<Box> via append while allocating garbage) and checks its output is identical under NoGC
# and under Immix collecting+evacuating constantly. Byte-identical output proves the variable-size
# buffer is sized/scanned correctly, evacuated, and its element pointers relocated intact.
#
# Expected (both runs): 200 then 19900 (count, and 0+1+…+199).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/arr_gc
STRESS=${NOMU_GC_STRESS:-512}

"$NOMUC" "$ROOT/examples/arr_gc.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
# Evacuation leg under Immix (NOMU_GC_STRESS = collect+defrag every $STRESS bytes; see gc-stress.sh
# on why stress is an Immix, not GenImmix, tool). GenImmix's generational barrier is covered by gc-gen.sh.
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  baseline: $(echo $base)"; echo "  evac:     $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "evac run exited $rc"
[[ "$base" == "200
19900" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "evac output differs from baseline (array relocation bug)"
echo "PASS: Array<Box> byte-identical under NoGC and Immix-evacuation (stress=$STRESS) — buffer + element pointers relocated intact"
