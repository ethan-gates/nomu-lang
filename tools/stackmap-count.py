#!/usr/bin/env python3
# Count LLVM stack-map records in a Mach-O binary or object (its __llvm_stackmaps section holds one v3
# blob per object linked in). Usage: stackmap-count.py <binary>
import struct, subprocess, sys
path = sys.argv[1]
out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout.split("\n")
off = size = None
for i, l in enumerate(out):
    if l.strip() == "sectname __llvm_stackmaps":
        for j in range(i, i + 10):
            p = out[j].split()
            if p and p[0] == "size": size = int(p[1], 16)
            if p and p[0] == "offset": off = int(p[1])
        break
data = open(path, "rb").read()[off:off + size]
pos, blobs, funcs, records = 0, 0, 0, 0
while pos + 16 <= len(data):
    ver = data[pos]
    if ver != 3:  # inter-blob padding
        pos += 8; continue
    nf, nc, nr = struct.unpack_from("<III", data, pos + 4)
    pos += 16
    fsum = sum(struct.unpack_from("<QQQ", data, pos + 24 * k)[2] for k in range(nf))
    assert fsum == nr, (fsum, nr)
    pos += 24 * nf + 8 * nc
    for _ in range(nr):
        nloc = struct.unpack_from("<H", data, pos + 14)[0]
        pos += 16 + 12 * nloc
        pos = (pos + 7) & ~7
        nlo = struct.unpack_from("<H", data, pos + 2)[0]
        pos += 4 + 4 * nlo
        pos = (pos + 7) & ~7
    print(f"object {blobs}: functions={nf} records={nr}")
    blobs += 1; funcs += nf; records += nr
print(f"total: objects={blobs} functions={funcs} records={records} section_bytes={size}")
