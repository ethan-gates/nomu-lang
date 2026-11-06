#!/usr/bin/env python3
"""The deepest stack use below checked functions, from a build's frame tables (task 104).

Reads the `<stem>.frames` tables code generation writes beside each object (`src/llvmgen/FrameTable.swift`)
and reports what the link's check (`FrameTable.check`) measures: from every unchecked function a checked one
calls, the deepest chain of unchecked frames, a checked callee counted with its frame and the stack check's
slow path, and an indirect call counted as a call to any function whose address is taken. The link fails a
chain over the reserve; this lists the deepest ones, the slow path's depth and the largest checked frame.

    nomu build <pkg> -c release
    python3 tools/frame-depth.py build/<pkg>/<pkg>.frames build/_external/nomu.nomu/**/*.frames [--top 10]
"""
import argparse
import sys
from collections import defaultdict

NO_STACK = {"rtSwitch", "rtFiberInit", "memcpy", "memmove", "memset", "bzero", "memcmp"}
SLOW = "__nomu_stack_slow"


def load(paths):
    size, checked, calls, indirect, taken, entries = {}, set(), defaultdict(set), set(), set(), set()
    for path in paths:
        with open(path) as f:
            lines = f.read().split("\n")
        if lines[0] != "nomu-frames 1":
            sys.exit(f"{path}: not a frame table")
        for line in lines[1:]:
            p = line.split(" ", 3)
            if p[0] == "f":
                size[p[3]] = max(size.get(p[3], 0), int(p[1]))
                if p[2] == "1":
                    checked.add(p[3])
            elif p[0] == "c":
                calls[p[1]].add(p[2])
            elif p[0] == "i":
                indirect.add(p[1])
            elif p[0] == "a":
                taken.add(p[1])
            elif p[0] == "e":
                entries.add(p[1])
    return size, checked, calls, indirect, taken - entries


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tables", nargs="+")
    ap.add_argument("--reserve", type=int, default=16384)
    ap.add_argument("--top", type=int, default=10)
    args = ap.parse_args()
    size, checked, calls, indirect, taken = load(args.tables)
    targets = sorted(t for t in taken if t in size)
    memo, unknown, cycles, path = {}, set(), [], []

    def callees(f):
        out = sorted(calls.get(f, ()))
        return out + targets if f in indirect else out

    def depth(f):
        if f in memo:
            return memo[f]
        if f in path:
            cycles.append(path[path.index(f):] + [f])
            return (0, [f])
        path.append(f)
        best = (0, [])
        for c in callees(f):
            d = contribution(c)
            if d[0] > best[0]:
                best = d
        path.pop()
        memo[f] = (size[f] + best[0], [f] + best[1])
        return memo[f]

    def contribution(c):
        if c in checked:
            slow = depth(SLOW) if SLOW in size else (0, [])
            return (size[c] + slow[0], [c + " (checked)"] + slow[1])
        if c in size:
            return depth(c)
        if c not in NO_STACK and not c.startswith("nomu_libc_"):
            unknown.add(c)
        return (0, [c])

    entries = {c for f in checked for c in callees(f) if c not in checked}
    results = sorted((contribution(e) for e in entries), key=lambda r: -r[0])
    print(f"checked functions: {len(checked)}, unchecked entries from checked code: {len(entries)}, "
          f"indirect callers: {len(indirect)}, address-taken: {len(targets)}")
    print(f"largest checked frame: {max((size[f] for f in checked), default=0)} bytes")
    if SLOW in size:
        print(f"slow path: {depth(SLOW)[0]} bytes: " + " -> ".join(depth(SLOW)[1]))
    print(f"deepest unchecked chains (reserve {args.reserve} bytes):")
    for total, chain in results[: args.top]:
        print(f"  {total:6d}  " + " -> ".join(chain))
    if unknown:
        print("callees with no known stack use: " + ", ".join(sorted(unknown)))
    if cycles:
        print("cycles among unchecked functions (no bound):")
        seen = set()
        for c in cycles:
            key = tuple(sorted(c))
            if key not in seen:
                seen.add(key)
                print("  " + " -> ".join(c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
