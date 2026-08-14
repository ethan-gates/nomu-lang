#!/bin/zsh
# 6.5.3 — a NON-LEAF non-escaping class (a field holding a managed pointer) is stack-allocated with
# escape analysis ON, and its interior managed pointer is a real GC root. SROA scalar-replaces the
# stack object so the field becomes an addrspace(1) SSA value the statepoint rewriter relocates; no
# interior stack-map scanning is needed. This test proves that under the moving collector: `Holder` is
# stack, its `inner` points at a heap `Inner` that must survive and relocate across evacuations while
# `Holder` is live across `churn`. Unlike the gc-*.sh collector tests, escape analysis is ON here.
# Byte-identical output under NoGC and Immix-evacuation proves the interior root is scanned + relocated;
# a divergence or crash under Immix would mean the stack object's managed field went unscanned.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/escape_nonleaf
STRESS=${NOMU_GC_STRESS:-512}   # collect+defrag every N bytes; smaller = more evacuations
fail() { echo "FAIL: $1"; echo "  base: $(echo $base)"; echo "  evac: $(echo $evac)"; exit 1; }

"$NOMUC" "$ROOT/examples/escape_nonleaf.nomu" >/dev/null 2>&1 || { echo "FAIL: compile"; exit 1; }
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS "$BIN" 2>/dev/null); rc=$?

[[ $rc -eq 0 ]] || fail "evac run exited $rc"
[[ "$base" == "12345
7
4999950000" ]] || fail "baseline output unexpected"
[[ "$evac" == "$base" ]] || fail "evac output differs — the non-leaf stack object's interior managed pointer was not relocated"
echo "PASS: escape-nonleaf — non-leaf Holder stack-allocated; interior heap pointer relocated intact across Immix evacuation (escape on)"
