#!/bin/zsh
# Task 125 · slice 1 — RawPtr round-trip. Compiles examples/raw_mem.nomu (allocates an off-heap block,
# stores/loads Ints at byte offsets, exercises pointer arithmetic and a byte element, frees) and checks
# its output. A second leg runs under the moving collector (Immix, collecting+defragging constantly): a
# RawPtr addresses unmanaged addrspace(0) memory the collector never relocates, so the output must be
# byte-identical whether or not a collection is running.
#
# Expected (both legs): 42 / 7 / 99 / 255.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/raw_mem
STRESS=${NOMU_GC_STRESS:-512}

"$NOMUC" "$ROOT/examples/raw_mem.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

want="42
7
99
255"
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  want: $(echo $want)"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "moving-collector run exited $rc"
[[ "$base" == "$want" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector (raw pointer should be untouched by GC)"
echo "PASS: RawPtr round-trip (alloc/store/load/advanced/free) — byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
