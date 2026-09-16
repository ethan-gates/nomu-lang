#!/bin/zsh
# IR golden harness — verify a refactor leaves compiler output byte-identical.
#
# Emits NOIR for every example (the --stop=noir debug view writes even for files
# with semantic errors, so error paths are covered) and SSAIR for the examples
# that compile clean, into a snapshot directory. `compare` diffs two snapshots
# and reports any file that differs, is missing, or is newly present.
#
#   tools/ir-golden.sh capture <dir>              # build nomuc, emit all IR into <dir>
#   tools/ir-golden.sh compare <before> <after>   # diff two snapshots
#
# Typical use around a refactor:
#   tools/ir-golden.sh capture build/ir-golden/before
#   ...make changes...
#   tools/ir-golden.sh capture build/ir-golden/after
#   tools/ir-golden.sh compare build/ir-golden/before build/ir-golden/after
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

capture() {
  local out=$1
  mkdir -p "$out"
  rm -f "$out"/*.noir(N) "$out"/*.ssair(N) "$out"/*.ll(N)
  echo "building nomuc (opt)..."
  # Release build: ~80MB and much faster startup than the fastbuild binary, which
  # matters because startup dominates each invocation. Resolve the binary via cquery
  # so we reference the opt output regardless of where the bazel-bin symlink points.
  bazel build //:nomuc -c opt >/dev/null 2>&1 || { echo "build failed"; exit 1; }
  local NOMUC=$ROOT/$(bazel cquery --output=files //:nomuc -c opt 2>/dev/null)
  [[ -x "$NOMUC" ]] || { echo "nomuc not found at $NOMUC"; exit 1; }
  # All emits in one run, files in parallel, amortizes startup. `--stop=llvm` writes NOIR before the
  # codegen-fatal check (so an erroring file still yields its .noir), SSAIR for clean files, and the
  # egress LLVM IR (pre-opt) for clean files — halting before object emission + linking to stay fast.
  local jobs=${NOMU_GOLDEN_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}
  rm -f "$ROOT"/build/examples/*.noir(N) "$ROOT"/build/examples/*.ssair(N) "$ROOT"/build/examples/*.ll(N)
  print -l "$ROOT"/examples/*.nomu \
    | xargs -P "$jobs" -I{} "$NOMUC" --emit-noir --emit-ssair --emit-llvm --stop=llvm {} >/dev/null 2>&1
  local n=0
  for f in "$ROOT"/examples/*.nomu; do
    local name=${f:t:r}
    [[ -f "$ROOT/build/examples/$name.noir"  ]] && cp "$ROOT/build/examples/$name.noir"  "$out/$name.noir"
    [[ -f "$ROOT/build/examples/$name.ssair" ]] && cp "$ROOT/build/examples/$name.ssair" "$out/$name.ssair"
    [[ -f "$ROOT/build/examples/$name.ll"    ]] && cp "$ROOT/build/examples/$name.ll"    "$out/$name.ll"
    n=$((n + 1))
  done
  echo "captured IR for $n examples into $out ($(ls "$out" | wc -l | tr -d ' ') artifacts)"
}

compare() {
  local a=$1 b=$2
  local fail=0
  for f in "$a"/*(.N); do
    local base=${f:t}
    if [[ ! -f "$b/$base" ]]; then echo "MISSING in $b: $base"; fail=1
    elif ! diff -q "$f" "$b/$base" >/dev/null; then echo "DIFFERS: $base"; fail=1
    fi
  done
  for f in "$b"/*(.N); do
    [[ -f "$a/${f:t}" ]] || { echo "EXTRA in $b: ${f:t}"; fail=1; }
  done
  if [[ $fail -eq 0 ]]; then
    echo "IDENTICAL — $(ls "$a" | wc -l | tr -d ' ') artifacts match"
  else
    echo "MISMATCH"; exit 1
  fi
}

case "${1:-}" in
  capture) [[ $# -eq 2 ]] || { echo "usage: $0 capture <dir>"; exit 2; }; capture "$2" ;;
  compare) [[ $# -eq 3 ]] || { echo "usage: $0 compare <before> <after>"; exit 2; }; compare "$2" "$3" ;;
  *) echo "usage: $0 {capture <dir> | compare <before> <after>}"; exit 2 ;;
esac
