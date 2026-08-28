#!/bin/zsh
# Task 128.3.1 — self-hosted parked-fiber root scan, diffed against the C libunwind walk in-process.
#
# examples/walk_parked.nomu: worker parks holding {111, 222} live across sleep(200); dead 999 is excluded.
# While worker is parked, main calls rtScanParkedFibers: the C runtime hands each parked fiber's innermost
# Nomu-frame anchor as a (sp, pc) pair (rt_gc_parked_anchors — it crosses the C park frames with its
# unwinder), and Nomu runs the pcsp walk from each anchor, self-hosted, reading root slots and stepping
# between Nomu frames. Under NOMU_GC_SMOKE_PARKED the C walk also runs at the same point (its `v=` on stderr).
#
# Asserts: the Nomu-recovered set (stdout PARKED-ROOT) is exactly {111, 222}, matches the C oracle set
# (stderr v=), and excludes the dead 999. A stale/garbage anchor or a bad frame step would fault or diverge.
set -u
export NOMU_NO_ESCAPE=1   # leaf heap roots this test relies on must not be stack-promoted (as gc-smoke-parked)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$ROOT/examples/walk_parked.nomu" >/dev/null 2>&1 || fail "compile walk_parked"

out=$(NOMU_GC_SMOKE_PARKED=1 "$ROOT/build/examples/walk_parked" 2>/tmp/walk_parked.err)
cerr=$(cat /tmp/walk_parked.err)

# Nomu-recovered set (self-hosted walk). Dedup base/derived slot pairs (RewriteStatepointsForGC records each
# GC root as a (base, derived) pair, so the raw slot read reports each root twice; the tracer dedups via the
# header mark bit — here we compare the set).
nomu_vals=$(echo "$out" | grep '^PARKED-ROOT ' | sed 's/^PARKED-ROOT //' | sort -nu | tr '\n' ' ')
# C oracle set (libunwind walk).
c_vals=$(echo "$cerr" | grep -oE 'v=-?[0-9]+' | sed 's/v=//' | sort -nu | tr '\n' ' ')

[[ "$nomu_vals" == "111 222 " ]] || { echo "FAIL: Nomu parked set (expected '111 222', got '$nomu_vals')"; echo "$out"; echo "$cerr"; exit 1; }
echo "$nomu_vals" | grep -q 999 && fail "Nomu reported dead object 999 (not precise)"
[[ "$c_vals" == "111 222 " ]] || { echo "FAIL: C oracle set (expected '111 222', got '$c_vals')"; echo "$cerr"; exit 1; }
[[ "$nomu_vals" == "$c_vals" ]] || fail "Nomu walk diverges from C oracle ('$nomu_vals' vs '$c_vals')"

echo "PASS: self-hosted parked-fiber walk recovered {111, 222} from worker's saved context (pcsp walk over the saved stack; C crossed the park frames), matching the C libunwind oracle; dead 999 excluded"
