# Build graph granularity — one interface artifact, sliced keys, scheduler

**Avenue:** Infra · **Type/Lifecycle:** `driver · perf · needs-design` · **Size:** L · **Status:** needs-design ·
**Source:** found while finishing [172](172-incremental-build-cache.md): its keys are sound but transitive, each
module is one action, and jobs run one at a time. The build graph is expected to grow large, so it is shaped for
both full-graph throughput and full-graph latency, as Bazel shapes its action graph.

## What

Each module writes one interface artifact, and a consumer's key covers only the parts of its dependencies it
reads, so early cutoff stops at the first module whose outputs it reads are unchanged. Jobs run concurrently as
their inputs appear. Staged jobs, which release dependents at a job's interface stage, are designed here and
deferred (design item 3).

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
3. **One staged job per module (deferred).** Staging shortens only the critical path, so it pays only while
   cores wait on dependencies: interface-edit chains, small workspaces with a heavy root, wide hosts. A large
   cold build on one host keeps its cores busy with whole jobs, parallel codegen inside a job uses the same idle
   cores, and remote execution (REAPI, one result per action) runs whole jobs. So the scheduler runs whole jobs
   first, and staging waits for the build report to show idle cores on real builds (217.4's utilization). The
   design below is kept so the scheduler leaves room for it.

   A module compiles as one job, in memory, whose outputs become ready in two
   stages: the interface stage (the `.nmi` and `.bir`, after module inference) and the object stage (the `.o`).
   At its interface stage the job signals the scheduler, and dependents start, while the same job carries on
   to its object. The critical path becomes the chain of interface stages plus the longest object stage. One
   key and one store entry per job, as today. Precedent: Cargo's pipelined compilation (since Rust 1.38):
   `rustc` writes a crate's `.rmeta` partway through, announces it (`--json=artifacts`), and continues to
   codegen in the same process while Cargo starts the dependents.

   Chosen over two actions per module (Bazel's model: an interface action and an object action). Bazel's
   outputs appear only when an action ends, because it runs tools it does not control, in sandboxes or on
   remote workers whose protocol (REAPI) returns one result per action; an early output there becomes its own
   action that repeats the front end (Java header compilation, Swift's emit-module job, `rules_rust`'s metadata
   action). Swift's repeat is cheap because its interface needs declarations only; ours carries module
   inference's results, so a separate interface action would redo lowering and inference (~34% of a library's
   compile, 217.1) or pass that state through disk. The staged job keeps the state in memory and does the work
   once.

   **Rules.**
   - *Final at release.* Once a job signals its interface stage, nothing later in it changes its `.nmi` or
     `.bir`, and both depend only on the job's inputs. Anything a module publishes is computed before its
     interface stage; facts computed after stay local. A future export computed after optimization (inlinable
     bodies taken from optimized IR, a stack-depth bound after inlining) becomes a further stage, not a later
     interface stage.
   - *User errors first.* Every user-facing diagnostic comes before the interface stage (today parse, sema,
     exhaustiveness and lowering all do); after it, only internal compiler errors remain.
   - *Commit order.* A job's results (its files in `build/`, its store entry, its outcome in the report) become
     visible only when the job has finished and every producer it read has committed. A producer that fails
     after its interface stage cancels everything downstream of it: nothing of theirs reaches `build/` or the
     store, and the report marks them cancelled. A build's outcome is the sequential schedule's; only its time
     differs.
   - *Interfaces through scratch files.* Dependents read a producer's interface from its scratch directory,
     not its memory: the files are small, and the rule holds unchanged if jobs ever run as separate processes.
   - *Independent of timing.* The modules compiled, the outputs and the diagnostics (reported in plan order)
     are the same under any schedule, and under any thread schedule inside a job once jobs use threads.
   The first version continues to the object stage at once. Pausing a job in memory and resuming its object
   stage later, so interface stages run first (critical-path-first scheduling under a memory budget), is a
   later scheduler change that needs no change to the job. Under Bazel ([192](192-bazel-friendliness.md)) a
   module is one action without pipelining, or a split action that repeats the front end.
4. **A scheduler:** jobs run concurrently as their inputs appear, bounded by cores, over one plan. A job starts
   once every producer it reads has finished; with staged jobs, a job's interface stage releases its
   dependents.

## Open questions

1. **Where the interface boundary sits.** Decided: an action starts only once every input it reads is complete.
   A dependent waits for each dependency's whole interface (the `.bir` and the `.nmi` with every section);
   it does not start its sema and mono on the `.bir` and the ABI section ahead of the perf section. With the
   published results coming from module inference over the one monomorphized lowering
   ([202](202-one-inference-phase.md)), the interface action ends after module inference: ~34% of a library's
   compile, the other ~66% in its object action (217.1). Starting on partial inputs (the `.bir` is ready at
   ~11%) stays a possible later refinement, measured against this.
2. **What the object action reuses** from the interface action. Decided by design item 3: there is one job, so
   the object stage continues from the interface stage's state in memory and nothing is reused or redone.
   Until staging lands, the job is whole and the question does not arise.
3. **The slice's closure:** whether every declaration a transitive slice needs is reachable from the direct
   dependencies' interfaces alone, including what specializing a direct dependency's generic needs from
   further down (escape results and templates of the callees it reaches). Check the case of a direct
   dependency's template calling a transitive generic, which today has no template to specialize from.
4. **Header format and hash:** shares 172's open question on the key hash.

## Work

- **217.1** Measure: the share of a compile before and after the interface is written, per module, on the
  suite and `runtime`; the recompiles the transitive key causes over a set of edits.

  **Done.** From the build reports (193), over every suite fixture (one cache, each module counted at its
  first compile):

  | point in a library's compile (66 libraries) | share of compile time |
  |---|---|
  | `.bir` written (end of sema) | 11% |
  | `.nmi` written (after mono, lowering, module inference) | 34% (per module p10/p50/p90: 24/35/39%) |
  | after the `.nmi` (optimizer, LLVM, object) | 66% |

  `runtime`: 558 ms; the `.nmi` at 196 ms (35%), of which lowering is 174 ms; 362 ms after it. Binaries (138)
  have nothing above them; their split is moot.

  Recompiles, on the six fixtures with three or more own modules, each edit at the module with the most
  dependents: a body-only edit (a private function added) recompiles nothing above the edited module (its
  `.nmi` and `.bir` stay byte-identical, so today's key already stops there). An interface edit (a `package`
  function added) recompiles 15 modules above it: 11 read the edited module directly (an import, or a
  re-export through one), 4 read it only transitively (the roots of `gc_generic_two_consumers`,
  `mangle_generic_two_consumers`, `module_foreign_type`, `module_link_diamond`), which a key over direct
  inputs and transitive slices skips. The added function is used by no module, so a key over the
  declarations each module reads from its direct dependencies would skip all 15; the design as written keys
  direct dependencies whole (by section hash). The measurement scripts read `build/_perf/report.json` and
  the plan dump.
- **217.2** One interface artifact with a hash header; the planner and the key read headers.
- **217.3** Sliced transitive keys and inputs; `--explain` names the declarations whose change recompiled.
- **217.4** The scheduler over whole jobs: jobs run concurrently as their producers finish, bounded by cores;
  diagnostics reported in plan order. The report adds core utilization (`summed / (wall × cores)`) and the
  critical path a staged schedule would have (each producer releasing at its interface stage), the evidence
  217.7 waits on.
- **217.5** Tests: an interface change that leaves a middle module's outputs identical stops there; a
  transitive change outside every slice recompiles nothing above the middle; output equals a clean build;
  the sweep holds; builds under shuffled schedules give identical outputs and diagnostics.
- **217.6** Measure, on real builds (cold, interface edit, body edit) after 217.4: utilization, and the
  critical path with whole jobs against a staged schedule and against `summed / cores`. Decides whether
  217.7 is worth building.
- **217.7** Staged jobs (deferred, design item 3): the interface stage written to the job's scratch directory
  and signalled; commit order for `build/`, the store and the report; cancellation downstream of a failed
  producer. Tests: a producer that fails after its interface stage leaves nothing of its dependents in
  `build/` or the store and reports them cancelled; no published file changes after its stage signals.

## Dependencies

- **Depends on:** [202](202-one-inference-phase.md) (one lowering per module), which fixes the interface
  boundary; [172](172-incremental-build-cache.md), whose keys, store and build record it narrows and splits.
- **Interacts with:** [136](136-incremental-compilation.md) (finer granularity below the module),
  [192](192-bazel-friendliness.md) (the same actions under Bazel), [199](199-cache-management.md).

## Refs

`compile` (`src/driver/sources/CompileJob.swift`: `LoadedDependencies`, `externals()`, `importedTemplates`,
`dependencyResults`); `JobKeyer.key`/`details` (`JobKey.swift`); `ModuleJob.visibleDependencies` (`Plan.swift`);
`publishedResults` (`CompileSupport.swift`).
