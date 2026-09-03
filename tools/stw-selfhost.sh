#!/bin/zsh
# Task 128.3.2 — self-hosted stop-the-world over all mutators. The terminal rung of the scheduler ladder:
# a real STW across the 128.1.9 self-hosted carriers, with each stopped mutator's roots recovered by the
# self-hosted pcsp walk (rtWalkFrom) from a Nomu-captured user-frame anchor — retiring the C libunwind
# carrier crossing (gcParkedAnchors) that 128.3.1 left in place while the scheduler was still C. This is
# what lets GenImmix (150.4) land on the self-hosted scheduler.
#
# Two mutator shapes, each stopped mid-flight and walked self-hosted, diffed against the C libunwind STW
# oracle (NOMU_GC_STW_SMOKE) on the same program:
#   1. stw_running  — two workers spinning in a busy loop (stopped at a back-edge safepoint poll: the poll
#                     shim captures the user-frame anchor, the fiber parks at state 4). The running-mutator
#                     path — the novel piece of this rung.
#   2. stw_selfhost — a worker parked at sleep, walked directly via nomuSchedWalkParked (the parked path).
# Both must recover exactly {111, 222} and exclude the dead 999; the self-hosted set must match the C
# oracle. NOMU_NO_ESCAPE keeps the leaf heap roots off the stack-promotion path (as walk-parked / gc-smoke).
set -u
export NOMU_NO_ESCAPE=1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
ITERS=${STW_SELFHOST_ITERS:-10}
fail() { echo "FAIL: $1"; exit 1; }
# Fork + alarm-kill at 60 s (exit 124) so a stalled handshake (a carrier that never acks / never resumes)
# fails loud instead of wedging.
run() { perl -e 'my $p=fork; if($p==0){exec @ARGV or exit 127} local $SIG{ALRM}=sub{kill 9,$p; exit 124}; alarm 60; waitpid($p,0); exit($?>>8)' "$@"; }
sset() { sort -nu | tr '\n' ' '; }   # a numeric root set, deduped

# ---- 1. running-mutator STW (busy-loop workers stopped at a safepoint poll) ----
"$NOMUC" "$ROOT/examples/stw_running.nomu" >/dev/null 2>&1 || fail "compile stw_running"
RB=$ROOT/build/examples/stw_running
# C libunwind oracle (one forced STW, walks the running carriers' contexts).
c_out=$(NOMU_GC_STW_SMOKE=1 run "$RB" 2>/tmp/stw_running_c.err); rc=$?
[[ $rc -eq 0 ]] || fail "stw_running crashed/hung under the C STW oracle (exit $rc)"
[[ "$c_out" == "333" ]] || fail "stw_running C-plan output '$c_out', want 333"
c_set=$(grep -oE 'v=-?[0-9]+' /tmp/stw_running_c.err | sed 's/v=//' | sset)
[[ "$c_set" == "111 222 " ]] || { echo "$(cat /tmp/stw_running_c.err)"; fail "C oracle set '$c_set', want '111 222'"; }
# Self-hosted STW, looped over carrier counts.
for carriers in 2 4; do
  for i in $(seq 1 $ITERS); do
    out=$(NOMU_SCHED=nomu NOMU_CARRIERS=$carriers NOMU_STW_SELFHOST=1 run "$RB" 2>/tmp/stw_running_sh.err); rc=$?
    [[ $rc -eq 124 ]] && { cat /tmp/stw_running_sh.err; fail "stw_running self-hosted hung (carriers=$carriers run $i) — a carrier never acked or never resumed"; }
    [[ $rc -eq 0 ]]   || { cat /tmp/stw_running_sh.err; fail "stw_running self-hosted crashed (carriers=$carriers run $i exit $rc)"; }
    [[ "$out" == "333" ]] || fail "stw_running self-hosted output '$out', want 333 (carriers=$carriers run $i)"
    sh_set=$(grep -oE 'STW-ROOT -?[0-9]+' /tmp/stw_running_sh.err | sed 's/STW-ROOT //' | sset)
    [[ "$sh_set" == "111 222 " ]] || { cat /tmp/stw_running_sh.err; fail "self-hosted set '$sh_set', want '111 222' (carriers=$carriers run $i)"; }
    echo "$sh_set" | grep -q 999 && fail "self-hosted STW reported a dead root 999 (not precise)"
    [[ "$sh_set" == "$c_set" ]] || fail "self-hosted set '$sh_set' != C oracle '$c_set'"
  done
done
echo "  ok: running-mutator STW — self-hosted walk recovered {111,222} from two busy-loop workers stopped at a safepoint, matching the C libunwind oracle ($ITERS×{2,4 carriers})"

# ---- 2. parked-mutator walk (direct nomuSchedWalkParked over a sleep-parked fiber) ----
"$NOMUC" "$ROOT/examples/stw_selfhost.nomu" >/dev/null 2>&1 || fail "compile stw_selfhost"
SB=$ROOT/build/examples/stw_selfhost
for i in $(seq 1 $ITERS); do
  out=$(NOMU_SCHED=nomu NOMU_CARRIERS=1 run "$SB" 2>/dev/null); rc=$?
  [[ $rc -eq 0 ]] || fail "stw_selfhost crashed/hung (run $i exit $rc)"
  vals=$(echo "$out" | grep '^PARKED-ROOT ' | sed 's/^PARKED-ROOT //' | sset)
  [[ "$vals" == "111 222 " ]] || { echo "$out"; fail "parked-walk set '$vals', want '111 222' (run $i)"; }
  echo "$vals" | grep -q 999 && fail "parked-walk reported a dead root 999"
done
# Oracle: the C libunwind parked walk on the same shape (walk_parked.nomu) recovers the same set.
"$NOMUC" "$ROOT/examples/walk_parked.nomu" >/dev/null 2>&1 || fail "compile walk_parked"
o=$(NOMU_GC_SMOKE_PARKED=1 run "$ROOT/build/examples/walk_parked" 2>/dev/null | grep '^PARKED-ROOT ' | sed 's/^PARKED-ROOT //' | sset)
[[ "$o" == "111 222 " ]] || fail "walk_parked C oracle set '$o', want '111 222'"
echo "  ok: parked-mutator walk — nomuSchedWalkParked recovered {111,222} from a sleep-parked fiber, matching the C libunwind oracle ($ITERS runs)"

echo "PASS: self-hosted STW over all mutators — running (safepoint-stopped) and parked fibers both walked self-hosted (rtWalkFrom, no libunwind), matching the C oracle; dead roots excluded"
