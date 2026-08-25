# SIMD (stdlib module + backend support)

**Avenue:** Usability (perf floor) · **Type/Lifecycle:** `language-feature · needs-design` (stdlib +
backend + type-system) · **Size:** L · **Status:** needs-design · **Source:** deferred.md (2026-08-18)

## What

Explicit SIMD in two layers: a **stdlib SIMD module** (fixed-width vector types + elementwise ops,
comparisons, reductions, movemask, like Swift's `SIMD`) and **backend support** lowering them to LLVM
`<N x T>` vectors + target intrinsics (SSE/AVX, NEON) with a scalar fallback. LLVM supplies the
plumbing; the surface, type-system integration, and cross-target abstraction are the work.

## Motivating example — swiss tables

The durable point: **SIMD is used in hash maps.** A Google-swiss-table / hashbrown-style flat map
scans 16 control bytes per probe with a SIMD byte-compare + movemask — why a fast future `Table`
wants SIMD capability. But: whether the real map consumes the *Nomu* SIMD API is conditional. If the
map lands in the C `core` floor it uses C intrinsics directly; if the C floor is removed (the
[self-hosting](128-self-hosting-runtime.md) goal) the map becomes Nomu and consumes the Nomu SIMD module.
So the swiss-table motivates SIMD *capability*; its dependence on the *stdlib SIMD API* rides the
C-core-floor decision.

## The architectural fork — const generics or a fixed family

`SIMD16<UInt8>` wants an integer (const) type parameter, which Nomu's generics (type-params only)
lack:
- **Const / value generics** (`SIMD<let N: Int, T>`) — a real type-system feature that also unlocks
  fixed-size arrays. Larger ripple.
- **Fixed generated family** (`SIMD2`…`SIMD64` + a `SIMDScalar` interface) — Swift's choice; no const
  generics, more generated code. Contained.

This decision is the architecture-relevant part; the rest is stdlib + backend.

## Dependencies

The [generic hash map](124-generic-hashmap.md) (blocked on D6 spill) and
[raw-memory / byte buffers](125-unsafe-raw-memory.md) (control-byte array) both gate the swiss-table
outcome. Also: aligned vector storage, the vector-register ABI (`c-types.md`), cross-arch portability.

## Roadmap assessment

**One-liner pointer.** Perf-envelope driven (fast default collections + vectorized stdlib) + the
const-generics fork (type-system ripple if taken). Under the fixed-family path, only the
*const-generics decision* + the *SIMD-backed default `Table` commitment* need a roadmap anchor.

## Refs

deferred.md "SIMD"; `c-types.md`; [generic hash map](124-generic-hashmap.md),
[self-hosting](128-self-hosting-runtime.md).
