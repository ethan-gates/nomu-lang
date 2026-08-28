#!/bin/zsh
# Task 150 · rung 3 (Immix), increment 150.3.3 — the large-object space (LOS). Objects larger than a 32 KiB
# block cannot fit the block allocator, so rtImmixAlloc routes them to rtLosAlloc: a whole off-heap chunk,
# linked off the space's losHead for later reclamation, never moved (selfhosted-gc.md §10.3). Checks:
#   1. examples/immix_los.nomu compiles clean (the prelude allocator is auto-subset, task 149).
#   2. Output is correct: 5000 / 12497500 / 4999 — a large Array<Int> whose buffer grew into the LOS,
#      summed and read back.
#   3. Byte-identical under MMTk NoGC (oracle) and the self-hosted Immix+LOS allocator — the differential.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
BIN=$ROOT/build/examples/immix_los
fail() { echo "FAIL: $1"; exit 1; }

# 1 — compiles clean (and produces the binary).
errs=$($NOMUC "$ROOT/examples/immix_los.nomu" 2>&1)
echo "$errs" | grep -qiE "error|runtime-subset function" && fail "immix_los not clean:\n$errs"

want="5000
12497500
4999"
# 2 + 3 — correct under the oracle, and identical under the self-hosted allocator (large buffers → LOS).
base=$(NOMU_GC_PLAN=nogc "$BIN" 2>/dev/null)
self=$(NOMU_GC_PLAN=nomu "$BIN" 2>/dev/null)
[[ "$base" == "$want" ]] || fail "baseline (MMTk NoGC) output: got '$(echo $base)', want '$(echo $want)'"
[[ "$self" == "$base" ]] || fail "self-hosted Immix+LOS differs from oracle: got '$(echo $self)'"
echo "PASS: Immix large-object space (150.3.3) — large Array<Int> buffer routed to LOS; byte-identical under MMTk NoGC and self-hosted Immix+LOS"
