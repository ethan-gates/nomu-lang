#!/bin/zsh
# M6 · 6.4 — actor teardown / reclamation test. Churns 200k short-lived actors (create → send one
# fire-and-forget message → drop the reference). Once a mailbox drains, the actor + mailbox + message
# form an unreferenced cycle the moving GC reclaims — actors own no non-GC resource, so teardown is
# purely structural. N actors' worth of state (~20 MB) far exceeds the test heap (4 MB), so:
#
#   - under GenImmix the run COMPLETES at the tight heap (dead actors are collected), and
#   - under NoGC (bump-and-leak) the same tight heap RUNS OUT OF MEMORY.
#
# That contrast is the proof: reclamation is what lets the churn finish in bounded memory. Also
# exercises the capped mailbox-fiber pool + the scheduled-mailbox queue rooting (a scheduled mailbox
# whose actor is otherwise unreferenced stays live via the queue root, not collected mid-flight).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/gc_actor_teardown
HEAP=${NOMU_GC_HEAP:-4000000}   # ~4 MB: comfortably holds the bounded live set, far below N live actors

"$NOMUC" "$ROOT/examples/gc_actor_teardown.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }

# GenImmix at the tight heap: must complete (the dead actors are reclaimed).
gen=$(NOMU_GC_HEAP=$HEAP "$BIN" 2>/dev/null); gen_rc=$?
# NoGC at the tight heap: must NOT complete — 200k leaked actors don't fit (out of memory).
nogc_tight=$(NOMU_GC_PLAN=nogc NOMU_GC_HEAP=$HEAP "$BIN" 2>/dev/null); nogc_tight_rc=$?
# NoGC at a large heap: the program itself is correct when it is allowed to leak (sanity).
nogc_big=$(NOMU_GC_PLAN=nogc NOMU_GC_HEAP=64000000 "$BIN" 2>/dev/null)

fail() { echo "FAIL: $1"; echo "  genimmix(tight)=$gen rc=$gen_rc | nogc(tight)=$nogc_tight rc=$nogc_tight_rc | nogc(big)=$nogc_big"; exit 1; }

[[ "$gen" == "200000" && $gen_rc -eq 0 ]] || fail "GenImmix did not complete at the tight heap (actor leak?)"
[[ "$nogc_big" == "200000" ]]             || fail "NoGC at a large heap did not complete (program is wrong)"
[[ "$nogc_tight" != "200000" ]]           || fail "NoGC completed at the tight heap — the contrast is void (heap too large?)"

echo "PASS: gc_actor_teardown — 200k short-lived actors churned; GenImmix completes at ${HEAP}B (dead actors + mailboxes reclaimed) where NoGC runs out of memory — actor teardown is structural and real"
