#!/bin/zsh
# Task 150.3.12.3 — `any I` value-payload boxes survive a self-hosted moving collection. A value type
# boxed as `any I` gets a heap payload copy that is now a proper GC object `{ header, value }` (real type-id
# + the value's managed-pointer map, the 150.3.13 pattern). examples/gc_anybox.nomu keeps 64 boxed Pt values
# live while garbage over-allocation forces collections, then dispatches `total()` through each — reading the
# Pt back through the relocated payload. Header-less (pre-fix), the collector read the value's first word as a
# bogus type-id and mis-copied/mis-scanned the payload: the run crashed or printed nothing under a moving
# collection. The expected total is 10432, deterministic.
#
# Verified on the default block-on-OOM path: the heap-filling run triggers defrag collections that relocate
# payloads while the boxes are live. (Force-all evacuation — NOMU_STW_COLLECT — is not used here: it moves
# every block unconditionally with no to-space self-limit, so it is unsafe on a heap-filling program; it is
# the small-fixture stress in stw-collect.sh.) A collection must actually fire. NOMU_NO_ESCAPE keeps the
# boxes on the real heap.
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${GC_ANYBOX_ITERS:-6}
fail() { echo "FAIL: $1"; exit 1; }
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 180; waitpid($p,0); exit($?>>8)' "$@"; }

"$NOMUC" "$ROOT/examples/gc_anybox.nomu" >/dev/null 2>&1 || fail "compile gc_anybox"
BIN=$ROOT/build/examples/gc_anybox

want=$(run "$BIN" 2>/dev/null); [[ "$want" == "10432" ]] || fail "MMTk oracle '$want' != 10432"

# Default block-on-OOM: a collection fires mid-run while the boxes are live.
for i in $(seq 1 $ITERS); do
  got=$(NOMU_RUNTIME=selfhost NOMU_CARRIERS=1 NOMU_GC_DEBUG_PRESSURE=1 run "$BIN" 2>/tmp/gc_anybox.err); rc=$?
  [[ $rc -eq 124 ]] && { cat /tmp/gc_anybox.err; fail "OOM run $i hung"; }
  [[ "$got" == "$want" ]] || { cat /tmp/gc_anybox.err; fail "OOM run $i: '$got' != '$want' (rc=$rc) — a value payload mis-evacuated under a moving collection"; }
  ncol=$(grep -c "nomu-gc-sync: collection" /tmp/gc_anybox.err)
  [[ $ncol -ge 1 ]] || { cat /tmp/gc_anybox.err; fail "OOM run $i: no collection fired"; }
done

echo "PASS: any-I value-payload boxes survive a self-hosted moving collection — 64 boxed values read back identical to MMTk (10432) under default block-on-OOM ($ITERS/$ITERS runs, NOMU_RUNTIME=selfhost)"
