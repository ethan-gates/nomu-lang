#!/usr/bin/env python3
"""Classify non-GC pointers (addrspace 0) live across each gc.statepoint in post-RS4GC LLVM IR.

For each function, each statepoint call, and each SSA value of type `ptr` (addrspace 0) defined before
the statepoint and used after it, classify the value's origin by following GEPs/bitcasts/phis back:
  alloca    an address in this frame
  param     a pointer parameter (may point into a caller's frame: by-ref self, sret, erased buffers)
  load      loaded from memory (may be a stack address someone stored)
  call      returned by a call
  global    a global or constant
  other     anything else (inttoptr, select of mixed, ...)
"Live across" comes from backward liveness over the CFG (phi uses count at the predecessor's end).
Known imprecision: a phi of `ptr addrspace(1)` values can be counted as a non-GC pointer. Runtime
functions (`nomu_fn_*`) are reported separately.
"""
import re, sys, collections

FUNC = re.compile(r'^define .*? @("?[^"(]+"?)\((.*)\).*\{$')
LABEL = re.compile(r'^([\w.$-]+):')
DEF = re.compile(r'^\s*(%[\w.$-]+) = (.*)$')
VAL = re.compile(r'%[\w.$-]+')

def split_params(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{<": depth += 1
        if ch in ")]}>": depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip(): out.append(cur)
    return out

def parse_funcs(text):
    funcs = []
    cur = None
    for line in text.splitlines():
        m = FUNC.match(line)
        if m:
            cur = {"name": m.group(1).strip('"'), "params": {}, "blocks": [], "gc": "gc \"statepoint-example\"" in line}
            for p in split_params(m.group(2)):
                p = p.strip()
                names = VAL.findall(p)
                if names:
                    ty = p.split()[0]
                    cur["params"][names[-1]] = ty
            cur["blocks"].append(["entry", []])
            funcs.append(cur)
            continue
        if cur is None:
            continue
        if line.startswith("}"):
            cur = None
            continue
        lm = LABEL.match(line)
        if lm:
            cur["blocks"].append([lm.group(1), []])
            continue
        if line.strip() and not line.strip().startswith(";"):
            cur["blocks"][-1][1].append(line.split(", !dbg")[0])
    for f in funcs:
        if f["blocks"] and not f["blocks"][0][1] and len(f["blocks"]) > 1:
            f["blocks"].pop(0)
    return funcs

def analyze_func(f):
    defs = {}      # value -> (block index, inst index, text)
    types = {}
    for bi, (bname, insts) in enumerate(f["blocks"]):
        for ii, ins in enumerate(insts):
            m = DEF.match(ins)
            if m:
                defs[m.group(1)] = (bi, ii, m.group(2))
    names = [b[0] for b in f["blocks"]]
    index = {n: i for i, n in enumerate(names)}
    succ = collections.defaultdict(set)
    for bi, (bname, insts) in enumerate(f["blocks"]):
        if insts:
            for lab in re.findall(r'label %([\w.$-]+)', insts[-1]):
                if lab in index: succ[bi].add(index[lab])
    # uses per block (phi uses attributed to predecessor end)
    use_blocks = collections.defaultdict(list)   # value -> [(block, inst index)]
    for bi, (bname, insts) in enumerate(f["blocks"]):
        for ii, ins in enumerate(insts):
            body = DEF.match(ins).group(2) if DEF.match(ins) else ins
            if " phi " in " " + body:
                for v, lab in re.findall(r'\[\s*(%[\w.$-]+),\s*%([\w.$-]+)\s*\]', body):
                    if lab in index:
                        use_blocks[v].append((index[lab], 10**9))
                continue
            for v in VAL.findall(body):
                use_blocks[v].append((bi, ii))
    # reachability
    reach = {}
    def reachable(b):
        if b in reach: return reach[b]
        seen, stack = set(), list(succ[b])
        while stack:
            x = stack.pop()
            if x in seen: continue
            seen.add(x); stack.extend(succ[x])
        reach[b] = seen
        return seen

    def is_ptr0(v):
        if v in f["params"]:
            return f["params"][v] == "ptr"
        d = defs.get(v)
        if not d: return False
        body = d[2]
        if body.startswith("alloca"): return True
        if body.startswith("getelementptr"):
            return " ptr addrspace(1)" not in body.split(",")[1] if "," in body else True
        if body.startswith("phi ptr ") or body.startswith("select ") and " ptr %" in body and "addrspace(1)" not in body:
            return body.startswith("phi ptr ") or True
        if body.startswith("load ptr,"): return True
        if body.startswith("inttoptr") and body.rstrip().endswith("to ptr"): return True
        if re.match(r'(tail |musttail |notail )?call (fastcc |ccc )?ptr @', body): return True
        if body.startswith("addrspacecast") and body.rstrip().endswith("to ptr"): return True
        return False

    def origin(v, depth=0):
        if depth > 20: return "other"
        if v in f["params"]: return "param"
        d = defs.get(v)
        if not d: return "global"
        body = d[2]
        if body.startswith("alloca"): return "alloca"
        if body.startswith("getelementptr"):
            ops = VAL.findall(body.split(",", 1)[1]) if "," in body else []
            return origin(ops[0], depth + 1) if ops else "global"
        if body.startswith("phi"):
            os = {origin(x, depth + 1) for x in re.findall(r'\[\s*(%[\w.$-]+),', body)}
            return os.pop() if len(os) == 1 else "mixed"
        if body.startswith("load"): return "load"
        if "call" in body.split("(")[0]: return "call"
        return "other"

    # Per-instruction uses and defs; phi uses are attributed to the end of the predecessor.
    nb = len(f["blocks"])
    inst_uses = []
    phi_out = collections.defaultdict(set)   # pred block -> values used by phis in successors
    for bi, (bname, insts) in enumerate(f["blocks"]):
        row = []
        for ii, ins in enumerate(insts):
            m = DEF.match(ins)
            body = m.group(2) if m else ins
            d = m.group(1) if m else None
            if body.startswith("phi "):
                for v, lab in re.findall(r'\[\s*(%[\w.$-]+),\s*%([\w.$-]+)\s*\]', body):
                    if lab in index: phi_out[index[lab]].add(v)
                row.append((d, set()))
            else:
                row.append((d, set(VAL.findall(body))))
        inst_uses.append(row)
    live_in = [set() for _ in range(nb)]
    live_out = [set() for _ in range(nb)]
    changed = True
    while changed:
        changed = False
        for bi in reversed(range(nb)):
            out = set(phi_out[bi])
            for s2 in succ[bi]:
                out |= live_in[s2]
            cur = set(out)
            for d, us in reversed(inst_uses[bi]):
                if d: cur.discard(d)
                cur |= us
            if out != live_out[bi] or cur != live_in[bi]:
                live_out[bi], live_in[bi] = out, cur
                changed = True
    res = collections.Counter()
    for bi, (bname, insts) in enumerate(f["blocks"]):
        after = set(live_out[bi])
        for ii in reversed(range(len(insts))):
            d, us = inst_uses[bi][ii]
            if "@llvm.experimental.gc.statepoint" in insts[ii]:
                res["statepoints"] += 1
                live = {v for v in after if v != d and is_ptr0(v)}
                if live:
                    res["statepoints with a ptr0 live"] += 1
                for v in live:
                    o = origin(v)
                    res["live ptr0 from " + o] += 1
                    d0 = defs.get(v)
                    root = d0[2] if d0 else ("param " + f["params"].get(v, ""))
                    # follow gep chain to its root def for the sample
                    seen = 0
                    while d0 and d0[2].startswith("getelementptr") and seen < 10:
                        ops = VAL.findall(d0[2].split(",", 1)[1]); seen += 1
                        if not ops: break
                        nxt = defs.get(ops[0])
                        if not nxt:
                            root = "param/global " + ops[0]; d0 = None; break
                        d0 = nxt; root = nxt[2]
                    SAMPLES[o][re.sub(r'%[\w.$-]+', '%v', root)[:110]] += 1
            if d: after.discard(d)
            after |= us
    return res

SAMPLES = collections.defaultdict(collections.Counter)
def main():
    tot = {"user": collections.Counter(), "rt": collections.Counter()}
    for path in sys.argv[1:]:
        for f in parse_funcs(open(path).read()):
            if not f["gc"]: continue
            key = "rt" if f["name"].startswith("nomu_fn_") or f["name"].startswith("__nomu") else "user"
            tot[key].update(analyze_func(f))
    for key in ("user", "rt"):
        for k in sorted(tot[key]):
            print(f"{key:5} {k:40} {tot[key][k]}")
    for o in SAMPLES:
        print("==", o)
        for k, n in SAMPLES[o].most_common(8): print(f"   {n:5}  {k}")

if __name__ == "__main__":
    main()
