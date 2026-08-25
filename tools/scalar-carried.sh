#!/bin/zsh
# 7.3.1 — a loop-carried NON-LEAF non-escaping class (`Node`, reassigned to a fresh allocation each
# iteration) scalarizes under the SSAIR tier, and its carried managed field (`inner`) is a real GC root
# across the loop. Scalar promotion (m7-spec §7.3.1) decomposes the loop-carried Node into per-field SSA
# values; `inner` becomes an addrspace(1) SSA value threaded through the loop φ. That value is the only
# reference to the heap `Inner(v: 12345)`, live across `churn`, which drives evacuations. Byte-identical
# output under NoGC and Immix-evacuation proves the scalarized managed field is scanned + relocated at
# the loop-header poll; a divergence or crash under Immix would mean it went untracked.
#
# Compiled under the SSAIR egress (the tier that owns the pass) with escape analysis ON. Until §7.3.1
# lands, `Node` stays heap (loop-carried pointer φ) and this passes as a ready regression gate; once it
# lands, it exercises the scalarized-root relocation. Sibling of tools/escape-nonleaf.sh (the non-loop
# non-leaf case).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/scalar_carried_nonleaf
STRESS=${NOMU_GC_STRESS:-512}   # collect+defrag every N bytes; smaller = more evacuations
want="12345
50
99950000"
fail() { echo "FAIL: $1"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }

NOMU_EGRESS=ssair "$NOMUC" "$ROOT/examples/scalar_carried_nonleaf.nomu" >/dev/null 2>&1 || { echo "FAIL: compile"; exit 1; }
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null); rc=$?

[[ $rc -eq 0 ]] || fail "evac run exited $rc"
[[ "$base" == "$want" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "evac output differs — the scalarized loop-carried managed field was not relocated"
echo "PASS: scalar-carried — loop-carried non-leaf Node scalarized; carried heap pointer relocated intact across Immix evacuation (ssair egress, escape on)"
