#!/bin/zsh
# Task 128.1.1 · scheduler substrate — atomics. Compiles examples/atomics.nomu (the i64 seq-cst atomic
# ops over an off-heap RawPtr slot: atomicStore/atomicLoad/atomicFetchAdd/atomicCas/atomicExchange,
# single-thread and deterministic) and checks its output. A second leg runs under the moving collector
# (Immix, collecting+defragging constantly): the atomics address unmanaged addrspace(0) memory the
# collector never relocates, so the output must be byte-identical whether or not a collection is running.
#
# Expected (both legs): 100 / 100 / 105 / 105 / 200 / 200 / 200 / 200 / 55.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/atomics
STRESS=${NOMU_GC_STRESS:-512}

"$NOMUC" "$ROOT/examples/atomics.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

want="100
100
105
105
200
200
200
200
55"
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  want: $(echo $want)"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "moving-collector run exited $rc"
[[ "$base" == "$want" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector (atomics address raw memory, untouched by GC)"
echo "PASS: atomics (store/load/fetchAdd/cas/exchange, i64 seq-cst) — byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
