#!/usr/bin/env python3
"""Scheduler workloads swept over the scheduler's settings (task 234.3).

Builds the scheduler workloads, runs each under every chosen configuration (a named set of NOMU_*
settings) at several carrier counts, and prints a table per workload: one row per metric and
configuration, one column per carrier count, each the median of `--iters` runs. Every workload also
reports `cpu ms`, the process's user plus system time, which shows what spinning and the monitor cost.

  pingpong_fiber   two fibers handing a turn back and forth (ns per hop)
  pingpong_actor   two actors sending a counter back and forth (ns per hop)
  fanout_actor     one actor sending jobs to 16 actors, by job size (ns per job)
  forkjoin_fiber   a binary tree of 8,190 spawned and joined fibers, by leaf work (ns per fiber)
  pipeline_actor   items through a chain of 8 busy stage actors, by stage work (ns per item)
  producer_fiber   a producer that keeps running after readying a consumer (the consumer's wait, ns)
  sleepers_fiber   1,024 fibers sleeping 1 ms twenty times (ms; the floor is 20)
  mixed_fiber      compute fibers beside a handing-off pair (ms until each side finishes)
  idle_fiber       mostly asleep, with small bursts (ms; read cpu ms)

Usage:
  tools/schedbench.py [--iters N] [--carriers 1,2,4,8] [--configs a,b,...] [--workloads a,b,...]
                      [--json out.json]
  tools/schedbench.py --list        the configurations and their settings

Needs the built `nomu` (`bazel build -c opt //src/nomu-cli:nomu`).
"""

import json
import os
import re
import resource
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")

# name -> its NOMU_* settings; anything unset keeps the runtime's default.
CONFIGS = {
    "default": {},
    "no-slot": {"NOMU_SLOT": "0"},
    "steal-1us": {"NOMU_SLOT_STEAL_NS": "1000"},
    "steal-10us": {"NOMU_SLOT_STEAL_NS": "10000"},
    "search-5us": {"NOMU_SEARCH_NS": "5000"},
    "search-50us": {"NOMU_SEARCH_NS": "50000"},
}
DEFAULT_CONFIGS = ["default", "no-slot"]


def fields(out, name):
    """Each output line starting with `name`, as a dict of its `key value` pairs."""
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if not parts or parts[0] != name:
            continue
        rows.append({parts[i]: int(parts[i + 1]) for i in range(1, len(parts) - 1, 2)
                     if re.fullmatch(r"-?\d+", parts[i + 1])})
    return rows


def per_round(name, count_key, unit):
    def metrics(out):
        return {f"work {r['work']:>5} {unit}": r["ns"] / r[count_key] for r in fields(out, name)}
    return metrics


def pingpong_fiber(out):
    r = fields(out, "pingpong_fiber")[0]
    return {"ns/hop": r["hops"] and r["ns"] / r["hops"]}


def pingpong_actor(out):
    r = fields(out, "pingpong_actor")[0]
    return {"ns/hop": r["ns"] / 1000000}


def producer(out):
    r = fields(out, "producer_fiber")[0]
    return {"wait p50 ns": r["p50"], "wait p99 ns": r["p99"], "wait max ns": r["max"],
            "misses": r["misses"], "total ms": r["ns"] / 1e6}


def total_ms(name):
    def metrics(out):
        return {"total ms": fields(out, name)[0]["ns"] / 1e6}
    return metrics


def mixed(out):
    r = fields(out, "mixed_fiber")[0]
    return {"pair ms": r["pair_ns"] / 1e6, "compute ms": r["bg_ns"] / 1e6}


# name -> (build flags, metrics from its output)
WORKLOADS = {
    "pingpong_fiber": (["--config=rt_prelude"], pingpong_fiber),
    "pingpong_actor": ([], pingpong_actor),
    "fanout_actor": ([], per_round("fanout_actor", "msgs", "ns/job")),
    "forkjoin_fiber": ([], per_round("forkjoin_fiber", "fibers", "ns/fiber")),
    "pipeline_actor": ([], per_round("pipeline_actor", "items", "ns/item")),
    "producer_fiber": (["--config=rt_prelude"], producer),
    "sleepers_fiber": ([], total_ms("sleepers_fiber")),
    "mixed_fiber": (["--config=rt_prelude"], mixed),
    "idle_fiber": ([], total_ms("idle_fiber")),
}


