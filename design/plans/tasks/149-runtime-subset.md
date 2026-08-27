# Runtime-subset mechanism (the pragmas that let runtime code avoid its own services)

**Avenue:** Risk (self-hosting prerequisite) · **Type/Lifecycle:** `language-feature · in-progress`
(language + compiler checking) · **Size:** M · **Status:** slice 1 built — designation + call-graph
closure check · **Source:** distilled from [128 self-hosting](128-self-hosting-runtime.md), 2026-08-25

**► Built (slice 1).** Two designation sources — the **runtime prelude** (`src/stdlib/runtime.nomu`,
subset-by-default; the proper "designated file" until [100](100-modules.md)) and an ad-hoc
`--runtime-subset=<names>` flag — feeding the NOIR call-graph closure check in `Sema.swift`
(`checkRuntimeSubset`): a subset function may not allocate on the heap (class/actor construct, closure,
`any`-box, array, `spawn`) or call outside the allowlist (subset functions + the 125 `__raw*`/`__ptr*`
primitives + pure leaves). Test: `tools/subset.sh`. **Remaining slices:** codegen-site guards
(write-barrier / safepoint-poll suppression), the `nosplit fun` keyword (staged behind
[104](104-fiber-stack-strategy.md)), module-membership designation with [100](100-modules.md).

**► Design:** [`internals/runtime-subset.md`](../../internals/runtime-subset.md). Surface pinned with
Ethan: **surface A — module-default subset + a narrow per-function keyword refinement** (`nosplit fun`);
no attribute grammar; the marker appears only in privileged runtime code. Represented internally as a
per-function property set (`{noAlloc, noBarrier, noSafepoint, nosplit}`) seeded by module membership and
refinable, so a finer per-function surface (attributes/keywords) stays a front-end addition later.
Checking is a call-graph closure pass + codegen-site guards; the 125 primitives are the subset-legal
allowlist. Ready to build.

## What

The mechanism that lets code *inside* the runtime avoid recursively invoking the services it implements.
GC and scheduler code cannot trigger an implicit GC allocation, emit a write barrier, hit a
compiler-inserted safepoint, or grow its stack the normal way — those are the very things it is
implementing. Go solves this with runtime pragmas (`//go:nosplit`, `//go:nowritebarrier`,
`//go:noescape`); Nomu needs an analog: a way to mark a function or region as runtime-subset, plus
compiler checking that the marked code stays within the subset.

## Why it exists, and why now

A hard prerequisite for writing any of the runtime in Nomu ([128](128-self-hosting-runtime.md)). Without
it, the first line of the self-hosted collector would recursively call the collector. It is
frontend/compiler-contained and independent of backend maturity, so it sits on the build-now critical
path alongside [125 unsafe raw memory](125-unsafe-raw-memory.md).

## Design axes

- **Surface.** How the subset is spelled — an attribute/annotation on a function, a module-level mode, or
  a capability. Touches syntax; needs sign-off before it lands.
- **Which constraints.** The initial set: no implicit heap allocation, no write barrier, no
  compiler-inserted safepoint, bounded/controlled stack growth. Each maps to a check.
- **Checking.** Where the checks live (Sema vs. an IR pass) and how violations are reported. A
  conservative static analysis over the call graph of subset code.
- **Escape hatches.** How subset code reaches the raw primitives ([125](125-unsafe-raw-memory.md)) it
  *is* allowed to use.

## Refs

[128 self-hosting](128-self-hosting-runtime.md); [125 unsafe raw memory](125-unsafe-raw-memory.md);
`runtime.md` (safepoints, mutator); Go runtime pragmas (prior art).
