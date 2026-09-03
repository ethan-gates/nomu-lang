#!/bin/zsh
# Task 128.1.7 (feeder 2 of 2) · self-hosted I/O poller (kqueue). Compiles examples/scheduler_poller.nomu
# with the scheduler + poller functions designated runtime-subset (no safepoint poll on the raw carrier /
# poller threads), then runs it repeatedly. Eight fibers each register their own pipe's read-end with the
# kqueue via waitReadable and park; a dedicated poller thread blocks in kevent() and unparks the fiber
# stashed in each ready event's udata; main writes each fiber's id into its pipe to trigger readiness. A
# correct run wakes every fiber exactly once, each reads its byte and adds it, so the accumulator is
# 1+…+8 = 36, and it terminates (a self-pipe write wakes the poller for shutdown).
#
# NoGC only: carriers + poller are raw pthreads, not registered mutators (same envelope as pingpong).
# Each run is watchdogged (macOS has no `timeout`) so a lost readiness wakeup or a botched poller handoff
# fails loud. Looped to shake out the register-vs-kevent and poller-unpark handoff.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_poller.nomu
BIN=$ROOT/build/examples/scheduler_poller
SUB=mutexLock,mutexUnlock,enqueue,dequeue,wakeCarrier,signalStop,fiberNew,fiberSpawn,unpark,waitReadable,fiberMain,schedLoop,carrierMain,pollerMain
ITERS=${SCHED_POLLER_ITERS:-30}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler/poller not subset-legal / did not compile"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (kqueue/kevent/pipe unresolved?)"

for i in $(seq 1 $ITERS); do
  out=$(run "$BIN" 2>/dev/null)
  rc=$?
  [[ $rc -eq 124 ]] && fail "run $i hung (watchdog) — a lost readiness wakeup or a poller-handoff stall"
  [[ "$out" == "36" ]] || fail "run $i: got '$out', want 36 (8 fibers each woken once via kqueue, byte summed)"
done

echo "PASS: self-hosted I/O poller (kqueue) — 8 fibers parked on fd readiness, a poller thread unparks each via kevent udata; sum=36 ($ITERS/$ITERS runs), subset-legal"
