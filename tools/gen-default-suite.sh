#!/bin/zsh
# Generational-on-by-default check. The bulk of the GC/gen drivers now live in the integration
# manifest (tests/suite.json) and run via compiler-test; this script runs that suite, then the
# few GC tail scripts not yet ported (root-set / contrast / sorted-count cases). Per-script
# timeout catches hangs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=/tmp/gen-default-suite

# Tail scripts still living in tools/ (see tools/README.md for why each is unported).
SCRIPTS=(
  gc-actor gc-actor-teardown gc-smoke gc-smoke-stw gc-smoke-parked gc-smoke-tier gc-t6-stw gc-oom
  gen-multicarrier
)
CAP=240   # per-script hard timeout (s); a generational trigger loop would otherwise hang forever

run_one() {
  s=$1
  log="$OUT/$s.log"
  perl -e 'alarm shift; exec @ARGV' "$CAP" zsh "$ROOT/tools/$s.sh" >"$log" 2>&1
  rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "PASS $s"
  elif [[ $rc -eq 142 ]]; then
    echo "HANG $s (>${CAP}s)"
  else
    echo "FAIL $s (rc=$rc): $(grep -iE 'FAIL|error' "$log" | head -1)"
  fi
}

# Child worker invocation — must NOT touch the shared $OUT dir (only the parent resets it, below).
if [[ "${1:-}" == "--one" ]]; then CAP=$2; run_one "$3"; exit 0; fi

# Parent: the manifest suite first, then the tail scripts fanned out.
rm -rf "$OUT"; mkdir -p "$OUT"
export ROOT OUT
echo "=== manifest suite (compiler-test) ==="
bazel-bin/src/compiler-test/compiler-test tests/suite.json --enable 'gc-*,gen-*,immix-*,stw-*,selfhost-*'
mrc=$?
echo "=== tail scripts ==="
printf '%s\n' "${SCRIPTS[@]}" | xargs -P 6 -I{} zsh "$0" --one "$CAP" {} | sort | tee "$OUT/summary.txt"
echo "==="
bad=$(grep -cE '^(FAIL|HANG)' "$OUT/summary.txt")
echo "manifest rc=$mrc  tail failures=$bad  (logs in $OUT)"
exit $(( bad + (mrc != 0) ))
