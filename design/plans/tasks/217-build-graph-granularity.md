# Build graph granularity — interface and object actions, one interface artifact, sliced keys

**Avenue:** Infra · **Type/Lifecycle:** `driver · perf · needs-design` · **Size:** L · **Status:** needs-design ·
**Source:** found while finishing [172](172-incremental-build-cache.md): its keys are sound but transitive, each
module is one action, and jobs run one at a time. The build graph is expected to grow large, so it is shaped for
both full-graph throughput and full-graph latency, as Bazel shapes its action graph.

## What

The build graph's unit is the action, and an action starts once its input files exist, which is earlier than
when the module that produces them is finished. Each module becomes two actions over one interface artifact,
and a consumer's key covers only the parts of its dependencies it reads, so early cutoff stops at the first
module whose outputs it reads are unchanged.

## Today

- **One action per module:** parse, sema, the `.bir`, mono, the lowering, module inference, the `.nmi`, the
  optimizer passes, LLVM and the object. A consumer reads only the `.bir` (written after sema) and the `.nmi`
  (written after module inference), yet waits for the whole job.
- **Two interface files per module** (`.nmi`, `.bir`), every library writing both.
- **Transitive whole-file keys:** a job receives every transitive dependency's `.nmi` and `.bir` and its key
  covers their bytes. The compile reads less: of a dependency that is neither direct nor re-exported, only the
  types a visible signature names (`externals()`, `foreignTypes`), and none of its `.bir` or escape facts. So an
  interface change at the bottom of a chain recompiles every module above it, even when a module between
  produces byte-identical outputs (seen on `module_link_diamond`: `root` recompiled after `left` and `right`
  did).
- **Jobs run one at a time,** in plan order.

## Design

1. **One interface artifact per module** with sections `abi`, `perf` and `templates` (the `.bir`), extending the
   sectioned `.nmi` ([164](164-formal-inference-stage.md) §164.4.2). A header holds each section's offset and
   hash and a hash per declaration, so a consumer's key is computed from headers without hashing whole files.
2. **Keys over what a compile reads.** Direct dependencies and their re-exports enter whole, by section hash. A
   transitive dependency enters as a slice: the declarations reachable from its consumers' surfaces, computed
   from the direct dependencies' interfaces before the compile (the types their signatures name, the callees
   their templates reach, with those callees' escape results and, for a generic callee, its template). The job
   carries the slice and the compile loads only it, so key and input agree by construction.
3. **Two actions per module:** an interface action (sources and dependency interfaces → the interface
   artifact) and an object action (→ `.o`), each with its key and its store entry. Every object action can
   start once the interfaces it reads exist: the critical path becomes the chain of interface actions plus
   the longest object action. Precedents: Rust's pipelined compilation (`.rmeta`), Swift's separate module
   emission, Java header compilation under Bazel.
4. **A scheduler:** actions run concurrently as their inputs appear, bounded by cores, over one plan.

## Open questions

1. **Where the interface boundary sits.** [202](202-one-inference-phase.md) settled where the published
   results come from: module inference over the one monomorphized lowering, so the `.nmi`'s perf section is
   ready only after mono, the lowering and module inference. The `.bir` and the ABI section are ready after
   sema. Open: whether the interface artifact's sections become available separately (a consumer's sema and
   mono start once the ABI section and templates exist, its module inference once the perf section does),
   or the interface action ends after module inference.
2. **What the object action reuses** from the interface action instead of redoing (parse and sema, the
   lowering): stored state, or recomputation, by measurement.
3. **The slice's closure:** whether every declaration a transitive slice needs is reachable from the direct
   dependencies' interfaces alone, including what specializing a direct dependency's generic needs from
   further down (escape results and templates of the callees it reaches). Check the case of a direct
   dependency's template calling a transitive generic, which today has no template to specialize from.
4. **Header format and hash:** shares 172's open question on the key hash.

## Work

- **217.1** Measure: the share of a compile before and after the interface is written, per module, on the
  suite and `runtime`; the recompiles the transitive key causes over a set of edits.
- **217.2** One interface artifact with a hash header; the planner and the key read headers.
- **217.3** Sliced transitive keys and inputs; `--explain` names the declarations whose change recompiled.
- **217.4** Interface and object actions, each in the store.
- **217.5** The scheduler.
- **217.6** Tests: an interface change that leaves a middle module's outputs identical stops there; a
  transitive change outside every slice recompiles nothing above the middle; output equals a clean build;
  the sweep holds.

## Dependencies

- **Depends on:** [202](202-one-inference-phase.md) (one lowering per module), which fixes the interface
  boundary; [172](172-incremental-build-cache.md), whose keys, store and build record it narrows and splits.
- **Interacts with:** [136](136-incremental-compilation.md) (finer granularity below the module),
  [192](192-bazel-friendliness.md) (the same actions under Bazel), [199](199-cache-management.md).

## Refs

`compile` (`src/driver/sources/CompileJob.swift`: `LoadedDependencies`, `externals()`, `importedTemplates`,
`dependencyResults`); `JobKeyer.key`/`details` (`JobKey.swift`); `ModuleJob.visibleDependencies` (`Plan.swift`);
`publishedResults` (`CompileSupport.swift`).
