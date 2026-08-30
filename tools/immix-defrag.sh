#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.8 — copy reserve + defrag trigger (selfhosted-gc.md §10.6/
# §10.13). rtImmixCollectDefrag replaces force-all: it selects only fragmented blocks (live-line count from
# the last sweep's defragTable histogram, ≤ threshold) as evacuation sources, bounded by a copy reserve so
# to-space never runs out mid-collection, evacuates their survivors while marking everything else in place,
# then reclaims the emptied sources by the 150.3.5 sweep.
#
# NOMU_NO_ESCAPE=1 so the Boxes are heap-allocated. Runs under NOMU_GC_PLAN=nomu (the self-hosted heap).
# Checks:
#   1. examples/immix_defrag.nomu compiles clean (prelude auto-subset, task 149).
#   2. Selective evacuation + compaction: 1 / 1 / 1000 / 1 / 1 — the first collection did not move the root
#      (the trigger is selective, not force-all), a survivor then moved and its value reads back through the
#      fixed-up slot, the address-independent fingerprint is invariant across the compaction, and the emptied
#      source blocks were reclaimed.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_defrag
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/immix_defrag.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_defrag not clean:\n$errs"

want="1
1
1000
1
1"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: Immix copy reserve + defrag trigger (150.3.8) — selective evacuation of fragmented blocks within the copy reserve, survivors compacted + fixed up, fingerprint invariant, sources reclaimed"
