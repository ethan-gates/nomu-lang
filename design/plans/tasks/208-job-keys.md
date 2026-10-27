# Job keys — a key per compile job over everything it reads

**Avenue:** Infra · **Type/Lifecycle:** `driver · done` · **Size:** M · **Status:** done ·
**Source:** [172](172-incremental-build-cache.md) (Cache key composition). A prerequisite of 172; needs
[206](206-compiler-identity.md).

## Decided

A job's key covers the bytes the compile reads, as Bazel keys an action on its inputs' contents. A
dependency contributes the bytes of the `.nmi` and `.bir` the job reads, not a hash of one section: a
dependent's compile reads its dependencies' perf facts (escape summaries, through `externalEscape`) as well
as their ABI, and under `opt.mono` their `.bir` bodies, so a key over the ABI hash alone would serve stale
objects. Early cutoff comes from determinism instead ([207](207-build-determinism.md)): a dependency that
recompiles to identical bytes leaves its dependents' keys unchanged. Set aside: keying on chosen section
hashes (ABI always, perf when read, `.bir` under mono), which cuts off earlier but makes every new
cross-module read remember to join the key.

## The key's inputs

- The `CompileJob`: its source files' contents, imports, dependency list, product, `settings` in canonical
  form (198).
- The options that change an object: `subsetFuncs` (`--runtime-subset`), `compilingPrelude`, `whiteBox`,
  `runtimeSubsetByMembership`. Options that change no object (the `--emit-*` dumps, `--stop`, `emitJobs`)
  stay out, so switching a dump does not rebuild.
- The compiler identity (206) and the target triple, CPU and features (objects are tuned to
  `LLVMGetHostCPUName`).
- Each dependency's `.nmi` and `.bir` bytes, by hash of the file.
- Absolute source paths while debug info embeds them (until 207.3).

## Work

- **208.1** Compute the key from a job and its dependencies' outputs, behind one hash function (64-bit
  FNV-1a today; 172 open question 7).
- **208.2** Record the key's inputs beside the entry, each named, so two keys can be compared input by
  input: the answer to "why did this rebuild" (a source file, a setting, a dependency's interface).
- **208.3** Re-audit that each input is hashed once per process (190.6 F25).
- **208.4** Tests: equal inputs give equal keys; changing any one input changes the key; a dump-only option
  does not; a dependency whose outputs are byte-identical leaves the key unchanged.

## Done

- `JobKeyer` and `JobKey` (`src/driver/sources/JobKey.swift`). A key is a `Hasher64` over its named inputs in
  name order; `JobKey.changes(from:)` lists the names whose values differ. The inputs: `compiler`, `target`,
  `target.cpu`, `target.features`; `module`, `package`, `package.key`, `product`, `product.public`,
  `white-box`, `runtime-subset.membership`; `files` (in order), and per file `source:<path>` and
  `imports:<path>`, each file named by the path debug info records (207.3's `/nomu-src/…` form, so no input is
  an absolute path; the reported path, diagnostics only, stays out); `dependencies`
  (origins, in order), and per dependency `dep:<origin>.package`, `.nmi` and `.bir`; `setting:<name>`;
  `option.runtime-subset` and `option.compiling-prelude`. Output paths, the dumps, `stopAt`, `emitJobs` and
  `allowCoreImport` stay out. A dependency offered without a `.bir` path reads `none`.
- Every library job now writes its `.bir`, empty when it ships no templates, so the key hashes it like the
  `.nmi`. A dependent fails on a missing or unreadable offered `.bir` (`missing the templates of …`) where it
  used to fall back to the witness path.
- One hash function: `Hasher64` moved from the planner to `src/store`, where `ContentHash` (manifests) and the
  host-cache keys use it too. `objectTarget()` (`LLVMBridge`) reports the triple, CPU and features
  `emitModuleObject` uses.
- 208.2: the inputs are named in the key (`JobKey.inputs`) and computed when asked for, as Bazel writes its
  execution log only on request: `--verify-cache` prints them on a mismatch, and 212's report computes them.
  An action result records the key alone (`key`), with its files.
- 208.3 audit (190.6 F25): the compiler identity, target and CPU-features hash are computed once per
  `JobKeyer`; each file is hashed once per process and again only when its size or modification time
  changes, so a dependency's `.nmi` read by many dependents is hashed once; language-workspace sources are
  hashed once from the embedded tree. Per job, only its own imports are re-encoded.
- 208.4: `job_key_tests` covers equal keys, every input above changing the key and only its own name, source
  and dependency edits, a dependency rewritten with identical bytes, dump-only options and output paths, and
  a missing `.bir`. `build_tests` checks a real entry's recorded inputs, that every library writes its `.bir`,
  and that `nomu compile` fails when a dependency's `.bir` is missing.
- For 172.1: a job that stops before its object (`stopAt`, a terminal `--emit-nmi`) has no entry to publish,
  since its key leaves those options out.

## Refs

`CompileJob`, `JobFile`, `EmitOptions` (`src/driver/sources/CompileJob.swift`, `EmitMode.swift`);
`HostCache` (`Hasher64`); 172's "What 198 leaves to the key".
