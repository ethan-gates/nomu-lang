#!/bin/zsh
# Task 128.1.2 · two-thread futex ping-pong. Compiles examples/pingpong.nomu and runs it repeatedly,
# checking a real cross-thread sleep → wake: a second OS thread (pthread_create) running the Nomu
# `worker` (reached via RawPtr.ofFunc) wakes `main` blocked in futexWait. Each run must report 111 —
# hundreds: the word holds 1; tens: the worker ran; ones: main was asleep ≥ 10 ms until woken. `worker`
# is designated runtime-subset (raw memory + atomics + clock + futex only), so it carries no safepoint
# poll on the raw thread. Looped to shake out races; each wait has a 2 s backstop so a lost wakeup fails
# a run rather than hanging. NoGC only — the worker thread is not a registered mutator, so a moving
# collection over it is out of scope for this substrate isolation test.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/pingpong.nomu
BIN=$ROOT/build/examples/pingpong
ITERS=${PINGPONG_ITERS:-10}
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" --runtime-subset=worker "$SRC" >/dev/null 2>&1 || fail "compile (worker not subset-legal?)"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (pthread/__ulock unresolved?)"

for i in $(seq 1 $ITERS); do
  out=$("$BIN" 2>/dev/null)
  [[ "$out" == "111" ]] || fail "run $i: got '$out', want 111 (100=word-set, 10=worker-ran, 1=main-slept)"
done

echo "PASS: two-thread futex ping-pong — worker on a pthread wakes main in futexWait, real sleep→wake ($ITERS/$ITERS runs)"
