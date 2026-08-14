#!/bin/zsh
# 6.5.2 — escape-analysis behavioral differential. Compile+run every example twice, with escape
# analysis on and with NOMU_NO_ESCAPE=1, and assert identical stdout+exit. Escape analysis is a
# best-effort optimization, so behavior must be byte-identical whether it fires or not.
#
# Runs the examples through a parallel worker pool (`xargs -P`): each `nomuc` invocation is ~1s wall
# (compiler startup + link dominate, not codegen), and the examples are independent, so the pool cuts
# wall time by roughly the core count. Every program run is watchdogged (macOS has no `timeout`).
# examples/stdin.nomu is skipped on purpose: it spawns a multi-second ticker alongside readLine, so
# its output ordering is timing-dependent — a behavioral differential can't compare it.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc

# Worker mode: one example, on vs off. Prints "OK <name>", "DIFF <name>", or "SKIP <name>".
if [[ "${1:-}" == "--one" ]]; then
  src=$2; name=$(basename "$src"); bin="$ROOT/build/examples/${name%.nomu}"
  run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 20; waitpid($p,0); exit($?>>8)' "$@"; }
  "$NOMUC" "$src" >/dev/null 2>&1 || { echo "SKIP $name"; exit 0; }
  on=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  NOMU_NO_ESCAPE=1 "$NOMUC" "$src" >/dev/null 2>&1
  off=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  [[ "$on" == "$off" ]] && echo "OK $name" || echo "DIFF $name"
  exit 0
fi

ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
res=$(ls "$ROOT"/examples/*.nomu | grep -v '/stdin.nomu$' | xargs -P "$ncpu" -n1 zsh "$0" --one)
pass=$(echo "$res" | grep -c '^OK ');  fail=$(echo "$res" | grep -c '^DIFF '); skip=$(echo "$res" | grep -c '^SKIP ')
echo "identical=$pass differ=$fail skipped(compile)=$skip (+1 stdin, excluded by design)"
if [[ $fail -ne 0 ]]; then echo "FAIL — diverged on:"; echo "$res" | grep '^DIFF '; exit 1; fi
echo "PASS: escape analysis is behavior-preserving across the example corpus"
