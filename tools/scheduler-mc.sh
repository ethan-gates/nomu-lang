#!/bin/zsh
# Task 128.1.5 · multi-carrier scheduler. Compiles examples/scheduler_mc.nomu with the scheduler +
# carrier + mutex functions designated runtime-subset (so they carry no safepoint poll on the raw carrier
# threads), then runs it repeatedly. Each run starts 4 carrier OS threads draining one shared MT-safe run
# queue: phase 1 (100 fibers) is enqueued before the carriers exist; the carriers drain it and go idle
# (sleeping on the wake-gen futex); phase 2 (100 fibers) is pushed ~50 ms later from the main thread, each
# push waking a sleeping carrier (the cross-thread wake). Every fiber adds 3 to a shared atomic
# accumulator, so the sum is 600 regardless of interleaving; the last fiber to finish broadcasts a stop
# and the carriers exit for main to join. A correct run prints 600 and terminates.
#
# NoGC only: the carriers are raw pthreads, not registered mutators, so a moving collection's STW neither
# knows nor waits for them (same envelope as tools/pingpong.sh); they touch only off-heap memory. Looped
# to shake out queue/mutex/wake races; each run is watchdogged (macOS has no `timeout`) so a lost wakeup
# or a lock imbalance fails a run rather than wedging.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_mc.nomu
BIN=$ROOT/build/examples/scheduler_mc
SUB=mutexLock,mutexUnlock,enqueue,dequeue,wakeCarrier,fiberNew,fiberSpawn,fiberMain,schedLoop,carrierMain
ITERS=${SCHED_MC_ITERS:-30}
fail() { echo "FAIL: $1"; exit 1; }
# Fork the program, alarm-kill it at 30 s (exit 124) so a deadlock is a loud failure, not a hang.
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler is not subset-legal / did not compile"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (pthread/__ulock unresolved?)"

for i in $(seq 1 $ITERS); do
  out=$(run "$BIN" 2>/dev/null)
  rc=$?
  [[ $rc -eq 124 ]] && fail "run $i hung (watchdog) — a lost carrier wake, a lock imbalance, or a botched shutdown deadlocked the carriers"
  [[ "$out" == "600" ]] || fail "run $i: got '$out', want 600 (200 fibers × 3, summed atomically across 4 carriers)"
done

echo "PASS: multi-carrier scheduler — 4 carriers drain a shared MT-safe queue, idle-sleep + cross-thread wake-on-push, clean shutdown; sum=600 ($ITERS/$ITERS runs), subset-legal"
