#!/usr/bin/env python3
"""GC baseline: times the benchmark workloads under each collector mode and records the GC report's metrics.

For each workload and plan it builds a `release` binary (for timing) and a `release` + `gc_record` binary (for
the report), then runs both on 1 and 4 carriers. The plans are generational (`genimmix`, the default) and
major-only (`immix`, the `gc_immix` config: no nursery and no write barrier). Timing is the best wall clock of N runs; a run whose output changes between runs is
flagged. Results go to <out>/baseline.json and a table on stdout.

Usage:
  tools/gc-baseline.py [--iters N] [--out DIR] [workload ...]

Build the compiler first: bazel build -c opt //src/nomu-cli:nomu
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")
BENCH_DIR = os.path.join(ROOT, "benchmarks")
DEFAULT_WORKLOADS = ["micro_alloc", "alloc_live", "binary_tree", "gc_barrier", "gc_footprint", "micro_carried",
                     "micro_dispatch"]
MODES = [("gen", []), ("major", ["gc_immix"])]
CARRIERS = ["1", "4"]


def build(workload, configs, dest):
    """Build `workload` under `configs` and copy its binary to `dest`."""
    src = os.path.join(BENCH_DIR, workload)
    r = subprocess.run([NOMU, "build"] + [f"--config={c}" for c in configs] + [src], capture_output=True,
                       cwd=ROOT)
    if r.returncode != 0:
        sys.exit(f"gc-baseline: build failed for {workload}:\n{r.stderr.decode(errors='replace')}")
    with open(os.path.join(ROOT, "build", "_perf", "report.json")) as f:
        shutil.copy(json.load(f)["binaries"][-1], dest)
    return dest


def best_time(binary, env, iters):
    """Best wall clock of `iters` runs, or (None, why) when a run fails or its output changes."""
    best, first = None, None
    for _ in range(iters):
        start = time.perf_counter()
        r = subprocess.run([binary], capture_output=True, env=env, timeout=300)
        took = time.perf_counter() - start
        if r.returncode != 0:
            return None, f"exit {r.returncode}"
        if first is not None and r.stdout != first:
            return None, "output changed between runs"
        first = r.stdout
        best = took if best is None else min(best, took)
    return best, None


def gc_metrics(binary, env, scratch):
    """The `metrics` object of one recorded run's GC report."""
    d = tempfile.mkdtemp(dir=scratch)
    subprocess.run([binary], capture_output=True, env=dict(env, NOMU_GC_REPORT_DIR=d), timeout=300)
    reports = [p for p in glob.glob(os.path.join(d, "*.json")) if not p.endswith(".trace.json")]
    if not reports:
        return None
    with open(reports[0]) as f:
        return json.load(f).get("metrics")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=7)
    ap.add_argument("--out", default=os.path.join(ROOT, "build", "gc-baseline"))
    ap.add_argument("workloads", nargs="*", default=DEFAULT_WORKLOADS)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix="gc-baseline-")

    rows = {}
    print(f"{'workload':15} {'car':>3} {'mode':5} {'wall':>9} {'cycles':>6} {'gc ms':>8} "
          f"{'p50 ms':>7} {'max ms':>7} {'ttsp99':>7} {'peak MB':>7}")
    for w in args.workloads:
        bins = {mode: (build(w, ["release"] + cfgs, os.path.join(scratch, f"{w}-{mode}-release")),
                       build(w, ["release", "gc_record"] + cfgs, os.path.join(scratch, f"{w}-{mode}-record")))
                for mode, cfgs in MODES}
        for car in CARRIERS:
            for mode, _ in MODES:
                rel, rec = bins[mode]
                env = dict(os.environ, NOMU_CARRIERS=car)
                wall, err = best_time(rel, env, args.iters)
                m = gc_metrics(rec, env, scratch)
                rows[f"{w}/c{car}/{mode}"] = {"wall_s": wall, "error": err, "metrics": m}
                if err:
                    print(f"{w:15} {car:>3} {mode:5} {err}")
                    continue
                m = m or {}
                p = m.get("pauses", {})
                print(f"{w:15} {car:>3} {mode:5} {wall:8.4f}s {m.get('cycles', 0):6} "
                      f"{m.get('gcTime', 0) / 1e3:8.1f} {p.get('p50', 0) / 1e3:7.2f} {p.get('max', 0) / 1e3:7.2f} "
                      f"{m.get('timeToSafepoint', {}).get('p99', 0) / 1e3:7.2f} "
                      f"{m.get('heap', {}).get('peakBytesInUse', 0) >> 20:7}", flush=True)
    with open(os.path.join(args.out, "baseline.json"), "w") as f:
        json.dump(rows, f, indent=1)
    shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
