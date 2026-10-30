#!/usr/bin/env python3
# Run a command under a memory cap and a wall-clock limit, for binaries that might grow without bound.
# macOS does not enforce `ulimit -v`, so this polls the process group's physical footprint (resident plus
# compressed, as Activity Monitor counts it) every 5 ms and kills its process group with SIGKILL past the cap.
# Usage: memcap.py [--mb N] [--sec N] [--stop] -- command args...   (defaults: 2048 MB, 60 s)
# Exit status: the command's, or 137 with a "memcap:" line on stderr when it was killed. With --stop, a
# process over a limit is frozen (SIGSTOP) instead of killed, for a debugger to attach; memcap prints its pid
# and exits 138, and the caller must kill it (`kill -9 <pid>`).
import ctypes, os, signal, subprocess, sys, time

def footprint_bytes(pid):
    # proc_pid_rusage(RUSAGE_INFO_V2): words 0-1 are the uuid, then user and system time, package idle and
    # interrupt wakeups, pageins, wired, resident, and the physical footprint at word 9.
    buf = (ctypes.c_uint64 * 40)()
    if libproc.proc_pid_rusage(pid, 2, ctypes.byref(buf)) != 0:
        return 0
    return buf[9]

args = sys.argv[1:]
mb, sec, stop = 2048, 60, False
while args and args[0] != "--":
    if args[0] == "--stop":
        stop, args = True, args[1:]
        continue
    flag, val = args[0], args[1]
    if flag == "--mb": mb = int(val)
    elif flag == "--sec": sec = float(val)
    else: sys.exit(f"memcap: unknown option {flag}")
    args = args[2:]
cmd = args[1:]
if not cmd:
    sys.exit("usage: memcap.py [--mb N] [--sec N] -- command args...")

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
cap = mb * 1024 * 1024
proc = subprocess.Popen(cmd, start_new_session=True)
start, peak, reason = time.monotonic(), 0, None
while proc.poll() is None:
    used = footprint_bytes(proc.pid)
    peak = max(peak, used)
    if used > cap:
        reason = f"footprint {used >> 20} MB over the {mb} MB cap"
    elif time.monotonic() - start > sec:
        reason = f"over the {sec:g} s limit"
    if reason and stop:
        os.killpg(proc.pid, signal.SIGSTOP)
        print(f"memcap: stopped pid {proc.pid}: {reason}", file=sys.stderr)
        sys.exit(138)
    if reason:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        print(f"memcap: killed: {reason}", file=sys.stderr)
        sys.exit(137)
    time.sleep(0.005)
print(f"memcap: peak footprint {peak >> 20} MB", file=sys.stderr)
sys.exit(proc.returncode if proc.returncode >= 0 else 128 - proc.returncode)
