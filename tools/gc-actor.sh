#!/bin/zsh
# Task 150.3.12.1 — the actor scheduled-mailbox queue as a GC root under a moving collection, on the
# default block-on-OOM path (NOMU_RUNTIME=selfhost, no GC knob). examples/gc_actor.nomu creates 2000
# short-lived Worker actors; each is sent 50 `add` messages and a final `report`, then its handle is
# dropped — so the actor, its mailbox, and every queued message are reachable ONLY through the scheduler's
# scheduled-mailbox queue (head sched+80, sched_next chain, tail sched+88). With one carrier the sends all
# run before any drain, so the whole backlog sits on that queue while draining begins; each `add` handler
# allocates a throwaway window of Boxes, over-allocating far past the 256 MiB heap so collections fire mid-
# drain while later workers' mailboxes are still queued. Their messages' `self` receiver + `v` arg must
# survive each collection — the coverage 150.3.12.1 adds (nomuSchedWalkRoots roots the queue head/tail).
#
# Oracle: MMTk NoGC never collects, so the queue trivially survives and every actor's sum is 1225
# (0+1+…+49). The block-on-OOM run must print the identical 2000 lines. Without the queue root a mid-drain
# collection reclaims the queued backlog and the run prints nothing (all workers lost). A collection must
# actually fire (else the heap never filled and nothing was proven). NOMU_NO_ESCAPE keeps the garbage Boxes
# on the real heap.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_ACTOR_ITERS:-4}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 180; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_actor.nomu" >/dev/null 2>&1 || fail "compile gc_actor"
BIN=$ROOT/build/examples/gc_actor

# Oracle: MMTk NoGC, single carrier so the mailbox-fiber pool drains on one thread (serial stdio → no
# interleaved report lines), sorted (drain order is irrelevant to the multiset of per-actor sums).
want=$(NOMU_CARRIERS=1 run "$BIN" 2>/dev/null | sort)
[[ $(echo "$want" | grep -c ' 1225$') -eq 2000 ]] || fail "MMTk oracle not 2000×'tag 1225' (got $(echo "$want" | wc -l) lines)"

# Default block-on-OOM, single carrier (sends fully queue before draining → a live backlog on the queue).
for i in $(seq 1 $ITERS); do
  got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=1 NOMU_GC_DEBUG_PRESSURE=1 run "$BIN" 2>/tmp/gc_actor.err | sort); rc=$?
  [[ $rc -eq 124 ]] && { cat /tmp/gc_actor.err; fail "run $i hung (watchdog) — an OOM handshake stalled with the queue live"; }
  [[ $rc -eq 0 ]]   || { cat /tmp/gc_actor.err; fail "run $i crashed (exit $rc) — a stale queued mailbox/message pointer after a move"; }
  [[ "$got" == "$want" ]] || { echo "$got" | head; fail "run $i output != MMTk oracle — a mid-drain collection lost or corrupted queued messages"; }
  ncol=$(grep -c "nomu-gc-sync: collection" /tmp/gc_actor.err)
  [[ $ncol -ge 1 ]] || { cat /tmp/gc_actor.err; fail "run $i: no mid-drain collection fired (heap never filled — nothing proven)"; }
done

echo "PASS: actor scheduled-mailbox queue rooted under a moving collection — 2000 short-lived actors' queued messages (self + args) survive collections fired mid-drain at true OOM, every actor's sum 1225, output-identical to MMTk NoGC ($ITERS/$ITERS runs, NOMU_RUNTIME=selfhost, no GC knob)"
