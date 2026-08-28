#!/bin/zsh
# Task 150 · rung 2 (mark-verify) — the MMTk-side fingerprint (the independent oracle), diffed against the
# self-hosted Nomu tracer in a single run under immix.
#
# examples/mark_verify_oracle.nomu holds one live managed graph (an Array<Box>: handle + buffer + 3 Boxes).
# RawPtr.gcForceCollect() forces one GC; under NOMU_GC_MARKVERIFY the MMTk binding folds every live object
# it traces into MMTK-FP (B) over its authoritative live set. Then the self-hosted pcsp walk (rtCollectRoots)
# recovers the same real stack roots and rtMarkVerify folds the same address-independent hash over the
# tracer's live set, printed as FP (A). Both trace the same real roots, so A == B is the apples-to-apples
# cross-run diff: a missed live object or a wrongly-marked dead one moves one sum and not the other.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

$NOMUC "$ROOT/examples/mark_verify_oracle.nomu" >/dev/null 2>&1 || fail "compile mark_verify_oracle"

got=$(NOMU_GC_PLAN=immix NOMU_GC_MARKVERIFY=1 "$ROOT/build/examples/mark_verify_oracle" 2>/dev/null) \
  || fail "mark_verify_oracle nonzero exit"

# total must be the full graph: handle + buffer + 3 Boxes = 5.
echo "$got" | grep -q '^total 5$' || { echo "FAIL: live-set total (expected 5)"; echo "$got"; exit 1; }

# A: the Nomu tracer's fingerprint. B: MMTk's — the forced GC is the last collection, so take the last
# MMTK-FP line (any heap-pressure GC during setup would print an earlier, partial one).
A=$(echo "$got" | grep '^FP ' | sed 's/^FP //')
B=$(echo "$got" | grep '^MMTK-FP ' | tail -1 | sed 's/^MMTK-FP //')

[[ -n "$A" && "$A" != "0" ]] || { echo "FAIL: missing/trivial Nomu fingerprint (A)"; echo "$got"; exit 1; }
[[ -n "$B" && "$B" != "0" ]] || { echo "FAIL: missing/trivial MMTk fingerprint (B) — did the forced GC trace?"; echo "$got"; exit 1; }
[[ "$A" == "$B" ]] || { echo "FAIL: fingerprints differ — Nomu tracer live set != MMTk live set (A=$A B=$B)"; echo "$got"; exit 1; }

echo "PASS: MMTk live-set fingerprint ($B) matches the self-hosted Nomu tracer ($A) — the mark-verify cross-run diff, both tracing real roots"
