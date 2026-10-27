# Job keys — a key per compile job over everything it reads

**Avenue:** Infra · **Type/Lifecycle:** `driver · ready-to-build` · **Size:** M · **Status:** ready-to-build ·
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

## Refs

`CompileJob`, `JobFile`, `EmitOptions` (`src/driver/sources/CompileJob.swift`, `EmitMode.swift`);
`HostCache` (`Hasher64`); 172's "What 198 leaves to the key".
