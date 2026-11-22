#!/usr/bin/env python3
"""The loop-poll kernel set (task 245; 236's goal G3): `benchmarks/loop_kernels` under each configuration.

Builds the kernels in release under every chosen configuration, runs each `--iters` times on one carrier with a
nursery large enough that nothing collects, checks that every build prints the same checksum, and prints each
kernel's median time and its change against the first configuration.

  today     loop-header polls as built
  no-polls  no loop polls (`measure_no_loop_polls`): unsound, the bound strip mining aims at
  no-stops  no loop polls and no entry stack checks (`measure_no_stack_checks` too): 236's G3 bound

Usage:
  tools/loopbench.py [--iters N] [--configs today,no-polls,no-stops]

Needs the built `nomu` (`bazel build -c opt //src/nomu-cli:nomu`).
"""

import argparse
import os
import re
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")
ENV = dict(os.environ, NOMU_NURSERY_RESERVE="7000", NOMU_CARRIERS="1")

# name -> extra build configs
CONFIGS = {
    "today": [],
    "no-polls": ["measure_no_loop_polls"],
    "no-stops": ["measure_no_loop_polls", "measure_no_stack_checks"],
}


def build(configs):
    args = [NOMU, "build", "--no-history", "-c", "release"]
    for c in configs:
        args += ["-c", c]
    r = subprocess.run(args + [os.path.join(ROOT, "benchmarks", "loop_kernels")], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"loopbench: {configs} failed to build:\n{r.stderr}")
    return os.path.join(ROOT, "build", "benchmarks", "loop_kernels", "loop_kernels")


def run(binary):
    r = subprocess.run([binary], capture_output=True, text=True, env=ENV)
    if r.returncode != 0:
        sys.exit(f"loopbench: {binary} exited {r.returncode}:\n{r.stderr}")
    times = {m.group(1): int(m.group(2)) for m in re.finditer(r"kernel (\w+) ns (\d+)", r.stdout)}
    check = re.search(r"checksum (-?\d+)", r.stdout).group(1)
    return times, check


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iters", type=int, default=7)
    ap.add_argument("--configs", default="today,no-polls")
    a = ap.parse_args()
    names = a.configs.split(",")
    for n in names:
        if n not in CONFIGS:
            sys.exit(f"loopbench: unknown configuration {n} (known: {', '.join(CONFIGS)})")
    medians, checks = {}, {}
    for n in names:
        binary = build(CONFIGS[n])
        runs = [run(binary) for _ in range(a.iters)]
        checks[n] = {c for _, c in runs}
        kernels = runs[0][0].keys()
        medians[n] = {k: statistics.median(t[k] for t, _ in runs) for k in kernels}
    base = names[0]
    print(f"{'kernel':12}{base + ' ms':>14}" + "".join(f"{n:>14}" for n in names[1:]))
    for k in medians[base]:
        row = f"{k:12}{medians[base][k] / 1e6:>14.1f}"
        for n in names[1:]:
            row += f"{(medians[n][k] / medians[base][k] - 1) * 100:>+13.1f}%"
        print(row)
    for n in names:
        if checks[n] != checks[base]:
            print(f"! {n}: checksum {sorted(checks[n])} differs from {base}'s {sorted(checks[base])}")
    print(f"\nmedian of {a.iters}; columns after the first: change in median time")


if __name__ == "__main__":
    main()
