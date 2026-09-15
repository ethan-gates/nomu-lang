#!/bin/zsh
# Task 150.3.9 — a real evacuating Immix collection driven at a stop-the-world over the self-hosted
# scheduler. This is the bridge from 128.3.2 (STW + self-hosted root recovery) to a collecting GC: the
# recovered roots feed the self-hosted Immix evacuator (rtImmixEvacMark), which moves the live graph and
# fixes up each root slot in place on the stopped mutator stacks — the first time the Nomu collector
# reclaims memory at a whole-program STW on the Nomu scheduler. Precondition for GenImmix (150.4).
#
# The proof is transparency: a force-all moving collection relocates every live object, so if the stack-slot
# fixup were wrong the mutator would resume on a stale pointer (into reclaimed space) and read garbage or
# crash. The program instead prints the same value as under MMTk/NoGC. Run single-carrier — the self-hosted
# allocator is not yet multi-carrier-safe (a follow-up), and single-carrier keeps the collection
# deterministic. NOMU_NO_ESCAPE keeps the live root off the stack-promotion path (as walk-parked / gc-smoke).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${STW_COLLECT_ITERS:-15}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 60; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/stw_collect.nomu" >/dev/null 2>&1 || fail "compile stw_collect"
BIN=$ROOT/build/examples/stw_collect

# Oracle: MMTk NoGC (no collection). The self-hosted moving collection must be output-identical.
want=$(NOMU_GC_PLAN=nogc run "$BIN" 2>/dev/null)
[[ -n "$want" ]] || fail "no baseline output"
[[ "$want" == "111" ]] || fail "baseline output '$want', want 111"

# Single-carrier and multi-carrier. Multi-carrier (NOMU_CARRIERS>1) exercises the 150.3.10.1 TLAB reset: the
# force-all collection may relocate the allocating carrier's current block, and the collector resets every
# registered carrier's TLAB at end-of-collection so the mutator refills cleanly on resume. One allocating
# fiber, so the fiber-result-box gap (150.3.13) is not in play.
for nc in 1 2 4; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_SCHED=nomu NOMU_CARRIERS=$nc NOMU_GC_PLAN=nomu NOMU_STW_COLLECT=1 run "$BIN" 2>/tmp/stw_collect.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/stw_collect.err; fail "carriers=$nc run $i hung (watchdog) — an STW handshake or the collection stalled"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/stw_collect.err; fail "carriers=$nc run $i crashed (exit $rc) — likely a mis-fixed root slot into reclaimed space"; }
    [[ "$got" == "$want" ]] || { cat /tmp/stw_collect.err; fail "carriers=$nc run $i output '$got' != oracle '$want' — moving collection not transparent (fixup wrong)"; }
    # The collection must actually have run (roots walked + fixed up), not silently no-op'd.
    grep -q "nomu-stw-collect: round 0 fixed [1-9]" /tmp/stw_collect.err || { cat /tmp/stw_collect.err; fail "carriers=$nc run $i: no collection ran (0 roots fixed)"; }
  done
done

echo "PASS: self-hosted evacuating Immix collection at a scheduler STW — a live object relocated by a force-all move, its stack slot fixed up, the mutator resumed and read the moved object; output-identical to MMTk NoGC across $ITERS runs at 1/2/4 carriers (NOMU_SCHED=nomu + NOMU_GC_PLAN=nomu; multi-carrier exercises the 150.3.10.1 TLAB reset)"
