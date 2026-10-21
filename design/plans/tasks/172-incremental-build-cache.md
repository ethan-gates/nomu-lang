# Incremental build cache (content-addressed, module-granular)

**Avenue:** Infra · **Type/Lifecycle:** `perf · needs-design` (driver + build orchestration + artifact
store) · **Size:** L · **Status:** needs-design — **wants real design time before build.** · **Source:**
pulled out of [100](100-modules.md) §100.4.5 (driver incremental cache) + §100.4.6 (incremental / stability
tests). The separate-compilation machinery (per-module objects, sectioned `.nmi`, independent ABI/perf
hashes) is built; this task is the persistent cache that turns it into a build that skips unchanged work,
and the correctness harness that proves it safe.

## What

A persistent, content-addressed build cache at **module granularity**: a build recompiles only the modules
whose inputs changed, plus the modules whose dependencies changed in a way that is observable across the
boundary, and reuses cached artifacts (`.nmi`, `.o`, escape summaries) for everything else. The output of an
incremental build is bit-for-bit the output of a clean build.

**Two parts.** [190](190-explicit-module-builds.md) guarantees a normalized build graph for a single
`nomu build` of one root module: each module compiles once, and nothing persists across invocations except
the per-host cache. 172 extends that in two parts:
1. **Several root modules in one build.** `nomu build` takes several root modules and plans one graph over
   all of them, so a module they share compiles once and their jobs run together.
2. **Caching modules across builds.** Module outputs are kept in a store keyed by a hash of their inputs,
   and a build reuses every entry whose key matches (the rest of this doc).

Both parts reshape `build/`, so the layout questions 190 deferred land here (190.6 F3, F6).

The invalidation lever already exists: the `.nmi` is sectioned with an **ABI hash** and a **perf hash**
(164.4.2 — `ModuleInterface.abiHash`/`perfHash`), where `abiHash` is a function of the ABI section alone. A
module body or perf-fact edit that leaves the ABI section byte-identical must **not** rebuild its dependents.
An ABI edit (a signature, a layout, a conformance) must cascade to them. That split is the spine of the
cache.

## Why its own task (out of 100)

Module-level separate compilation (100.4) delivered the artifacts; caching them robustly is a distinct
system with its own correctness burden (determinism, atomic publish, concurrency, invalidation soundness,
eviction) that deserves dedicated design rather than a one-line driver bolt-on. It is also the foundation the
finer-grained work builds on, so it reads cleanly as its own layer.

**Boundary with [136](136-incremental-compilation.md) (Incremental compilation).** 172 is the **coarse,
persistent, module-granular build cache** — the near-term deliverable on top of separate compilation. 136 is
the **fine-grained, in-process, query-based** incremental story (recompute sub-module units, cached
monomorphizations, LSP responsiveness), which sits downstream of [142](142-ir-pipeline-hardening.md) and
reuses 172's keying + store. 172 ships first and stands alone; 136 is its successor at finer granularity, not
a competitor.

## Design surface — decisions to settle in the design session

**From [190](190-explicit-module-builds.md) 190.6: the `build/` layout.**
- *Overlapping invocations (F3).* Today's unit directories are written in place, so two `nomu build`
  invocations running at once in one workspace can tear reads, mix configurations and mix sources;
  accepted until the store lands. A store whose outputs are immutable once published, published
  atomically, at paths keyed by their inputs, makes overlapping invocations safe by construction: same
  inputs share a result, different inputs never touch each other's files. **Direction:** at most one `nomu`
  invocation at a time per workspace, with several root modules allowed in one build (part 1), so shared
  work such as the runtime archive is planned once instead of raced (190.6 F22). How `build/` presents the store (links, a manifest) is
  too.