def build(name, flags):
    src = os.path.join(ROOT, "benchmarks", name)
    r = subprocess.run([NOMU, "build", "--no-history"] + flags + [src], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"schedbench: {name} failed to build:\n{r.stderr}")
    return os.path.join(ROOT, "build", "benchmarks", name, name)


def run_once(binary, env, metrics):
    """One run: the workload's metrics plus its CPU time, or None when it failed."""
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    try:
        r = subprocess.run([binary], env=env, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return None
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    if r.returncode != 0:
        return None
    try:
        m = metrics(r.stdout)
    except (IndexError, KeyError, ZeroDivisionError):
        return None
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    m["cpu ms"] = cpu * 1000
    return m


def main():
    args = sys.argv[1:]
    iters, carriers = 3, [1, 2, 4, 8]
    configs, workloads, json_out = DEFAULT_CONFIGS, list(WORKLOADS), None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--list":
            for name, cfg in CONFIGS.items():
                print(f"{name:<30} {' '.join(f'{k}={v}' for k, v in cfg.items()) or '(defaults)'}")
            return
        if a in ("-h", "--help"):
            print(__doc__)
            return
        if i + 1 >= len(args):
            sys.exit(f"schedbench: {a} needs a value")
        v = args[i + 1]
        if a == "--iters":
            iters = int(v)
        elif a == "--carriers":
            carriers = [int(c) for c in v.split(",")]
        elif a == "--configs":
            configs = v.split(",")
        elif a == "--workloads":
            workloads = v.split(",")
        elif a == "--json":
            json_out = v
        else:
            sys.exit(f"schedbench: unknown argument {a}")
        i += 2
    for c in configs:
        if c not in CONFIGS:
            sys.exit(f"schedbench: unknown configuration {c} (see --list)")
    for w in workloads:
        if w not in WORKLOADS:
            sys.exit(f"schedbench: unknown workload {w}")
    if not os.path.exists(NOMU):
        sys.exit(f"schedbench: {NOMU} not found — run `bazel build -c opt //src/nomu-cli:nomu` first")

    results = {}
    for w in workloads:
        flags, metrics = WORKLOADS[w]
        binary = build(w, flags)
        # table[(metric, config)][carriers] = median
        table = {}
        for cfg in configs:
            for c in carriers:
                env = dict(os.environ, NOMU_CARRIERS=str(c), **CONFIGS[cfg])
                runs = [m for m in (run_once(binary, env, metrics) for _ in range(iters)) if m is not None]
                if not runs:
                    continue
                for key in runs[0]:
                    vals = [m[key] for m in runs if key in m]
                    table.setdefault((key, cfg), {})[c] = statistics.median(vals)
        results[w] = {f"{k} | {cfg}": v for (k, cfg), v in table.items()}
        print(f"\n== {w}  (median of {iters}; columns are carriers)")
        width = max(len(cfg) for cfg in configs)
        header = f"{'':<22}{'':<{width}}" + "".join(f"{c:>10}" for c in carriers)
        print(header)
        for key in sorted({k for k, _ in table}, key=lambda k: (k == "cpu ms", k)):
            for cfg in configs:
                row = table.get((key, cfg))
                if row is None:
                    continue
                cells = "".join(f"{row[c]:>10.1f}" if c in row else f"{'fail':>10}" for c in carriers)
                print(f"{key:<22}{cfg:<{width}}{cells}")
        sys.stdout.flush()
    if json_out:
        with open(json_out, "w") as f:
            json.dump({"carriers": carriers, "configs": {c: CONFIGS[c] for c in configs}, "results": results},
                      f, indent=1)


if __name__ == "__main__":
    main()
