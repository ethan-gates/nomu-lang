#!/usr/bin/env python3
"""Fiber-switch baseline against Go (task 104.1).

Builds the switch benchmarks and their Go counterpart, runs each at several carrier counts (NOMU_CARRIERS,
and GOMAXPROCS for Go), and prints the best ns per hop of `--iters` runs.

  ctx_swap        the register swap alone (ns per switch; a hop is two)
  pingpong_fiber  two fibers through the scheduler's park and unpark
  pingpong_actor  two actors sending a counter back and forth
  go chan         two goroutines over unbuffered channels
  go mailbox      two goroutines, each with a buffered channel as its mailbox
  go gosched      two goroutines yielding in turn

The Go program is kept outside the repository, in the gitignored `practice/go/pingpong`; the Go rows run
only when it is there.

Usage:
  tools/pingpong.py [--iters N] [--carriers 1,2,4]

Needs the built `nomu` (`bazel build -c opt //src/nomu-cli:nomu`), and `go` on PATH for the Go rows.
"""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOMU = os.path.join(ROOT, "bazel-bin", "src", "nomu-cli", "nomu")
GO_SRC = os.path.join(ROOT, "practice", "go", "pingpong")
GO_BIN = os.path.join(ROOT, "practice", "build-go", "pingpong")

# name -> its build flags
NOMU_BENCHES = [
    ("ctx_swap", ["--config=runtime_tier", "--runtime-subset=swapPeer,swapRounds"]),
    ("pingpong_fiber", ["--config=rt_prelude"]),
    ("pingpong_actor", []),
]
GO_MODES = ["chan", "mailbox", "gosched"]
GO_HOPS = 2000000


def build_nomu(name, flags):
    src = os.path.join(ROOT, "benchmarks", name)
    r = subprocess.run([NOMU, "build", "--no-history"] + flags + [src], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"pingpong: {name} failed to build:\n{r.stderr}")
    return os.path.join(ROOT, "build", "benchmarks", name, name)


def build_go():
    r = subprocess.run(["go", "build", "-o", GO_BIN, "."], cwd=GO_SRC, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"pingpong: the Go benchmark failed to build:\n{r.stderr}")


def per_hop(cmd, env, iters):
    """Best ns per hop over `iters` runs. Every program prints `... <count> ... ns <total>`; the actor one
    prints its total only, for its fixed 1,000,000 hops."""
    best = None
    for _ in range(iters):
        out = subprocess.run(cmd, env=env, capture_output=True, text=True).stdout
        m = re.search(r"(?:hops|rounds) (\d+) ns (\d+)", out)
        if m:
            count, ns = int(m.group(1)), int(m.group(2))
        else:
            m = re.search(r"ns (\d+)", out)
            if not m:
                return None
            count, ns = 1000000, int(m.group(1))
        v = ns / count
        best = v if best is None else min(best, v)
    return best


def main():
    args = sys.argv[1:]
    iters, carriers = 3, [1, 2, 4]
    i = 0
    while i < len(args):
        if args[i] == "--iters":
            iters = int(args[i + 1]); i += 2; continue
        if args[i] == "--carriers":
            carriers = [int(c) for c in args[i + 1].split(",")]; i += 2; continue
        if args[i] in ("-h", "--help"):
            print(__doc__); return
        sys.exit(f"pingpong: unknown argument {args[i]}")
    if not os.path.exists(NOMU):
        sys.exit(f"pingpong: {NOMU} not found — run `bazel build -c opt //src/nomu-cli:nomu` first")

    rows = []
    for name, flags in NOMU_BENCHES:
        binary = build_nomu(name, flags)
        rows.append((name, [per_hop([binary], dict(os.environ, NOMU_CARRIERS=str(c)), iters) for c in carriers]))
    if os.path.isdir(GO_SRC):
        build_go()
        for mode in GO_MODES:
            rows.append((f"go {mode}", [per_hop([GO_BIN, mode, str(GO_HOPS)], dict(os.environ, GOMAXPROCS=str(c)), iters)
                                        for c in carriers]))

    print(f"ns per hop (ctx_swap: per round trip), best of {iters}; columns are carriers / GOMAXPROCS\n")
    header = f"{'benchmark':<16}" + "".join(f"{c:>10}" for c in carriers)
    print(header)
    print("-" * len(header))
    for name, vals in rows:
        print(f"{name:<16}" + "".join(f"{v:>10.1f}" if v is not None else f"{'—':>10}" for v in vals))


if __name__ == "__main__":
    main()
