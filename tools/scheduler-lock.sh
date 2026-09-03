#!/bin/zsh
# Task 128.1.4 · MT-safe run queue under a self-hosted futex mutex + the lock-handoff park protocol.
# Compiles examples/scheduler_lock.nomu with the scheduler functions designated runtime-subset — which
# also proves the mutex (atomics + futex) and the lock-coupled park path are subset-legal — and checks:
#   1. three fibers each add to a shared accumulator, run to completion → 6     (queue under the lock)
#   2. a park/unpark handoff between two fibers                        → 111    (lock-coupled park)
#   3. one fiber computes a value, another joins and reads it          → 42     (join under the lock)
#   4. a two-fiber relay bouncing a token 1000 rounds each            → 2000   (parking-heavy stress)
# A second leg runs under the moving collector: the scheduler touches only off-heap memory, so the output
# is unchanged. Every run is watchdogged (macOS has no `timeout`) so a park-protocol deadlock fails the
# test instead of wedging.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/scheduler_lock.nomu
BIN=$ROOT/build/examples/scheduler_lock
SUB=mutexLock,mutexUnlock,enqueue,dequeue,schedRun,fiberMain,fiberNew,fiberSpawn,fiberSpawnParked,park,parkLocked,unpark,unparkLocked,joinFiber
STRESS=${NOMU_GC_STRESS:-512}
want=$'6\n111\n42\n2000'
fail() { echo "FAIL: $1"; exit 1; }
# Fork the program, alarm-kill it at 30 s (exit 124) so a deadlock is a loud failure, not a hang.
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

# The subset designation must compile — the scheduler + mutex are runtime-subset code.
"$NOMUC" --runtime-subset=$SUB "$SRC" >/dev/null 2>&1 || fail "scheduler is not subset-legal / did not compile"
out=$(run "$BIN" 2>/dev/null)
[[ $? -eq 124 ]] && fail "park protocol hung (watchdog) — a lost wakeup or lock imbalance deadlocked the scheduler"
[[ "$out" == "$want" ]] || fail "scenarios: got '$(echo $out)', want '6 111 42 2000'"

evac=$(NOMU_GC_PLAN=immix NOMU_GC_STRESS=$STRESS run "$BIN" 2>/dev/null)
[[ "$evac" == "$want" ]] || fail "output differs under the moving collector (got '$(echo $evac)')"

echo "PASS: MT-safe queue + lock-handoff park (spawn=6, park/unpark=111, join=42, relay-stress=2000) — subset-legal, GC-independent"
