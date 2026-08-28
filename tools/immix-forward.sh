#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.6 — forwarding word + copy primitive (selfhosted-gc.md §10.8),
# the mechanism evacuation (150.3.7) is built on. rtCopyObject copies an object to a fresh slot, installs the
# forwarding record (header bit 33 + new address in payload word 0), and it reads back; rtCheckPayloadWord
# confirms every managed type has a payload word 0 for the forwarding pointer. Checks:
#   1. examples/immix_forward.nomu compiles clean (prelude auto-subset, task 149).
#   2. Copy + forward + read back: 12345 / 1 / 1 / 0 / 0.
#   3. Deterministic across runs.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_forward
fail() { echo "FAIL: $1"; exit 1; }

errs=$($NOMUC "$ROOT/examples/immix_forward.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_forward not clean:\n$errs"

want="12345
1
1
0
0"
got=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got" == "$want" ]] || fail "output: got '$(echo $got)', want '$(echo $want)'"
got2=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$got2" == "$got" ]] || fail "non-deterministic across runs"
echo "PASS: Immix forwarding word + copy primitive (150.3.6) — copy/forward/read-back, payload-word-0 guard clean"
