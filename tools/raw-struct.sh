#!/bin/zsh
# Task 125 · slice 3 — RawPtr composition, shareability, identity. Compiles examples/raw_struct.nomu
# (a value struct with a RawPtr field; a RawPtr crossing a spawn boundary; RawPtr.null / isNull / eq)
# and checks its output. A RawPtr is a value word carrying no managed pointer, so: it composes into a
# plain aggregate (no category-3 relocation problem), it is shareable across tasks, and it is untouched
# by the moving collector — the second leg confirms byte-identical output under Immix-evacuation.
#
# Expected (both legs): 123 / 456 / 123 / 1 / 0 / 1 / 0.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/raw_struct
STRESS=${NOMU_GC_STRESS:-512}

"$NOMUC" "$ROOT/examples/raw_struct.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

want="123
456
123
1
0
1
0"
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  want: $(echo $want)"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "moving-collector run exited $rc"
[[ "$base" == "$want" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "output differs under the moving collector"
echo "PASS: RawPtr composition (struct field) + shareability (crosses spawn) + identity (null/isNull/eq) — byte-identical under NoGC and Immix-evacuation (stress=$STRESS)"
