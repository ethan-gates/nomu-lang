#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.7 — evacuation + pointer fixup (selfhosted-gc.md §10.6/§10.7).
# rtImmixEvacCollect force-evacuates every reachable in-heap object into fresh to-space (rtCopyObject +
# forwarding record, §10.8) and rewrites every managed slot and the root to the survivor's new address as the
# trace visits it; the emptied from-space is then reclaimed by the 150.3.5 sweep.
#
# NOMU_NO_ESCAPE=1 so the Boxes are heap-allocated (addrOf sees real heap addresses). Runs under
# NOMU_GC_PLAN=nomu (the self-hosted heap the copies land in). Checks:
#   1. examples/immix_evac.nomu compiles clean (prelude auto-subset, task 149).
#   2. Move + fixup + reclaim: 1 / 1 / 111 / 1 / 1 — the root moved, a live Box moved and its value reads back
#      through the fixed-up element slot, the address-independent fingerprint is invariant across the move (a
#      missed fixup would diverge it), and from-space blocks were reclaimed.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_evac
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/immix_evac.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_evac not clean:\n$errs"

want="1
1
111
1
1"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: Immix evacuation + pointer fixup (150.3.7) — live set force-evacuated to new addresses, slots + root fixed up, fingerprint invariant, from-space reclaimed"
