# Compressed references

**Avenue:** Risk (footprint) · **Type/Lifecycle:** `perf · gc · codegen · parked` · **Size:** XL · **Status:**
parked until after [127](127-lxr-collector.md) (LXR) and the work ahead of it on the horizon · **Source:**
[262](262-collector-gaps.md).5.6.1

## Why

A managed reference is 8 bytes and every object carries an 8-byte header, so an object of two references is
24 bytes where Go's is 16. That is binary-trees' whole memory gap with Go: its live set at depth 21 is 144 MiB
against about 96 MiB (262.5.6.1).

The header cannot go: Immix packs objects of different types into the same lines, and LXR inherits that, so
the collector needs each object's type at the object (Go's headerless objects rest on spans segregated by size
class). A 4-byte header saves nothing for an object whose first field is a reference, since references are
8-byte aligned. Storing references as 32-bit offsets from the heap base, scaled by the 8-byte alignment (the
JVM's compressed references), makes the two-reference object 16 bytes and bounds the heap at 32 GiB.

## To explore

- Encoding and decoding at every managed load and store, and what it costs the optimizer and the statepoint
  rewrite (a compressed reference is an integer, not an `addrspace(1)` pointer).
- Relocation, the write barrier and the stack copier on compressed slots.
- The heap bound, and a fallback for programs that need more.
- What LXR's reference counting, kept in side metadata, needs from it.
