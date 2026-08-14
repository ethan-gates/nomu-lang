#!/bin/zsh
# M6 · 6.2.4 moving-GC evacuation stress: prove the NoGC→Immix flip evacuates correctly. Compiles
# examples/gc_stress.nomu, runs it once under NOMU_GC_PLAN=nogc (the pre-flip baseline) and once under
# NOMU_GC_STRESS (Immix collecting + defragging constantly, so live objects move every cycle), and
# checks the two outputs match. Byte-identical output across hundreds of evacuations proves live roots
# and managed interior references are relocated intact and garbage is reclaimed.
#
# Expected (both runs): 42 / 7 / 42 / 499500 — pair.a.v, pair.b.v, inner.v (all survived moves), sum.
set -u
# 6.5.2: pin escape analysis off so leaf heap roots this collector test relies on are not stack-promoted.
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gc_stress
STRESS=${NOMU_GC_STRESS:-1024}   # bytes-between-collections; smaller = more GCs

"$NOMUC" "$ROOT/examples/gc_stress.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

# The evacuation leg runs under Immix (the non-generational moving plan): NOMU_GC_STRESS drives a
# collect+defrag every $STRESS bytes, so every live object relocates. GenImmix is validated separately
# by gc-gen.sh — under an aggressive stress the generational collector's own evacuation allocations
# re-trip the byte trigger (a nested GC the single worker can't service), so stress is an Immix tool.
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null)
rc=$?

fail() { echo "FAIL: $1"; echo "  baseline: $(echo $base)"; echo "  evac:     $(echo $evac)"; exit 1; }
[[ $rc -eq 0 ]] || fail "evac run exited $rc"
[[ "$base" == "42
7
42
499500" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "evac output differs from baseline (relocation bug)"
echo "PASS: gc_stress byte-identical under NoGC and Immix-evacuation (stress=$STRESS) — roots + interior refs relocated intact"
