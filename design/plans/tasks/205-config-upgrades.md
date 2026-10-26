# Config upgrades

**Avenue:** Usability · **Type/Lifecycle:** `tooling · deferred` · **Size:** M · **Status:** deferred — taken
up after [172](172-incremental-build-cache.md) · **Source:** [198](198-build-configuration.md), the parts of
the configuration story left out of the minimum 172 needs.

## What

198 builds the configuration system as far as the build cache needs it: settings resolve once per build and
every input that changes a compiled object reaches the job file. These items make the system usable and
complete. The design goals (G1–G20) and the decisions behind them are in 198's doc.

The questions a user needs answered, during development and after the fact: what settings the code they
care about uses, and how it got them (including why a declaration of theirs lost). After the fact, the
answer is to check out the revision and build, so builds keep no large resolution files around by default.

## Items

- **205.1** A view of one module's resolution, printed and never stored: each setting's final value, the
  layer and `file:line` that set it, and the declarations that lost, each with its reason (the resolver
  already marks every candidate won, overridden, outranked or unmatched). Its flag, its default module (the
  entry) and whether it stops the build are open. The whole-build record (G1) has no `nomu` surface;
  `cfgresolver` prints it for its goldens.
- **205.2** The builtin file (G19): the compiler writes its schema as a read-only `cfg.yaml`
  (`Schema.builtinFile`) into the host cache under its own identity, and prints its path where users look
  (205.1's output, `-c`'s help). Every `cfg.yaml` is a specialization of it.
- **205.3** Provenance in the binary: the short form in `__nomu_config` gains `source`, the entry
  workspace's revision, beside `compiler` (today the two coincide for the suite, whose fixtures live in the
  compiler's repository). Assumptions to settle about the user's source control: a git repository
  (`git rev-parse HEAD`, the enclosing repository's when the workspace is nested); uncommitted changes
  (`-dirty`, at the cost of a `git status`, which can take 100 ms or more on a large repository); not a
  repository, or another VCS (`none` to start); externals pinned by local path, whose revisions go
  unrecorded until [189](189-multi-remote-workspace-builds.md) versions them. `source` is deterministic for
  a checkout, so it keeps G11.
- **205.4** Diffing two configurations: what selecting one config changes compared with another.
- **205.5** Runtime settings off environment variables: GC stress, nursery reserve, mature floor, trigger
  reserve, carriers, the GC driver threads, through the settings object 198.4 built (G14). A GC leg then
  needs its own binary, so this likely brings the run-time override G14 leaves open, letting the harness
  compile many fixtures under one config and give each run its own values. The override could itself be a
  baked run setting, off by default and on under `test` (GHC's `-rtsopts`), so a release binary's record
  still describes its behavior. Codegen reads the GC values as loads of runtime globals, so an override
  needs no recompile.
- **205.6** The harness's run legs onto configs (with 205.5), and configurations of one fixture compiled in
  parallel again, dropping the copy into `build/compiler-test/`.
