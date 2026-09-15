#!/bin/zsh
# Task 150.3.11 — synchronous block-on-OOM collection, the DEFAULT self-hosted GC trigger. Unlike
# tools/gc-pressure.sh (which sets NOMU_GC_PRESSURE to run the background polling collector), this drives the
# default path: NOMU_RUNTIME=selfhost with no GC knob at all. Collection fires only when an allocating mutator
# truly runs out of blocks — the mutator captures its alloc-site anchor, initiates a stop-the-world, the GC
# coordinator (a plain pthread) runs a defrag collection, and the mutator retries. The program over-allocates
# far past the 256 MiB heap, so without block-on-OOM it would exhaust; under it the program survives and its
# checksum matches MMTk NoGC. Exercised single- and multi-carrier, plus the concurrent-allocator example (four
# fibers hitting OOM at once). NOMU_NO_ESCAPE keeps the Boxes off the scalar-replacement path (real heap).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_OOM_ITERS:-6}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 90; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_pressure.nomu"  >/dev/null 2>&1 || fail "compile gc_pressure"
"$NOMUC" "$ROOT/examples/gc_concurrent.nomu" >/dev/null 2>&1 || fail "compile gc_concurrent"
GP=$ROOT/build/examples/gc_pressure
CC=$ROOT/build/examples/gc_concurrent

# Oracles: MMTk NoGC absorbs the over-allocation without collecting; the block-on-OOM run must be identical.
gp_want=$(run "$GP" 2>/dev/null); [[ -n "$gp_want" ]] || fail "no gc_pressure baseline"
cc_want=$(run "$CC" 2>/dev/null); [[ -n "$cc_want" ]] || fail "no gc_concurrent baseline"

# Single allocating fiber, default block-on-OOM, single- and multi-carrier. A collection must actually fire
# (the coordinator prints under NOMU_GC_DEBUG_PRESSURE) — else the "survival" would be a heap that never filled.
for nc in 1 2 4; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=$nc NOMU_GC_DEBUG_PRESSURE=1 run "$GP" 2>/tmp/gc_oom.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/gc_oom.err; fail "gp carriers=$nc run $i hung (watchdog) — an OOM handshake stalled"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/gc_oom.err; fail "gp carriers=$nc run $i crashed (exit $rc) — heap exhaustion or a mis-fixed root"; }
    [[ "$got" == "$gp_want" ]] || { cat /tmp/gc_oom.err; fail "gp carriers=$nc run $i output '$got' != oracle '$gp_want'"; }
    ncol=$(grep -c "nomu-gc-sync: collection" /tmp/gc_oom.err)
    [[ $ncol -ge 1 ]] || { cat /tmp/gc_oom.err; fail "gp carriers=$nc run $i: no block-on-OOM collection fired"; }
  done
done

# Concurrent allocators (four fibers over-allocating at once → concurrent OOM), default block-on-OOM.
for nc in 1 2 4 8; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=$nc run "$CC" 2>/tmp/gc_oom.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/gc_oom.err; fail "cc carriers=$nc run $i hung (watchdog) — a concurrent-OOM handshake stalled"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/gc_oom.err; fail "cc carriers=$nc run $i crashed (exit $rc)"; }
    [[ "$got" == "$cc_want" ]] || { cat /tmp/gc_oom.err; fail "cc carriers=$nc run $i output '$got' != oracle '$cc_want'"; }
  done
done

echo "PASS: synchronous block-on-OOM collection (default trigger) — a program over-allocating far past the 256 MiB heap survives via collections fired only at true OOM, output-identical to MMTk NoGC single- and multi-carrier, including four concurrent allocators hitting OOM at once (NOMU_RUNTIME=selfhost, no GC knob)"