- *Stale layouts (F6).* A file left by an older layout where a unit directory now goes fails the build with
  an opaque "File exists". The redesigned layout should say how a stale or foreign layout is detected and
  cleared. (F6's other half, a clash between the workspace-root module's binary and a child module's
  directory, is gone: packages, and so modules, live below their workspace's root; 190.6 F14.)

Each item lists the options, then the current lean. Nothing here is locked; this is the agenda.

### Cache key composition

What determines a module's cache entry. Candidate inputs: the module's own source content, the compiler
(recipe) version, the codegen/mode flags (incl. the 100.5 `--mono` dial), the target triple/arch, and the
**transitive ABI hashes** of its dependencies.

- *Content vs timestamp keying.* Options: (a) hash file **content**; (b) mtime + size. Content hashing is
  correct under branch switches, touch-without-edit, and shared/remote caches; mtime is cheaper but lies
  across checkouts and RBE. **Lean: content hash** (FNV-1a over source bytes, the same family the runtime
  archive already uses), with mtime as an optional fast-path pre-filter that still verifies by content on a
  candidate hit.
- *Dependency contribution — ABI hash, not object hash.* A dependent keys on each dependency's `abiHash`
  (transitively closed over re-exports), never on the dependency's object bytes — so a dependency's body /
  perf edit that preserves its ABI leaves the dependent's key fixed and its object reused. **Lean: fixed.**
- *Compiler version.* Embed a recipe version (the runtime archive's `"recipe-N"` model) so a compiler change
  invalidates everything without the user clearing anything. **Lean: fixed.**

### Invalidation walk

On a build: hash each module's inputs, compare to the cache, and compute the dirty set. A module recompiles
when its own content changed, its flags/target/compiler changed, or a dependency's ABI hash changed. A
module whose inputs are unchanged and whose dependencies' ABI hashes are unchanged is **skipped** — its
cached `.o` + `.nmi` are reused. The walk is a topological pass over the existing module graph (100.2.1).

- *ABI-stable propagation.* The key property: a body edit bumps only `perfHash` and the object, so the
  rebuild stops at the edited module. Teeth: a dependent's object is reused (unchanged) across a dependency
  body edit. Open: whether a perf-hash change ever needs to reach a dependent (it does once the 100.5 `--mono`
  dial reads `.bir` bodies cross-module — see below).

### The specialization-dial interaction (the subtle one)

Under the witness baseline (debug), a dependency's generic **body** never crosses the boundary, so a body
edit cannot affect a dependent — the clean ABI/perf split holds. Under the 100.5 `--mono` dial, a dependent
reads a dependency's `.bir` body to specialize, so a dependency body edit **can** invalidate the dependent's
specializations. The cache key must therefore include the mode, and under `--mono` a body edit's invalidation
reaches dependents that specialized against it. **Lean: the `--mono` dial is part of the key; the `.bir`
section gets its own hash (a third section hash alongside ABI/perf), and a dependent that specialized keys on
it.** Settle the exact dependency during design; this is the reason perf-hash-stability alone is not the
whole invalidation story.

### Artifact store — layout, atomic publish, concurrency

Generalize the content-addressed runtime-archive cache (`cachedRuntimeArchive`): a store keyed by the 172.1
key, holding each module's `.o` + `.nmi` (+ escape summary / later `.bir`). Writes go to a pid-unique scratch
path and publish by atomic rename under the content key, so a crash or a concurrent build never leaves a
partial artifact at a shared path. **Lean: reuse that exact discipline.**

- *Store location.* Options: (a) per-project `build/cache/`; (b) a shared per-user/global cache; (c) both
  (project cache, optional shared layer). A shared layer is what makes CI / multi-checkout / RBE reuse real.
  **Lean: project cache first, designed so a shared/global layer and an RBE action cache drop in behind the
  same key (the design already stays RE-ready).**
- *Concurrency.* Parallel module builds (and parallel top-level builds) must not corrupt the store — atomic
  publish + content keys make a race benign (both produce the same bytes under the same key). **Lean: fixed.**

### Determinism / reproducibility

Content-addressing is only sound if the same inputs produce byte-identical artifacts. The `.nmi` is already
deterministic (name-sorted, body-free, 100.4.1). Object emit must be equally reproducible (no embedded
timestamps/paths, stable symbol ordering). **This is a prerequisite, not an optimization** — without it a
"hit" can serve stale or mismatched bytes. Audit and pin object determinism as part of the task.

### Cache lifecycle

Eviction / size cap / staleness / manual clear; cross-run persistence; corruption resilience (a bad entry
is detected and rebuilt, never served). Options for eviction: LRU by access time, a size ceiling, or
never-evict + manual clear (the runtime archive's current model). **Lean: start never-evict + `clean`
command, add a size-bounded LRU once the cache is shared.**

## Phases (buildable decomposition)

- 172.1 — **Cache key model.** Define and compute the per-module key (content + compiler recipe + flags +
  target + transitive dependency ABI hashes). Encodes the ABI-hash invalidation rule. Unit-tested
  standalone: equal inputs → equal key; a perf-only dependency change → unchanged dependent key; an ABI
  change → changed dependent key.
- 172.2 — **Artifact store.** Content-addressed `.o` + `.nmi` (+ escape summary) store with pid-safe atomic
  publish, hit/miss, generalized from `cachedRuntimeArchive`.
- 172.3 — **Invalidation walk + skip.** Topological pass over the module graph: hash, diff, compute the
  dirty set, recompile it, reuse cached artifacts for clean modules, link as today.
- 172.4 — **Object-emit determinism.** Audit + pin reproducible object bytes (the content-addressing
  prerequisite); a differential check that two clean builds of the same source produce byte-identical `.o`.
- 172.5 — **Lifecycle.** `clean`; corruption detection + rebuild; (later) size cap / eviction; (later) a
  shared cache layer.
- 172.6 (tests) — **Stability + correctness harness** (the former 100.4.6). Covers:
  - a body edit does **not** rebuild dependents (teeth: a dependent's object is reused — a recompile counter
    / object identity, not just output equality);
  - `.nmi` ABI-section **byte-stability** across recompiles of unchanged source;
  - an ABI edit **does** cascade to dependents;
  - incremental-build output == clean-rebuild output == whole-program-mono golden (the 100.4 differential,
    extended);
  - concurrency: parallel builds against one cache produce correct, uncorrupted artifacts.

## Dependencies & triggers

- **Depends on:** [198](198-build-configuration.md) (build configuration). Every setting that changes compiled
  output enters the key through the configuration's canonical form, and every workspace compiles under a
  defined configuration; the key is designed against 198's settings.
- **Rides:** [164](164-formal-inference-stage.md) §164.4.2 (sectioned `.nmi`, independent ABI/perf hashes —
  the invalidation lever) + §164.4.3 (per-definition perf section); the content-addressed runtime-archive
  cache (the store model); [100](100-modules.md) §100.4.1/.2 (`.nmi` + per-module objects).
- **Feeds:** [136](136-incremental-compilation.md) (fine-grained/query incremental reuses the key + store),
  [137](137-tooling-lsp-formatter.md) LSP responsiveness, Bazel RBE (the design stays RE-ready).
- **Interacts with:** [100](100-modules.md) §100.5 (the `--mono` specialization dial — `.bir` in the key),
  [145](145-monomorphization-cost.md) (cached monomorphizations), [142](142-ir-pipeline-hardening.md)
  (versioned stage-boundary formats, so a cached artifact is never misread across a format change),
  [156](156-differential-stage-diffing.md) (shares the determinism requirement).

## Open design questions (for the session)

1. The exact `.bir` / `--mono` invalidation dependency (when a dependency body edit must reach a dependent).
2. Shared/global cache layer + RBE action-cache mapping — now or deferred behind the same key.
3. Granularity floor: module-level only here, or a first step toward per-definition keying (the bridge to
   136).
4. Eviction policy and cache-size governance once shared (with [199](199-cache-management.md), cache
   management).
5. Whether the cache key folds in the GC/runtime archive key (so a runtime change invalidates module objects
   that inlined runtime-subset code).
6. **Which dependency interfaces enter a module's key** ([190](190-explicit-module-builds.md) 190.6 F15). A
   release compile needs the transitive `.nmi` closure plus its dependencies' `.bir` (§100.5: specialized
   bodies reach anything their producers could see), so its key covers them; an ABI change deep in the graph
   then invalidates every module above it. A debug compile needs only direct `.nmi` (and the types visible
   signatures name), so its key could be narrower; whether to key the two modes differently is open.
7. **The key hash** ([190](190-explicit-module-builds.md) 190.6 F16). The cache serves one execution host;
   remote caching and remote execution are Bazel's ([192](192-bazel-friendliness.md)), so collisions matter
   only by accident and the hash need not be cryptographic. Today it is 64-bit FNV-1a (`Hasher64`). A
   replacement must meet all of:
   - no dependencies: implementable in Swift, and later in Nomu, at a reasonable size (ideally under 20 KB
     and 1000 lines);
   - overall throughput at least FNV-1a's;
   - acceptable latency on small inputs (it need not beat FNV-1a there, but nothing egregious);
   - collision probability similar to 64-bit FNV-1a or better.

   Candidates to measure: FNV-1a at 128 bits (same code, wider state) and an in-tree XXH3 (64 or 128 bits).
   Accidental-collision odds for a 64-bit key: about N²/2⁶⁵ for N entries (about 3 × 10⁻⁸ at a million).
8. **Re-audit how key inputs are hashed** (190.6 F25): the embedded sources, the runtime key and the
   embedded tree are hashed once per process today; check that every input of the new keys is too.
9. **The compiler's identity in the key** ([190](190-explicit-module-builds.md) 190.6 F5). Today it is the git
   commit the compiler was built from, so uncommitted compiler changes reuse stale entries. The identity
   must change whenever compiled output can, and should stay put when it cannot, since most compiler
   rebuilds leave output unchanged and every identity change rebuilds the whole cache. Candidates: a hash of
   the compiler binary (exact, about 20 ms for 59 MB and nearly free when remembered per inode, size and
   modification time, but it changes on every compiler rebuild); the commit plus a hash of the dirty tree
   (cheap; no protection outside git; needs limiting to compiler paths); a Bazel-computed hash of the
   compiler's sources (exact to source, independent of git; misses toolchain changes unless included);
   manual format and ABI versions (stable, but misses changes nobody versioned). A combination may fit:
   for example, a coarse identity for the cache plus a format/ABI check at load.

## Refs

[100](100-modules.md) §100.4.5/.6 (the pulled-out items), §100.5 (dial); `ModuleInterface.abiHash`/`perfHash`
(`src/interface/sources/ModuleInterface.swift`); `cachedRuntimeArchive` / `runtimeArchiveKey`
(`src/driver/sources/Driver.swift`); `internals/inference.md` (the fact-store sections feeding the perf
hash). A dedicated `internals/build-cache.md` contract doc can spin up during the design session.
