#!/bin/zsh
# Escape-analysis behavioral differential. Build and run every example module twice, with escape analysis
# on and with escape analysis off (`-c no_escape`), and assert identical stdout+exit. Escape analysis is a best-effort
# optimization, so behavior must be byte-identical whether it fires or not.
#
# Examples run through a parallel worker pool (`xargs -P`); the examples are independent. Builds take turns
# (one `nomu` per workspace at a time) and the runs go in parallel. Every program run is watchdogged (macOS has no `timeout`) with
# stdin closed, on one carrier (NOMU_CARRIERS=1): multi-carrier output order depends on scheduling (separate
# `print` calls from concurrent actors interleave), which would hide the one variable under test. An example
# that does not build with default options (e.g. one needing `-c rt_prelude`) is skipped. Usage, from anywhere: tools/escape-diff.sh  (build `//src/nomu-cli:nomu` first).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export NOMU=$ROOT/bazel-bin/src/nomu-cli/nomu
# Worker mode: one example module directory, on vs off. Prints "OK <name>", "DIFF <name>", "CFAIL <name>",
# or "SKIP <name>". The binary is <repo>/build/<module path>/<leaf> (the compiler's layout), so each build's
# binary runs before the next build replaces it.
if [[ "${1:-}" == "--one" ]]; then
  dir=$2; name=${dir:t}; rel=${dir#$ROOT/}; bin="$ROOT/build/$rel/$name"
  export NOMU_CARRIERS=1
  run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 20; waitpid($p,0); exit($?>>8)' "$@"; }
  "$NOMU" build "$dir" >/dev/null 2>&1 || { echo "SKIP $name"; exit 0; }
  on=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  # A failed off-build must be a hard failure: without this guard the run below could read a stale binary
  # from an earlier run, so a compile break would masquerade as a pass.
  "$NOMU" build -c no_escape "$dir" >/dev/null 2>&1 || { echo "CFAIL $name"; exit 0; }
  off=$(run "$bin" </dev/null 2>&1; echo "rc=$?")
  [[ "$on" == "$off" ]] && echo "OK $name" || echo "DIFF $name"
  exit 0
fi
[[ -x "$NOMU" ]] || { echo "FAIL: $NOMU not built (bazel build -c opt //src/nomu-cli:nomu)"; exit 1; }
ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
dirs=( "$ROOT"/examples/*/main.nomu(N:h) "$ROOT"/examples/benchmarks/*/main.nomu(N:h) )
res=$(print -l $dirs | xargs -P "$ncpu" -I{} zsh "$0" --one {})
pass=$(echo "$res" | grep -c '^OK ');  fail=$(echo "$res" | grep -c '^DIFF '); skip=$(echo "$res" | grep -c '^SKIP '); cfail=$(echo "$res" | grep -c '^CFAIL ')
echo "identical=$pass differ=$fail off-build-fail=$cfail skipped(no default build)=$skip"
if [[ $cfail -ne 0 ]]; then echo "FAIL — off-config build broke on:"; echo "$res" | grep '^CFAIL '; exit 1; fi
if [[ $fail -ne 0 ]]; then echo "FAIL — diverged on:"; echo "$res" | grep '^DIFF '; exit 1; fi
echo "PASS: escape analysis is behavior-preserving across the example corpus"
