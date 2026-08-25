#!/bin/zsh
# M7 · §7.0.5 T6 — safepoint coverage after a tier transform (invariant I9). Multi-block inlining
# (7.5) splices `loopSum`'s bare compute loop into `spin`, producing an inlined loop whose only
# safepoint is the egress's loop-header poll. This test proves that poll survives the transform: with
# the tier on, the STW handshake still stops the carrier while it spins in the inlined loop, scans
# every root, and resumes. If inlining ever dropped the back-edge poll, the carrier would never reach
# a safepoint and the handshake would hang — so the watchdogged completion (exit 0) is the assertion.
#
# Runs under (so multi-block inlining actually fires) and NOMU_NO_ESCAPE=1 (6.5.2 —
# keep the leaf heap roots this collector test relies on off the stack). Distinct from
# gc-smoke-stw.sh, whose loop is written directly in `spin` (no inlining involved).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
SRC=$ROOT/examples/gc_smoke_t6.nomu

fail() { echo "FAIL: $1"; exit 1; }

# Compile with the pass dumps so we can confirm the loop is genuinely inlined (not a leftover call).
NOMU_DUMP_SSAIR_PASSES=1 "$NOMUC" "$SRC" >/dev/null 2>&1 || fail "compile"
spin=$(sed -n '/fun spin(/,/^}/p' "$ROOT/build/examples/gc_smoke_t6.o.final.ssair")
echo "$spin" | grep -q 'call ' && fail "loopSum was not inlined into spin — T6 would not exercise an inlined loop"
echo "$spin" | grep -q 'condBr' || fail "no loop in spin after inlining — expected an inlined back-edge loop"
echo "OK: loopSum inlined into spin (an inlined loop with no interior call/alloc)"

# Run under the STW smoke driver; watchdog it (a dropped poll would hang the handshake).
out=$(NOMU_GC_STW_SMOKE=1 perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 30; waitpid($p,0); exit($?>>8)' "$ROOT/build/examples/gc_smoke_t6" 2>&1 1>/dev/null)
rc=$?
echo "$out"

[[ $rc -eq 124 ]] && fail "handshake hung (timeout) — the carrier never reached a safepoint (inlined loop lost its poll)"
[[ $rc -eq 0 ]] || fail "program did not complete (exit $rc) — resume may have deadlocked"
echo "$out" | grep -q 'nomu-gc-stw: stopping the world' || fail "world was not stopped"
echo "$out" | grep -q 'nomu-gc-stw: resumed' || fail "world was not resumed"
echo "$out" | grep -q 'v=777' || fail "missing running-fiber root 777 (carrier scan of the inlined loop)"
echo "$out" | grep -q 'v=888' || fail "missing parked-fiber root 888 (registry scan)"
creads=$(echo "$out" | sed -n 's/.*: \([0-9]*\) carrier roots.*/\1/p')
[[ "${creads:-0}" -ge 1 ]] || fail "no carrier (running-fiber) roots scanned — the spinning carrier was not caught at a safepoint"
echo "PASS: T6 — the loop-header poll survives multi-block inlining; STW stopped + scanned the inlined-loop carrier (777) + parked root (888) and resumed"
