#!/usr/bin/env python3
"""Perf-validation harness for the M7 optimizer tier (m7-spec.md §7.5 exit criterion).

Compiles each workload under a set of pass configurations, runs the resulting binary
several times (best wall-clock reported, to cut noise), and prints a table of times and
speedups. Correctness is guarded: every config's stdout must match the `off` baseline's,
so a config that changes program output is flagged rather than silently trusted.

Configurations (all on the SSAIR egress — the sole backend path; passes A/B-toggled by the `no_*` configs
in the repository's root cfg.yaml):

  off    every pass disabled  (the inert tier — the correctness + timing baseline)
  esc    off + escape analysis (stack + scalar promotion) only
  dev    off + devirtualization only
  di     off + devirt + inline       (inline's targets come from devirt)
  all    every pass on               (the compounded pipeline)

Usage:
  tools/perf-tier.py [--iters N] [--release] [workload ...]

`workload` is a module directory, or a bare name resolved under examples/benchmarks/.
Default workloads are the tier microbenchmarks plus binary_tree. Compilation goes through
the built `nomu` (run `bazel build -c opt //src/nomu-cli:nomu` first). Runs use one carrier
(NOMU_CARRIERS=1) so timings and output are free of scheduling noise.
"""

import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")
BENCH_DIR = os.path.join(ROOT, "examples", "benchmarks")

# name -> the configs selected (root cfg.yaml). A pass is *enabled* by the absence of its `no_*` config;
# `off` disables all three.
CONFIGS = [
    ("off", ["no_devirt", "no_inline", "no_escape"]),  # the inert tier
    ("esc", ["no_devirt", "no_inline"]),
    ("dev", ["no_inline", "no_escape"]),
    ("di",  ["no_escape"]),
    ("all", []),                                       # every pass on
]

# The tier microbenchmarks plus real GC/compute workloads.
DEFAULT_WORKLOADS = ["micro_dispatch", "micro_alloc", "micro_carried", "gc_barrier", "gc_footprint", "binary_tree"]


def resolve(name):
    """A workload module directory from a bare name or an explicit path."""
    if os.path.isdir(name):
        return os.path.abspath(name)
    cand = os.path.join(BENCH_DIR, name)
    if os.path.isdir(cand):
        return cand
    sys.exit(f"perf-tier: workload not found: {name}")


def compile_config(src, configs, release):
    """Build `src` under `configs` (plus `release`); returns (ok, stderr or the binary's path), the path as the
    build reports it."""
    selected = (["release"] if release else []) + configs
    cmd = [NOMU, "build", "--report-jobs"] + [f"--config={c}" for c in selected] + [src]
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        return False, r.stderr.decode(errors="replace")
    lines = [l[len("binary "):] for l in r.stdout.decode().splitlines() if l.startswith("binary ")]
    return (True, lines[-1]) if lines else (False, "the build reported no binary")


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
    if not os.path.exists(NOMU):
        sys.exit(f"perf-tier: {NOMU} not found — run `bazel build -c opt //src/nomu-cli:nomu` first")
    os.environ["NOMU_CARRIERS"] = "1"

    names = [c[0] for c in CONFIGS]
    header = f"{'workload':<16}" + "".join(f"{n:>9}" for n in names) + f"{'all/off':>10}"
    print(f"perf-tier — best of {iters} runs, ms{' (-c release)' if release else ''}\n")
    print(header)
    print("-" * len(header))

    for w in workloads:
        src = resolve(w)
        times = {}
        baseline_out = None
        note = ""
        for name, configs in CONFIGS:
            ok, result = compile_config(src, configs, release)
            if not ok:
                times[name] = None
                note = f"  (compile fail @ {name}: {result.strip().splitlines()[-1] if result.strip() else '?'})"
                continue
            binary = result
            ms, out = run_timed(binary, iters)
            times[name] = ms
            if baseline_out is None:
                baseline_out = out            # the first config (off) is the correctness reference
            elif out != baseline_out:
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
