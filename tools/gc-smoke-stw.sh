#!/bin/zsh
# M6 · 6.2.3 stop-the-world smoke: prove the STW handshake stops every carrier at a safepoint, lets
# the collector scan all roots, and resumes cleanly — with no real collection. Compiles
# examples/gc_smoke_stw.nomu and runs it under NOMU_GC_STW_SMOKE=1; a runtime background thread stops
# the world while a compute fiber spins (root 777, held across its back-edge poll) and a fiber is
# parked (root 888), scans both, and resumes.
#
# Expected: the world stops and resumes; the running fiber's root 777 is recovered via its carrier's
# saved poll context (6.2.1); the parked fiber's root 888 via the registry (6.2.2); the program runs
# to completion (exit 0) — proving resume released every carrier.
set -u
# 6.5.2: pin escape analysis off so leaf heap roots this collector test relies on are not stack-promoted.
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
"$NOMUC" "$ROOT/examples/gc_smoke_stw.nomu" >/dev/null || { echo "FAIL: compile"; exit 1; }
out=$(NOMU_GC_STW_SMOKE=1 "$ROOT/build/examples/gc_smoke_stw" 2>&1 1>/dev/null)
rc=$?
echo "$out"

fail() { echo "FAIL: $1"; exit 1; }
[[ $rc -eq 0 ]] || fail "program did not complete (exit $rc) — resume may have deadlocked"
echo "$out" | grep -q 'nomu-gc-stw: stopping the world' || fail "world was not stopped"
echo "$out" | grep -q 'nomu-gc-stw: resumed' || fail "world was not resumed"
echo "$out" | grep -q 'v=777' || fail "missing running-fiber root 777 (carrier context scan)"
echo "$out" | grep -q 'v=888' || fail "missing parked-fiber root 888 (registry scan)"
# At least one root from each source.
creads=$(echo "$out" | sed -n 's/.*: \([0-9]*\) carrier roots.*/\1/p')
preads=$(echo "$out" | sed -n 's/.*carrier roots, \([0-9]*\) parked roots.*/\1/p')
[[ "${creads:-0}" -ge 1 ]] || fail "no carrier (running-fiber) roots scanned"
[[ "${preads:-0}" -ge 1 ]] || fail "no parked-fiber roots scanned"
echo "PASS: STW stopped + resumed all carriers; scanned running root 777 + parked root 888; program completed"
