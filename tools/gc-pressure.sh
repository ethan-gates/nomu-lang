#!/bin/zsh
# Task: heap-pressure-triggered self-hosted Immix collection on the Nomu scheduler — the auto-trigger half
# of "collecting Immix + Nomu scheduler". A GC thread polls the self-hosted heap's free-block count and, when
# it drops below the reserve, drives a defrag collection at the scheduler STW (the 128.3.2 handshake +
# multi-root evacuator). The mutator stops at its next back-edge safepoint poll (a clean user statepoint),
# so collection happens between allocations and its roots are walkable.
#
# Proof: a single fiber allocates 640 MiB of Boxes (a sliding window of 100 live, the rest garbage) — far
# more than the 256 MiB self-hosted heap — so without reclamation the heap exhausts. Under the trigger the
# program survives via repeated collections and its checksum matches MMTk NoGC, which proves the survivors
# (and the array buffer's internal pointers) were relocated and fixed up correctly. Single-carrier (the
# self-hosted allocator is not yet multi-carrier-safe). NOMU_NO_ESCAPE keeps the Boxes off the
# scalar-replacement path so the allocation is real.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_PRESSURE_ITERS:-8}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 60; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_pressure.nomu" >/dev/null 2>&1 || fail "compile gc_pressure"
BIN=$ROOT/build/examples/gc_pressure

# Oracle: MMTk NoGC (1 GiB reserve absorbs the 640 MiB without collecting).
want=$(run "$BIN" 2>/dev/null)
[[ -n "$want" ]] || fail "no baseline output"

# Single-carrier and multi-carrier: one allocating fiber over-allocates, the GC thread drives repeated
# collections. Multi-carrier (NOMU_CARRIERS>1) exercises the 150.3.10.1 TLAB reset — the collector resets
# every registered carrier's TLAB at end-of-collection, so the (single) allocating carrier refills cleanly
# from the relocated pool on resume. Only one fiber allocates, so the fiber-result-box gap (150.3.13) is not
# in play; this stays checksum-stable.
for nc in 1 2 4; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_SCHED=nomu NOMU_CARRIERS=$nc NOMU_GC_PLAN=nomu NOMU_GC_PRESSURE=1 NOMU_GC_TRIGGER_RESERVE=4096 \
          NOMU_GC_DEBUG_PRESSURE=1 run "$BIN" 2>/tmp/gc_pressure.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/gc_pressure.err; fail "carriers=$nc run $i hung (watchdog) — a pressure collection or the STW handshake stalled"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/gc_pressure.err; fail "carriers=$nc run $i crashed (exit $rc) — heap exhaustion or a mis-fixed root"; }
    [[ "$got" == "$want" ]] || { cat /tmp/gc_pressure.err; fail "carriers=$nc run $i output '$got' != oracle '$want' — collection not transparent"; }
    ncol=$(grep -c "nomu-gc-pressure: collection" /tmp/gc_pressure.err)
    [[ $ncol -ge 2 ]] || { cat /tmp/gc_pressure.err; fail "carriers=$nc run $i: only $ncol collection(s) — heap pressure did not drive repeated collection"; }
  done
done

echo "PASS: heap-pressure-triggered self-hosted Immix collection — a fiber over-allocating 640 MiB on a 256 MiB heap survives via repeated defrag collections at a scheduler STW, output-identical to MMTk NoGC across $ITERS runs at 1/2/4 carriers (NOMU_SCHED=nomu + NOMU_GC_PLAN=nomu; multi-carrier exercises the 150.3.10.1 TLAB reset)"
