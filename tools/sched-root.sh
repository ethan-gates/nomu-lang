#!/bin/zsh
# Task 128.3.1 — self-hosted scheduler-root scan, diffed against the C read in-process.
#
# examples/sched_root.nomu: main sends one fire-and-forget `bump`, enqueuing the Counter's mailbox onto the
# global scheduled queue (rt_sched_head). Run single-carrier (NOMU_CARRIERS=1) so no mailbox fiber drains it
# before main reads it. rtScanSchedRoot reads rt_sched_head self-hosted (RawPtr.gcSchedHead() loads the
# global) and prints its pointer (stdout SCHED-ROOT). Under NOMU_GC_SMOKE_SCHED the C oracle reads the same
# global at main's sleep safepoint (stderr `sched-root`).
#
# Asserts: the Nomu-recovered pointer is non-null, exactly one root is reported, and it equals the C oracle's
# pointer. A wrong global reference or a missed store would read null or a different address.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOMUC=$ROOT/bazel-bin/src/nomu-cli/nomuc
fail() { echo "FAIL: $1"; exit 1; }

"$NOMUC" "$ROOT/examples/sched_root.nomu" >/dev/null 2>&1 || fail "compile sched_root"

out=$(NOMU_CARRIERS=1 NOMU_GC_SMOKE_SCHED=1 "$ROOT/build/examples/sched_root" 2>/tmp/sched_root.err) \
  || fail "sched_root nonzero exit"
cerr=$(cat /tmp/sched_root.err)

nroots=$(echo "$out" | grep '^nroots ' | sed 's/^nroots //')
nomu_ptr=$(echo "$out" | grep '^SCHED-ROOT ' | sed 's/^SCHED-ROOT //')
c_ptr=$(echo "$cerr" | grep -oE 'sched-root -?[0-9]+' | sed 's/sched-root //')

[[ "$nroots" == "1" ]] || { echo "FAIL: expected 1 scheduler root, got '$nroots'"; echo "$out"; echo "$cerr"; exit 1; }
[[ -n "$nomu_ptr" && "$nomu_ptr" != "0" ]] || { echo "FAIL: Nomu sched root null/empty ('$nomu_ptr')"; echo "$out"; exit 1; }
[[ -n "$c_ptr" && "$c_ptr" != "0" ]] || { echo "FAIL: C oracle sched root null/empty ('$c_ptr')"; echo "$cerr"; exit 1; }
[[ "$nomu_ptr" == "$c_ptr" ]] || fail "Nomu sched root diverges from C oracle ('$nomu_ptr' vs '$c_ptr')"

echo "PASS: self-hosted scheduler-root scan recovered rt_sched_head ($nomu_ptr) via RawPtr.gcSchedHead(), matching the C oracle; single managed root reported"
