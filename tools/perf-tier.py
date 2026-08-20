#!/usr/bin/env python3
"""Perf-validation harness for the M7 optimizer tier (m7-spec.md §7.5 exit criterion).

Compiles each workload under a set of pass configurations, runs the resulting binary
several times (best wall-clock reported, to cut noise), and prints a table of times and
speedups. Correctness is guarded: every tier config's stdout must match the NOIR baseline's,
so a config that changes program output is flagged rather than silently trusted.

Configurations (all but `noir` use the SSAIR egress; passes are A/B-toggled by NOMU_NO_*):

  noir   the pre-M7 NOIR oracle egress (reference point)
  off    SSAIR, every pass disabled  (the inert tier — isolates egress cost)
  esc    off + escape analysis only
  dev    off + devirtualization only
  di     off + devirt + inline       (inline's targets come from devirt)
  all    SSAIR, every pass on        (the compounded pipeline)

Usage:
  tools/perf-tier.py [--iters N] [--release] [workload ...]

`workload` is a path to a .nomu file, or a bare name resolved under examples/benchmarks/.
Default workloads are the tier microbenchmarks plus binary-tree. Compilation goes through
the built `nomuc` (run `bazel build //src/nomu-cli:nomuc` first).
"""

import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMUC = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomuc")
BENCH_DIR = os.path.join(ROOT, "examples", "benchmarks")

# name -> extra environment (on top of the SSAIR egress, except `noir`). A pass is *enabled*
# by the absence of its NOMU_NO_* flag; `off` disables all three.
CONFIGS = [
    ("noir", {}),                                                              # NOIR oracle
    ("off",  {"NOMU_EGRESS": "ssair", "NOMU_NO_DEVIRT": "1", "NOMU_NO_INLINE": "1", "NOMU_NO_ESCAPE": "1"}),
    ("esc",  {"NOMU_EGRESS": "ssair", "NOMU_NO_DEVIRT": "1", "NOMU_NO_INLINE": "1"}),
    ("dev",  {"NOMU_EGRESS": "ssair", "NOMU_NO_INLINE": "1", "NOMU_NO_ESCAPE": "1"}),
    ("di",   {"NOMU_EGRESS": "ssair", "NOMU_NO_ESCAPE": "1"}),
    ("all",  {"NOMU_EGRESS": "ssair"}),
]

# The tier microbenchmarks plus real GC/compute workloads.
DEFAULT_WORKLOADS = ["micro_dispatch", "micro_alloc", "hashmap", "gc_barrier", "gc_footprint", "binary-tree"]


def resolve(name):
    """A workload path from a bare name or an explicit path."""
    if os.path.isfile(name):
        return os.path.abspath(name)
    cand = os.path.join(BENCH_DIR, name if name.endswith(".nomu") else name + ".nomu")
    if os.path.isfile(cand):
        return cand
    sys.exit(f"perf-tier: workload not found: {name}")


def binary_path(src):
    """Where the compiler drops the linked binary: <root>/build/<relpath-without-ext>."""
    rel = os.path.relpath(src, ROOT)
    return os.path.join(ROOT, "build", os.path.splitext(rel)[0])


def compile_config(src, env_extra, release):
    env = dict(os.environ)
    env.update(env_extra)
    cmd = [NOMUC, src]
    if release:
        cmd.append("-O")
    r = subprocess.run(cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        return False, r.stderr.decode(errors="replace")
    return True, ""


def run_timed(binary, iters):
    """Best wall-clock over `iters` runs (plus one untimed warm-up); returns (ms, stdout)."""
    subprocess.run([binary], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)  # warm-up
    best = None
    out = b""
    for _ in range(iters):
        t0 = time.perf_counter()
        p = subprocess.run([binary], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        dt = (time.perf_counter() - t0) * 1000.0
        out = p.stdout
        best = dt if best is None else min(best, dt)
    return best, out.decode(errors="replace").strip()


def main():
    args = sys.argv[1:]
    iters = 5
    release = False
    workloads = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--iters":
            iters = int(args[i + 1]); i += 2; continue
        if a == "--release":
            release = True; i += 1; continue
        if a in ("-h", "--help"):
            print(__doc__); return
        workloads.append(a); i += 1
    if not workloads:
        workloads = DEFAULT_WORKLOADS
    if not os.path.exists(NOMUC):
        sys.exit(f"perf-tier: {NOMUC} not found — run `bazel build //src/nomu-cli:nomuc` first")

    names = [c[0] for c in CONFIGS]
    header = f"{'workload':<16}" + "".join(f"{n:>9}" for n in names) + f"{'all/off':>10}"
    print(f"perf-tier — best of {iters} runs, ms{' (-O)' if release else ''}\n")
    print(header)
    print("-" * len(header))

    for w in workloads:
        src = resolve(w)
        binary = binary_path(src)
        times = {}
        baseline_out = None
        note = ""
        for name, env_extra in CONFIGS:
            ok, err = compile_config(src, env_extra, release)
            if not ok:
                times[name] = None
                note = f"  (compile fail @ {name}: {err.strip().splitlines()[-1] if err.strip() else '?'})"
                continue
            ms, out = run_timed(binary, iters)
            times[name] = ms
            if name == "noir":
                baseline_out = out
            elif baseline_out is not None and out != baseline_out:
                note += f"  [!{name} output differs]"

        def cell(n):
            v = times.get(n)
            return "  -  " if v is None else f"{v:.0f}"
        row = f"{w:<16}" + "".join(f"{cell(n):>9}" for n in names)
        off, allv = times.get("off"), times.get("all")
        speedup = f"{off/allv:.2f}x" if off and allv else "-"
        print(row + f"{speedup:>10}" + note)


if __name__ == "__main__":
    main()
