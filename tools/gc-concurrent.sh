#!/bin/zsh
# Task 150.3.10.1 / 150.3.13 — multi-carrier self-hosted allocation WITH collection. Four worker fibers
# allocate concurrently on separate carriers (NOMU_RUNTIME=selfhost NOMU_CARRIERS=N), each bumping its own
# per-carrier TLAB and refilling the shared Immix block pool under the space lock. This is the race the
# 150.3.10.1 split closes: before it the mutators bumped one shared descriptor cursor and concurrent carriers
# corrupted it, which is why 150.3.9 ran single-carrier.
#
# The workers over-allocate (4 × 6M × 16 B = 384 MiB ≫ 256 MiB heap), so under NOMU_GC_PRESSURE repeated
# defrag collections fire while all four carriers allocate: the collector stops every carrier, evacuates
# survivors across four stacks, resets all four TLABs, and (150.3.13) keeps each completed-but-unjoined
# worker's result box rooted until main joins it. Each worker returns a checksum over its 64-Box live window;
# the sum is order/address-independent, so the run must match MMTk NoGC exactly at every N. A high trigger
# reserve is used so collections fire often — this is the configuration that flushed out both the space-
# creation race (150.3.10.1) and the fiber-result-box root gap (150.3.13). NOMU_NO_ESCAPE keeps the Boxes off
# the scalar-replacement path (real heap objects).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_CONCURRENT_ITERS:-4}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 120; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_concurrent.nomu" >/dev/null 2>&1 || fail "compile gc_concurrent"
BIN=$ROOT/build/examples/gc_concurrent

# Oracle: MMTk NoGC (1 GiB reserve absorbs the 384 MiB without collecting). The self-hosted collecting run
# must be output-identical at every carrier count.
want=$(run "$BIN" 2>/dev/null)
[[ -n "$want" ]] || fail "no baseline output"

for c in 1 2 4 8; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=$c NOMU_GC_PRESSURE=1 NOMU_GC_TRIGGER_RESERVE=6144 \
          NOMU_GC_DEBUG_PRESSURE=1 run "$BIN" 2>/tmp/gc_concurrent.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/gc_concurrent.err; fail "carriers=$c run $i hung (watchdog) — a refill or the STW handshake stalled"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/gc_concurrent.err; fail "carriers=$c run $i crashed (exit $rc) — concurrent bump/refill race or a mis-fixed root"; }
    [[ "$got" == "$want" ]] || { cat /tmp/gc_concurrent.err; fail "carriers=$c run $i output '$got' != oracle '$want' — concurrent allocation/collection corrupted the heap"; }
    ncol=$(grep -c "nomu-gc-pressure: collection" /tmp/gc_concurrent.err)
    [[ $ncol -ge 2 ]] || { cat /tmp/gc_concurrent.err; fail "carriers=$c run $i: only $ncol collection(s) — over-allocation did not drive repeated collection"; }
  done
done

echo "PASS: multi-carrier self-hosted allocation with collection — four fibers over-allocating 384 MiB on a 256 MiB heap allocate concurrently on 1/2/4/8 carriers through repeated defrag collections, output-identical to MMTk NoGC across $ITERS runs each (NOMU_RUNTIME=selfhost; exercises the 150.3.10.1 concurrent refill + space guard and the 150.3.13 result-box roots)"
