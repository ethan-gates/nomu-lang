#!/bin/zsh
# Task 128.1.1 · scheduler substrate — futex (macOS __ulock_wait / __ulock_wake, the libSystem futex
# floor; no C-runtime shim). Compiles examples/futex.nomu and checks the value-check contract
# single-threaded, using the monotonic clock to tell the two paths apart:
#   1. a wait whose word ≠ expected returns promptly (< 50 ms) — no spurious kernel sleep.  (hundreds)
#   2. a wait whose word = expected blocks to the timeout (≥ 100 ms of a 200 ms wait).       (tens)
#   3. a wake with no waiter returns without faulting.                                       (ones)
# → the result code 111. The fixture uses finite timeouts on every wait, so it is self-bounding (it
# cannot hang even if the primitive misbehaves — a broken binding drops the tens digit instead). The
# binary must link the libSystem __ulock entries. The real two-thread sleep→wake ping-pong rides
# thread-create (128.1.2).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/futex.nomu
BIN=$ROOT/build/examples/futex
want=111
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile"
out=$("$BIN" 2>/dev/null); [[ "$out" == "$want" ]] || fail "output: got '$out', want 111 (hundreds=mismatch-prompt, tens=matched-slept, ones=wake-safe)"
otool -L "$BIN" 2>/dev/null | grep -q "libSystem" || fail "binary not linked against libSystem (__ulock unresolved?)"

# futexProbe runs only on the substrate primitives, so it is subset-legal (the `__sys`/`__raw`/`__atomic`
# allowlist). Designating it must compile and produce the same result.
"$NOMUC" --runtime-subset=futexProbe "$SRC" >/dev/null 2>&1 || fail "subset build did not compile (futex not subset-legal?)"
out=$("$BIN" 2>/dev/null); [[ "$out" == "$want" ]] || fail "subset output: got '$out', want 111"

echo "PASS: futex (__ulock_wait/__ulock_wake) — value-mismatch returns prompt, matched wait sleeps to timeout, wake-no-waiter safe; subset-legal"
