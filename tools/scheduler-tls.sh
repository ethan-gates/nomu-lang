#!/bin/zsh
# Task 128.1.6 · carrier-local rt_current (TLS) + the cross-thread park/unpark stress (the lost-wakeup race
# under real multi-carrier contention). Compiles examples/scheduler_tls.nomu with the scheduler + carrier
# + mutex + park/unpark + body functions designated runtime-subset (no safepoint poll on the raw carrier
# threads), then runs it repeatedly. Each run: 16 A↔B token-pair rings bounce a token via argument-free
# park() / explicit unpark() while 4 carrier OS threads steal them off the shared MT-safe queue, all
# racing to claim a fixed 2000-unit work budget. Every claimed unit adds 1 to a shared atomic accumulator,
# so a correct run — where the lock-handoff serializes each park-save against the cross-thread unpark that
# would re-queue it — prints exactly 2000 and terminates. A dropped lock-handoff would corrupt a half-saved
# context (crash) or lose a wakeup (hang); both fail loud under the watchdog.
#
# `park()` reads the running fiber from the thread-local slot (RawPtr.tlsGet, set by the carrier at
# switch-in), so this is where multi-carrier self-park first works. NoGC only: the carriers are raw
# pthreads, not registered mutators (same envelope as tools/pingpong.sh). Looped to shake out the race.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_tls.nomu
BIN=$ROOT/build/examples/scheduler_tls
SUB=mutexLock,mutexUnlock,enqueue,dequeue,wakeCarrier,fiberNew,handOff,unpark,fiberMain,schedLoop,carrierMain,ringBody
ITERS=${SCHED_TLS_ITERS:-40}
fail() { echo "FAIL: $1"; exit 1; }
# Fork the program, alarm-kill it at 30 s (exit 124) so a lost wakeup / corruption is a loud failure.
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler is not subset-legal / did not compile"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (pthread/__ulock unresolved?)"

for i in $(seq 1 $ITERS); do
  out=$(run "$BIN" 2>/dev/null)
  rc=$?
  [[ $rc -eq 124 ]] && fail "run $i hung (watchdog) — a lost cross-thread wakeup or a broken lock-handoff deadlocked the scheduler"
  [[ $rc -eq 0 ]]   || fail "run $i crashed (exit $rc) — likely a fiber switched into a context still mid-save (lock-handoff violated)"
  [[ "$out" == "2000" ]] || fail "run $i: got '$out', want 2000 (budget claimed exactly once each across 4 carriers)"
done

echo "PASS: multi-carrier cross-thread park/unpark (TLS rt_current + lock-handoff) — 16 rings, 4 carriers, budget=2000 claimed exactly once ($ITERS/$ITERS runs), subset-legal"
