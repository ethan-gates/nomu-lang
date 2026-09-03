#!/bin/zsh
# Task 128.1.9 · the self-hosted scheduler as the production scheduler behind NOMU_SCHED=nomu. The
# 128.1.x rungs each proved one scheduler mechanism as a standalone NoGC-only fixture; this rung
# consolidates them into one scheduler (src/stdlib/runtime.nomu) that runs real GC-registered user
# programs — carriers are ordinary pthreads binding an MMTk mutator lazily, polling at real safepoints
# (NoGC scope, so no stop-the-world over them yet — that is 128.3.2). fiber_spawn / spawn_join /
# rt_sleep_ms / rt_actor_send / rt_mailbox_pop and main dispatch on NOMU_SCHED (runtime.c); codegen is
# unchanged.
#
# The differential oracle, the ladder's method applied to the production surface: each real user program
# runs BOTH under NOMU_SCHED=nomu and under the default C scheduler, and the observable output must match.
# Covers the three user-facing surfaces — spawn/join (structured concurrency), sleep (the timer feeder),
# and actor send (mailbox + capped fiber pool) — under both multi-carrier (4) and single-carrier. Looped;
# each run watchdogged so a lost wakeup / deadlock fails loud (exit 124) instead of wedging.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${SCHED_INT_ITERS:-25}
fail() { echo "FAIL: $1"; exit 1; }
# Fork the program, alarm-kill it at 30 s (exit 124) so a lost wakeup / deadlock is a loud failure.
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$@"; }

# The programs to diff, one per line: "<source> <surface>".
progs=(
  "examples/spawn.nomu spawn/join"
  "examples/shareability.nomu spawn/join+struct-capture"
  "examples/actor.nomu actor+sleep+spawn/join"
  "examples/actor_relay.nomu actor-relay"
)

for entry in "${progs[@]}"; do
  src="${entry%% *}"
  surface="${entry#* }"
  bin="$ROOT/build/${src%.nomu}"
  "$NOMUC" "$ROOT/$src" >/dev/null 2>&1 || fail "$src did not compile"
  # The oracle: the C scheduler's output (deterministic for these programs).
  want=$(run "$bin" 2>/dev/null)
  rc=$?
  [[ $rc -eq 0 ]] || fail "$src crashed/hung under the C scheduler (exit $rc)"
  for carriers in 4 1; do
    for i in $(seq 1 $ITERS); do
      got=$(NOMU_SCHED=nomu NOMU_CARRIERS=$carriers run "$bin" 2>/dev/null)
      rc=$?
      [[ $rc -eq 124 ]] && fail "$src ($surface) hung under NOMU_SCHED=nomu NOMU_CARRIERS=$carriers run $i — a lost wakeup / deadlock in the self-hosted scheduler"
      [[ $rc -eq 0 ]]   || fail "$src ($surface) crashed under NOMU_SCHED=nomu NOMU_CARRIERS=$carriers run $i (exit $rc)"
      [[ "$got" == "$want" ]] || fail "$src ($surface) under NOMU_SCHED=nomu NOMU_CARRIERS=$carriers run $i: got '$got', want '$want' (C oracle)"
    done
  done
  echo "  ok: $src ($surface) — nomu == C over 2×$ITERS runs {4 carriers, 1 carrier}"
done

echo "PASS: self-hosted scheduler (NOMU_SCHED=nomu) matches the C scheduler on real spawn/join, sleep, and actor programs"
