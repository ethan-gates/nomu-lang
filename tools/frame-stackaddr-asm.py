#!/usr/bin/env python3
"""Find stack addresses kept across statepoint calls in arm64 Mach-O Nomu binaries.

Heuristic, linear scan of otool disassembly. A register holds a stack address when it is defined from
sp or x29 (add/sub/mov), or from another such register by add/sub of an immediate. At each statepoint
call (a return address in the binary's GC frame index), a callee-saved register x19-x28 that holds a
stack address and is read after the call before being redefined counts as "stack address in a
callee-saved register across a stopping point". A store of a stack-address register to memory counts
as "stack address stored to memory" (a spill or a field), wherever it happens.
"""
import re, struct, subprocess, sys, collections, json

STORES = []
CSR = {f"x{i}" for i in range(19, 29)}

def sections(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    secs = {}
    cur = {}
    for line in out.splitlines():
        line = line.strip()
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "sectname":
            cur = {"sect": parts[1]}
        elif parts[0] == "segname" and "sect" in cur:
            cur["seg"] = parts[1]
        elif parts[0] == "addr" and "sect" in cur:
            cur["addr"] = int(parts[1], 16)
        elif parts[0] == "size" and "sect" in cur:
            cur["size"] = int(parts[1], 16)
        elif parts[0] == "offset" and "sect" in cur:
            cur["offset"] = int(parts[1])
            secs[(cur.get("seg"), cur["sect"])] = dict(cur)
    return secs

def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def i64(b, o): return struct.unpack_from("<q", b, o)[0]

def statepoint_pcs(path):
    secs = sections(path)
    sm = secs.get(("__LLVM_STACKMAPS", "__llvm_stackmaps"))
    fi = secs.get(("__DATA_CONST", "__nomu_frameidx"))
    if not sm or not fi:
        return set()
    data = open(path, "rb").read()
    smb = data[sm["offset"]:sm["offset"] + sm["size"]]
    fib = data[fi["offset"]:fi["offset"] + fi["size"]]
    pad = (8 - fi["addr"] % 8) % 8
    fib = fib[pad:]
    if u32(fib, 0) != 1481197134:
        return set()
    count = struct.unpack_from("<Q", fib, 8)[0]
    pcs = set()
    for k in range(count):
        e = 16 + k * 24
        fdelta = i64(fib, e)
        rec = u32(fib, e + 8)
        nrec = u32(fib, e + 12)
        for _ in range(nrec):
            pcs.add(sm["addr"] + fdelta + u32(smb, rec + 8))
            nloc = u16(smb, rec + 14)
            loc_end = (16 + nloc * 12 + 7) // 8 * 8
            nlive = u16(smb, rec + loc_end)
            rec += (loc_end + 2 + nlive * 4 + 7) // 8 * 8
    return pcs

INS = re.compile(r"^([0-9a-f]+)\s+(\S+)\s*(.*)$")
REG = re.compile(r"\b([xw](?:[0-9]|[12][0-9]|30)|sp)\b")

def norm(r):
    return "x" + r[1:] if r.startswith("w") else r

def parse(path):
    out = subprocess.run(["otool", "-tvV", path], capture_output=True, text=True).stdout
    funcs = []
    cur = None
    for line in out.splitlines():
        if line and not line[0].isspace() and line.endswith(":") and not line.startswith("/") and "(__TEXT" not in line:
            cur = {"name": line[:-1], "ins": []}
            funcs.append(cur)
            continue
        m = INS.match(line.strip())
        if m and cur is not None:
            addr, op, rest = m.groups()
            cur["ins"].append((int(addr, 16), op, rest.split(";")[0].strip()))
    return funcs

def operands(rest):
    return [o.strip() for o in re.split(r",(?![^\[]*\])", rest) if o.strip()]

NO_DEF = {"str", "stp", "strb", "strh", "stur", "cmp", "cmn", "tst", "b", "bl", "blr", "br", "ret",
          "cbz", "cbnz", "tbz", "tbnz", "stlr", "stxr", "stlxr", "nop", "brk", "dmb", "isb", "dsb", "msr",
          "ccmp", "ccmn", "fcmp", "prfm", "hint", "autibsp", "pacibsp", "svc", "st1", "casal", "swpal",
          "ldaddal"}

def defs_uses(op, rest):
    ops = operands(rest)
    regs = [[norm(r) for r in REG.findall(o)] for o in ops]
    base = op.split(".")[0]
    if base.startswith("b.") or base in NO_DEF or op.startswith("b."):
        d = []
        if base in ("stxr", "stlxr"):
            d = regs[0][:1]
        return d, [r for rs in regs for r in rs]
    if base in ("ldp", "ldnp", "ldpsw"):
        d = regs[0] + regs[1] if len(regs) > 1 else regs[0]
        u = [r for rs in regs[2:] for r in rs]
        return d, u
    d = regs[0][:1] if regs else []
    u = [r for rs in regs[1:] for r in rs]
    # pre/post-indexed writeback also defines the base, ignore (it is sp or a pointer).
    return d, u

def is_stack_def(op, rest, held):
    ops = operands(rest)
    if len(ops) < 2:
        return False
    src = [norm(r) for r in REG.findall(ops[1])]
    if op in ("add", "sub") and len(ops) >= 3 and ops[2].startswith("#") and src:
        return src[0] in ("sp", "x29") or src[0] in held
    if op == "mov" and src:
        return src[0] in ("sp", "x29") or src[0] in held
    return False

def analyze(path, pcs, seen):
    res = collections.Counter()
    examples = []
    for f in parse(path):
        name = f["name"]
        runtime = name.startswith("_nomu_fn_") or name.startswith("___nomu") or name in ("_main",)
        key = ("rt" if runtime else "user")
        if name in seen:
            continue
        seen.add(name)
        ins = f["ins"]
        held = set()
        for i, (addr, op, rest) in enumerate(ins):
            d, u = defs_uses(op, rest)
            base = op.split(".")[0]
            # stores of a stack address to memory
            if base in ("str", "stp", "stur") and held:
                ops = operands(rest)
                vals = [norm(r) for o in ops[:-1] for r in REG.findall(o)]
                for v in vals:
                    if v in held:
                        res[(key, "stack addr stored to memory")] += 1
                        STORES.append((key, name, hex(addr), op, rest))
            if base in ("bl", "blr"):
                ret_addr = addr + 4
                if ret_addr in pcs:
                    res[(key, "statepoint calls")] += 1
                    live = set()
                    for r in held & CSR:
                        # read after the call before redefinition?
                        for (a2, op2, rest2) in ins[i + 1:]:
                            d2, u2 = defs_uses(op2, rest2)
                            if r in u2:
                                live.add(r)
                                break
                            if r in d2 or op2 == "ret":
                                break
                    if live:
                        res[(key, "statepoints with a stack addr live in a CSR")] += 1
                        res[(key, "stack addrs live in CSRs at statepoints")] += len(live)
                        if len(examples) < 6:
                            examples.append((name, hex(addr), sorted(live)))
                held -= {f"x{k}" for k in range(0, 19)}
                continue
            if base == "ret":
                held = set()
                continue
            if d:
                if is_stack_def(base, rest, held):
                    held.add(d[0])
                else:
                    for r in d:
                        held.discard(r)
    return res, examples

def main():
    total = collections.Counter()
    seen = set()
    exs = []
    nbin = 0
    for path in sys.argv[1:]:
        pcs = statepoint_pcs(path)
        if not pcs:
            continue
        nbin += 1
        r, e = analyze(path, pcs, seen)
        total.update(r)
        exs.extend(e)
    print("binaries:", nbin, "distinct functions:", len(seen))
    for k in sorted(total):
        print(f"{k[0]:5} {k[1]:48} {total[k]}")
    for e in exs[:12]:
        print("example:", e)
    import collections as C
    kinds = C.Counter()
    for k, n, a, op, rest in STORES:
        tgt = rest.split(",")[-1].strip() if "[" in rest else rest
        kinds[(k, op, "sp-relative" if "[sp" in rest or "[x29" in rest else "other base")] += 1
    for k, v in kinds.most_common(): print("store", k, v)
    for t in [x for x in STORES if x[0]=="user"][:15]: print("  ", t)

if __name__ == "__main__":
    main()
