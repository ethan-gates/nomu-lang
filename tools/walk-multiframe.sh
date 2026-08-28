#!/bin/zsh
# Task 150 · rung 2 — the Nomu pcsp stack walk validated MULTI-FRAME against the proven C libunwind walk.
# examples/walk_multiframe.nomu holds roots in two frames (inner: 33,44; outer: 11,22 across the inner
# call) and runs rtCollectRoots (the Nomu pcsp walk) immediately before sleep(0); under NOMU_GC_SMOKE the
# C walk runs at that same sleep safepoint. Both see the same live set, so the DISTINCT root .v values must
# match — proving the Nomu walk steps inner -> outer -> main and recovers exactly the roots the C walk does.
# Compiled with NOMU_NO_ESCAPE=1 so the leaf Box roots are heap-allocated (not stack-promoted), same as the
# gc-smoke fixture. The Nomu walk reports base/derived slot pairs (deduped here with sort -u).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$ROOT/examples/walk_multiframe.nomu" >/dev/null 2>&1 || fail "compile walk_multiframe"
NOMU_GC_SMOKE=1 "$ROOT/build/examples/walk_multiframe" 2>/tmp/wm.err 1>/tmp/wm.out || fail "run nonzero exit"

nomu=$(grep '^NOMU-ROOT ' /tmp/wm.out | sed 's/^NOMU-ROOT //' | sort -u)
cwalk=$(grep -oE 'v=-?[0-9]+' /tmp/wm.err | sed 's/v=//' | sort -u)
expected=$'11\n22\n33\n44'

[[ -n "$nomu" ]] || fail "Nomu walk recovered no roots"
[[ "$cwalk" == "$expected" ]] || { echo "FAIL: C walk did not find the 4 roots"; echo "  got: $(echo $cwalk)"; exit 1; }
[[ "$nomu" == "$cwalk" ]] || { echo "FAIL: Nomu walk roots differ from C walk"; echo "  nomu: $(echo $nomu)"; echo "  c:    $(echo $cwalk)"; exit 1; }
echo "PASS: Nomu pcsp walk recovers the same roots as the C libunwind walk across 2 frames — distinct set {$(echo $nomu | tr '\n' ' ')}"
