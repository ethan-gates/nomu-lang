#!/bin/zsh
# Task 150.3.12.2 — String (immortal-buffer) survival under a self-hosted moving collection, on the default
# block-on-OOM path (NOMU_RUNTIME=selfhost, no GC knob). examples/gc_string.nomu grows one String by
# repeated `concat` (each allocates an immortal `data` buffer via rt_alloc_immortal) while over-allocating
# garbage Boxes far past the 256 MiB heap, folding a content hash of the String each iteration. Immortal
# buffers live off-heap relative to the self-hosted Immix space: the evacuator's off-heap guard leaves them
# in place and the sweep never touches them, so the String reads back intact across every collection.
#
# Oracle: MMTk NoGC never collects, so the buffers trivially survive; the block-on-OOM run must fold the
# identical hash. A collection must actually fire (else the heap never filled). NOMU_NO_ESCAPE keeps the
# garbage Boxes on the real heap.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_STRING_ITERS:-4}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 180; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_string.nomu" >/dev/null 2>&1 || fail "compile gc_string"
BIN=$ROOT/build/examples/gc_string

want=$(run "$BIN" 2>/dev/null); [[ -n "$want" ]] || fail "no MMTk oracle output"

for nc in 1 2 4; do
  for i in $(seq 1 $ITERS); do
    got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=$nc NOMU_GC_DEBUG_PRESSURE=1 run "$BIN" 2>/tmp/gc_string.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/gc_string.err; fail "carriers=$nc run $i hung (watchdog)"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/gc_string.err; fail "carriers=$nc run $i crashed (exit $rc) — an immortal buffer moved/swept under a moving collection"; }
    [[ "$got" == "$want" ]] || { cat /tmp/gc_string.err; fail "carriers=$nc run $i hash '$got' != MMTk oracle '$want'"; }
    ncol=$(grep -c "nomu-gc-sync: collection" /tmp/gc_string.err)
    [[ $ncol -ge 1 ]] || { cat /tmp/gc_string.err; fail "carriers=$nc run $i: no collection fired (heap never filled — nothing proven)"; }
  done
done

echo "PASS: String immortal buffers survive a self-hosted moving collection — a String-heavy program folds a hash identical to MMTk NoGC while collections fire at true OOM, single- and multi-carrier ($ITERS/$ITERS runs, NOMU_RUNTIME=selfhost, no GC knob)"
