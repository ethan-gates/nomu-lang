#!/bin/zsh
# Task 128.1.7 (feeder 1 of 2) · self-hosted timer heap. Compiles examples/scheduler_timer.nomu with the
# scheduler + timer + carrier functions designated runtime-subset (no safepoint poll on the raw carrier /
# timer threads), then runs it. Four fibers sleep 40/80/120/160 ms via fiberSleep (register a deadline on
# the min-heap + park); a dedicated timer thread waits on the timer futex until each deadline and unparks
# the due fiber. A correct run wakes them in deadline order and records 1 2 3 4 (min-heap ordering + the
# timer-thread unpark), and all four wake (liveness) so the run terminates for the join.
#
# NoGC only: the carriers and the timer thread are raw pthreads, not registered mutators (same envelope as
# tools/pingpong.sh). Each run is watchdogged (macOS has no `timeout`) so a lost timer wakeup fails loud.
# A few runs — it is timing-based (~160 ms each), not a race loop.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_timer.nomu
BIN=$ROOT/build/examples/scheduler_timer
SUB=mutexLock,mutexUnlock,enqueue,dequeue,wakeCarrier,wakeTimer,signalStop,heapSwap,timerPush,timerPopMin,fiberNew,fiberSpawn,unpark,fiberSleep,fiberMain,schedLoop,carrierMain,timerMain
ITERS=${SCHED_TIMER_ITERS:-8}
want=$'1\n2\n3\n4'
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler/timer not subset-legal / did not compile"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (pthread/__ulock unresolved?)"

for i in $(seq 1 $ITERS); do
  out=$(run "$BIN" 2>/dev/null)
  rc=$?
  [[ $rc -eq 124 ]] && fail "run $i hung (watchdog) — a lost timer wakeup or a two-lock deadlock stalled the scheduler"
  [[ "$out" == "$want" ]] || fail "run $i: wake order '$(echo $out)', want '1 2 3 4' (deadline order)"
done

echo "PASS: self-hosted timer heap — min-heap deadlines + a timer thread unparking sleepers, woke in order 1 2 3 4 ($ITERS/$ITERS runs), subset-legal"
