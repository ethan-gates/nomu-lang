#!/bin/zsh
# Egress differential (M7 · m7-spec §7.0.5, T1). Compile+run every example twice — once through the
# default NOIR oracle egress, once through the SSAIR tier egress (NOMU_EGRESS=ssair, all passes on) —
# and assert identical stdout+exit. The SSAIR path must be a behavior-preserving replacement for the
# oracle, so any divergence is a tier bug.
#
# Runs through a parallel worker pool (`xargs -P`): each `nomuc` invocation is ~1s wall (startup +
# link dominate), and the examples are independent, so the pool cuts wall time by ~core count. Every
# program run is watchdogged (macOS has no `timeout`). examples/stdin.nomu is excluded: it spawns a
# timing-dependent ticker alongside readLine, so its output ordering can't be compared.
#
# Two properties this script is careful about (both were latent holes in the ad-hoc inline version):
#   1. It globs examples/ *and* examples/benchmarks/ — the benchmark workloads are in scope.
#   2. A failed SSAIR compile is a hard failure (CFAIL), not a silent pass: the runner recompiles in
#      place, so without this a broken SSAIR build would leave the NOIR binary and read as identical.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc

# Worker mode: one example, NOIR vs SSAIR. Prints OK / DIFF / CFAIL / SKIP <name>. The binary path is
# derived from the source's path relative to the repo root, so examples/benchmarks/ resolves too.
if [[ "${1:-}" == "--one" ]]; then
  src=$2; name=$(basename "$src"); rel=${src#$ROOT/}; bin="$ROOT/build/${rel%.nomu}"
  run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 20; waitpid($p,0); exit($?>>8)' "$@"; }
  "$NOMUC" "$src" >/dev/null 2>&1 || { echo "SKIP $name"; exit 0; }   # NOIR must compile to be in scope
  noir=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  NOMU_EGRESS=ssair "$NOMUC" "$src" >/dev/null 2>&1 || { echo "CFAIL $name"; exit 0; }
  ssair=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  [[ "$noir" == "$ssair" ]] && echo "OK $name" || echo "DIFF $name"
  exit 0
fi

ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
res=$(ls "$ROOT"/examples/*.nomu "$ROOT"/examples/benchmarks/*.nomu | grep -v '/stdin.nomu$' | xargs -P "$ncpu" -n1 zsh "$0" --one)
pass=$(echo "$res" | grep -c '^OK '); fail=$(echo "$res" | grep -c '^DIFF '); skip=$(echo "$res" | grep -c '^SKIP '); cfail=$(echo "$res" | grep -c '^CFAIL ')
echo "identical=$pass differ=$fail ssair-compile-fail=$cfail skipped(noir-compile)=$skip (+1 stdin, excluded by design)"
if [[ $cfail -ne 0 ]]; then echo "FAIL — SSAIR egress failed to compile:"; echo "$res" | grep '^CFAIL '; exit 1; fi
if [[ $fail -ne 0 ]]; then echo "FAIL — NOIR/SSAIR diverged on:"; echo "$res" | grep '^DIFF '; exit 1; fi
echo "PASS: the SSAIR tier egress matches the NOIR oracle across the example corpus"
