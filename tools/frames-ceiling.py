#!/usr/bin/env python3
"""Bound what a different frame mechanism could save (task 243.1).

Builds each workload under configurations that remove a cost of finding roots, unsoundly (the `measure_*`
configs in cfg.yaml), runs each with a nursery large enough that nothing collects, checks its output matches
the sound build's, and reports the median time and the change against today.

  python3 tools/frames-ceiling.py [--iters N] [--only name,name]

Needs the release compiler (`bazel build -c opt //src/nomu-cli:nomu`). Workloads that print their own
timing (`ns <n>` as the last field) are timed by that; the rest by wall clock.
"""
import argparse, os, statistics, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-out", "darwin_arm64-opt", "bin", "src", "nomu-cli", "nomu")
ENV = dict(os.environ, NOMU_NURSERY_RESERVE="7000", NOMU_CARRIERS="1")

# name -> extra build configs
WORKLOADS = [
    ("frames_tree", []),
    ("frames_strings", []),
    ("frames_loops", []),
    ("frames_fib", []),
    ("micro_carried", []),
    ("pingpong_fiber", ["rt_prelude"]),
    ("pingpong_actor", []),
]

# name -> configs, each standing in for a design (see design/internals/frames-designs.md)
CONFIGS = [
    ("today", []),
    ("regs", ["measure_gc_regs"]),
    ("no-polls", ["measure_no_loop_polls"]),
    ("no-homes", ["measure_no_shaped_homes"]),
    ("no-statepoints", ["measure_no_statepoints"]),
    ("no-sp+homes", ["measure_no_statepoints", "measure_no_shaped_homes"]),
    ("ceiling", ["measure_no_statepoints", "measure_no_shaped_homes", "measure_no_loop_polls"]),
]


def build(name, configs):
    args = [NOMU, "build", "--no-history", "-c", "release"]
    for c in configs:
        args += ["-c", c]
    r = subprocess.run(args + [os.path.join(ROOT, "benchmarks", name)], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"frames-ceiling: {name} {configs} failed to build:\n{r.stderr}")
    return os.path.join(ROOT, "build", "benchmarks", name, name)


def run(binary):
    t0 = time.perf_counter()
    r = subprocess.run([binary], capture_output=True, text=True, env=ENV)
    wall = time.perf_counter() - t0
    if r.returncode != 0:
        sys.exit(f"frames-ceiling: {binary} exited {r.returncode}:\n{r.stderr}")
    out = r.stdout.strip()
    fields = out.split()
    if len(fields) >= 2 and fields[-2] == "ns":
        return out.rsplit(" ns ", 1)[0] if " ns " in out else "", int(fields[-1]) / 1e9
    return out, wall


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iters", type=int, default=7)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    only = set(a.only.split(",")) - {""}
    names = [c[0] for c in CONFIGS]
    print(f"{'workload':16}" + "".join(f"{n:>16}" for n in names))
    for name, extra in WORKLOADS:
        if only and name not in only:
            continue
        base_out, base_t = None, None
        row = []
        for cname, configs in CONFIGS:
            binary = build(name, extra + configs)
            outs, times = set(), []
            for _ in range(a.iters):
                o, t = run(binary)
                outs.add(o)
                times.append(t)
            med = statistics.median(times)
            out = outs.pop() if len(outs) == 1 else None
            if cname == "today":
                base_out, base_t = out, med
                row.append(f"{med * 1000:13.1f}ms")
            else:
                same = "" if out == base_out else " !"
                row.append(f"{(med / base_t - 1) * 100:+12.1f}%{same:2}")
        print(f"{name:16}" + "".join(f"{c:>16}" for c in row), flush=True)
    print("\ncolumns after `today`: change in median time; `!` marks output differing from today's")


if __name__ == "__main__":
    main()
