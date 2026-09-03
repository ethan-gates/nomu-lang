#!/bin/zsh
# Task 128.1.8 · self-hosted actor mailbox + capped mailbox-fiber pool. Compiles
# examples/scheduler_actor.nomu with the scheduler + mailbox + pool functions designated runtime-subset
# (no safepoint poll on the raw carrier / mailbox-fiber threads), then runs it repeatedly. Eight actors
# receive 50 messages each (seq 0..49 in send order from the single sender); a global pool of at most 4
# mailbox fibers pulls scheduled mailboxes off the global queue and drains each to completion. Each handler
# asserts its seq equals the actor's expected counter (per-sender FIFO + the single-drain invariant — a
# mailbox is drained by at most one fiber at a time) and bumps it. A correct run delivers every message
# once, in order, with fibers reused across the 8 actors, and quiesces (drain-then-collect):
#   handled = 8*50 = 400
#   errors  = 0            (any out-of-order handling — a broken single-drain / FIFO — shows here)
#
# NoGC only: carriers + mailbox fibers are raw pthreads, not registered mutators (same envelope as
# pingpong). Looped + watchdogged so a lost dispatch, a double-drain, or a botched quiescence fails loud.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_actor.nomu
BIN=$ROOT/build/examples/scheduler_actor
SUB=mutexLock,mutexUnlock,enqueue,dequeue,wakeCarrier,signalStop,schedMbPush,schedMbPop,mailboxFiberNew,mailboxDispatch,actorSend,mailboxPop,mailboxDrain,mailboxFiberMain,schedLoop,carrierMain
ITERS=${SCHED_ACTOR_ITERS:-40}
want=$'400\n0'
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "actor runtime not subset-legal / did not compile"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem"

for i in $(seq 1 $ITERS); do
  out=$(run "$BIN" 2>/dev/null)
  rc=$?
  [[ $rc -eq 124 ]] && fail "run $i hung (watchdog) — a lost mailbox dispatch or a botched quiescence deadlocked shutdown"
  [[ $rc -eq 0 ]]   || fail "run $i crashed (exit $rc) — likely a concurrent double-drain corrupted a mailbox"
  [[ "$out" == "$want" ]] || fail "run $i: got '$(echo $out)', want '400 0' (400 delivered in FIFO order, no single-drain violation)"
done

echo "PASS: self-hosted actor mailbox + capped fiber pool — 8 actors × 50 msgs drained FIFO & single-drain by ≤4 reused fibers, quiesced; handled=400 errors=0 ($ITERS/$ITERS runs), subset-legal"
