#!/usr/bin/env python3
"""Time to stop the world beside running fibers, Nomu against Go (task 236.1.2; goals G2 and P4).

Builds `benchmarks/stop_latency` with the collector's recorder (`--config=rt_prelude --config=gc_record`) and
its Go counterpart (`practice/go/stop_latency`), runs each per mode and carrier count, and prints the time to
stop: Nomu's from the recorder's `timeToSafepoint` (the request to every carrier stopped), Go's from
`/sched/pauses/stopping/gc:seconds` (bucket upper bounds, so coarser). Each cell is the median over `--iters`
runs of that run's p50, p99 and max, in µs.

  mode 0  busy fibers in call-free loops (a poll every iteration)
  mode 1  busy fibers in recursion with no loop and no allocation (a stop waits out the call)

Usage:
  tools/stopbench.py [--iters N] [--carriers 2,4,8] [--modes 0,1] [--no-go]

Needs the built `nomu` (`bazel build -c opt //src/nomu-cli:nomu`) and, for Go, `go` on PATH.
"""

import argparse
import glob
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")


def build_nomu():
    src = os.path.join(ROOT, "benchmarks", "stop_latency")
    r = subprocess.run([NOMU, "build", "--no-history", "--config=rt_prelude", "--config=gc_record", src],
                       capture_output=True, text=True, cwd=ROOT)
    if r.returncode != 0:
        sys.exit(f"stopbench: stop_latency failed to build:\n{r.stderr}")
    return os.path.join(ROOT, "build", "benchmarks", "stop_latency", "stop_latency")


def build_go(tmp):
    out = os.path.join(tmp, "go_stop_latency")
    r = subprocess.run(["go", "build", "-o", out, "./stop_latency"], capture_output=True, text=True,
                       cwd=os.path.join(ROOT, "practice", "go"))
    if r.returncode != 0:
        sys.exit(f"stopbench: the Go counterpart failed to build:\n{r.stderr}")
    return out


def run_nomu(binary, mode, carriers, tmp):
    rep = os.path.join(tmp, "report")
    shutil.rmtree(rep, ignore_errors=True)
    os.makedirs(rep)
    env = dict(os.environ, NOMU_CARRIERS=str(carriers), STOP_MODE=str(mode), NOMU_GC_REPORT_DIR=rep)
    r = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        return None
    files = [f for f in glob.glob(os.path.join(rep, "*.json")) if not f.endswith(".trace.json")]
    t = json.load(open(files[0]))["metrics"]["timeToSafepoint"]
    return (t["p50"], t["p99"], t["max"])


def run_go(binary, mode, carriers):
    env = dict(os.environ, GOMAXPROCS=str(carriers), STOP_MODE=str(mode))
    r = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=300)
    m = re.search(r"stop_us p50 ([\d.]+) p99 ([\d.]+) max ([\d.]+)", r.stdout)
    return tuple(float(x) for x in m.groups()) if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iters", type=int, default=3)
    ap.add_argument("--carriers", default="2,4,8")
    ap.add_argument("--modes", default="0,1")
    ap.add_argument("--no-go", action="store_true")
    a = ap.parse_args()
    carriers = [int(c) for c in a.carriers.split(",")]
    modes = [int(m) for m in a.modes.split(",")]
    with tempfile.TemporaryDirectory() as tmp:
        nomu = build_nomu()
        go = None if a.no_go else build_go(tmp)
        print(f"time to stop, µs (median of {a.iters} runs of each run's p50 / p99 / max)")
        print(f"{'':<10}{'carriers':>9}{'nomu p50':>10}{'p99':>8}{'max':>8}"
              + ("" if go is None else f"{'go p50':>10}{'p99':>8}{'max':>8}"))
        for mode in modes:
            for c in carriers:
                row = f"{'mode ' + str(mode):<10}{c:>9}"
                for run in ([lambda: run_nomu(nomu, mode, c, tmp)]
                            + ([] if go is None else [lambda: run_go(go, mode, c)])):
                    rs = [x for x in (run() for _ in range(a.iters)) if x is not None]
                    if not rs:
                        row += f"{'fail':>10}{'':>16}"
                        continue
                    med = [statistics.median(r[i] for r in rs) for i in range(3)]
                    row += f"{med[0]:>10.0f}{med[1]:>8.0f}{med[2]:>8.0f}"
                print(row)
                sys.stdout.flush()


if __name__ == "__main__":
    main()
