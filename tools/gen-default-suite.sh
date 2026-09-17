#!/bin/zsh
# One-off (150.4.5.3): run the GC/generational driver scripts in parallel to verify generational-on-by-default.
# Each dedicated script carries the correct env + oracle for its fixture. The block-on-OOM scripts (gc-anybox,
# gc-string, gc-pressure, gc-gen, gc-stress, ...) run selfhost with NO reserve knob, so they now exercise the
# default-on generational path — the "did it only pass because it was major-only?" cases. The gen-* scripts
# force a small reserve (the positive override path). Runs P-wide via xargs; per-script timeout catches hangs.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
OUT=/tmp/gen-default-suite

SCRIPTS=(
  gc-anybox gc-string gc-pressure gc-gen gc-stress gc-concurrent
  gc-actor gc-actor-teardown gc-smoke gc-smoke-stw gc-smoke-parked gc-smoke-tier gc-t6-stw gc-oom
  gen-minor gen-nursery gen-barrier gen-major gen-los gen-multicarrier
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

# Parent: reset the log dir once, then fan out.
rm -rf "$OUT"; mkdir -p "$OUT"
export ROOT OUT
printf '%s\n' "${SCRIPTS[@]}" | xargs -P 6 -I{} zsh "$0" --one "$CAP" {} | sort | tee "$OUT/summary.txt"
echo "==="
bad=$(grep -cE '^(FAIL|HANG)' "$OUT/summary.txt")
echo "failures=$bad  (logs in $OUT)"
exit $bad
