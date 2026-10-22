# Build configuration — every build and runtime setting part of one configuration system

**Avenue:** Infra · **Type/Lifecycle:** `driver · runtime · design` · **Size:** L · **Status:** design firm;
ready to build — the YAML parser ([200](200-yaml-parser.md)) is done · **Source:** the 176.5.7 harness design, which needs GC and memory behavior varied per test run and
found it reachable only through environment variables; [190](190-explicit-module-builds.md) 190.6 F4
(build options reach only the entry workspace).

## Deliverable

A designed and built configuration system. A **setting** is one knob that changes what the compiler emits or
how a built program behaves (GC, memory, optimizer passes, diagnostics). A **config** is a named, declared set of
setting values (`debug`, `release`, `test`, or a user's own such as `production`). A **configuration** is
what resolution produces: the full set of settings in force for one module's compile, one link or one run.
Values come from the builtin defaults, the selected config, workspace, package and module files, and the
command line; a command-line flag is one source of a setting among these. Ambient environment variables stop
changing results.

## Design goals

- **G1. Observable resolution.** For every setting, `nomu` can show the final value and how it got there:
  each layer that declared it, the flattened config list (G4), and which declaration won. Each value records where it
  came from (file and line, CLI flag, or "from builtin (`release`)").
- **G2. Cacheable barriers key on their inputs.** A cacheable barrier is a deterministic step whose cache
  key is the hash of everything it receives. `nomu compile` (and its in-process form) is the main one: its
  key hashes the job file, which carries the resolved settings (G12), plus its source and interface inputs.
  A setting changes a job's key exactly when the driver passes it into that job; nothing classifies
  settings for the cache, so a setting a job never receives cannot give a stale hit, and over-passing costs
  only a recompile. This is Bazel's action-key model (command line, input digests, declared environment).
  The job file writes resolved values in a canonical form, so spellings that compile identically hash
  identically (`-O` and `-O --mono=all` give one key). Other barriers (the link, for one) may follow the
  same rule. The keys feed the host cache (the language workspace's key, today
  `PlanOptions.outputOptions`, never filled) and [172](172-incremental-build-cache.md)'s module cache; 172's
  key design depends on this one.
- **G3. Always a value.** Every setting has a built-in default at the bottom layer, so resolution never
  comes back empty. Defaults are chosen on purpose and may be opinionated.
- **G4. Configs.** A config is a generic construct: a declared name with at most one parent it inherits
  from. The resolver has no special cases; `debug`, `release` and `test` are declarations in the builtin
  layer, and a user's configs are declared the same way:

  ```yaml
  # builtin
  configs:
    debug: null
    release: null
    test: debug

  # workspace
  configs:
    production: release
    rbe: debug
  ```

  The value is the parent, or `null` for none; a config need not descend from a builtin one. Configs are
  declared only in the builtin and workspace layers; redeclaring a name is an error, and so is naming an
  undeclared config. An external workspace's declarations apply when it is the entry and are invisible
  when it is consumed.

  **Selection.** One or more configs are selected per build (`nomu build -c debug --config rbe`), which
  makes configs composable: one from a pair of GC configs, one from a pair of speed/size configs.
  Selection belongs to the CLI alone: no file selects a config for the entry, and selection cannot be
  qualified. Each subcommand has a default (`build` and `run` select `debug`, `test` selects
  `test`); any `-c` replaces the default, so `nomu build -c release` selects `release` alone and
  `nomu test -c rbe` selects `rbe` alone. The selection flattens to one ordered list: each selected
  config's chain from its root down to itself, in selection order, keeping the first appearance of a
  repeated name. With `rbe: debug`, `-c rbe -c debug` flattens to `[debug, rbe]`. A config's values are declarations at the layer that
  writes them (G16 syntax), carried upward until a stronger layer declares the setting; there is no
  separate class of "implied" values.
- **G5. One stack of layers.** Values resolve through one ordered stack, weakest first:
  `builtin < workspace < package < module < CLI`. The module is the finest layer, so module-level
  overrides are possible; it is also the compilation and cache unit, which is why no file layer exists.
  The CLI is the strongest layer and coarse: it addresses no package or module, and what it sets applies
  to the whole build (finer CLI addressing may come later). Layers are generic
  sources in an ordered list, each producing values with provenance (G1), so adding one (a system or user
  layer, say) is one more entry. The workspace, package and module layers are each an optional `cfg.yaml`
  in the workspace, package or module directory: one file name and one schema for every layer, kept apart
  from the manifests, which stay about identity and dependencies. A `cfg.yaml` at a package root that is
  also its root module is the package layer. Most projects are expected to have only the workspace file.
  Considered and set aside: config sections inside `nomu.yaml` and `pkg.yaml` with module values keyed by
  path (mixes configuration into the manifests, and path keys read poorly beside config qualifiers), and a
  hybrid of manifests for workspace and package with `cfg.yaml` for modules. Considered and set aside: separate stacks for build-wide and per-module
  settings (two walks to learn and report), one build-wide configuration with no package or module layers
  (loses module overrides), and Cargo-style overrides written only in the workspace file (package authors
  could ship no defaults).
- **G6. Files first, flags second, environment never.** File-based configuration is the main source and CLI
  flags are an override layer. The compiler, the driver and built programs read no `NOMU_*` environment
  variables, so a variable in a developer's shell cannot change a build or a run.
- **G7. Plain data.** Configuration files, config declarations included, are static data that a tool can
  read without running anything, as `modules.md` §Manifest already requires of manifests. A config is
  declared values; Bazel's Starlark transitions are the contrast.
- **G8. One typed schema.** Each setting is declared once, with a name, type, allowed values, default, doc
  string, target set (G10), granularity (G18) and, for list- and map-valued settings, a merge rule
  (replace by default; append when the schema says so). CLI parsing, file validation, docs and the G1 report all come from that
  declaration. An unknown setting name or a bad value is an error. The schema for built-in settings lives
  in the compiler, which reads them; user files set values and define bundles.
- **G9. Deterministic, conflict-checked resolution.** The same inputs always produce the same
  configuration. The order of declarations and of setting flags never matters; Bazel's in-place
  `--config` expansion, where position decides, was set aside. The one deliberate exception is the order
  of selected configs: in the flattened list (G4) a later config beats an earlier one, so
  `-c gc_fast -c small` and `-c small -c gc_fast` can differ, and the G1 report shows the list in order.
  Config parents form no cycle. Precedence: layer order decides first. Within one layer, a qualified
  declaration (G16) matches when it names a config in the flattened list; the declaration naming the
  latest config in the list wins, then unqualified. Two declarations in one layer whose winning config is
  the same, with different values, are a reported conflict, as are two spellings of one declaration in one layer
  (`opt release:` with `inline:` inside, and `opt:` with `inline release:` inside). There is no "reset to
  inherited" spelling; a stronger layer writes the value it wants (and `null` already means "no parent" in
  `configs:`).
- **G10. Each setting declares its targets.** Targets are compile output, build behavior (planning,
  linking, cache location), the running program, and diagnostics (dumps, timing). A setting may declare
  several: `gc.plan` changes emitted code (barriers, the inline allocation path) and is read by the
  runtime, so it declares `[compile, run]`. Targets document a setting, group the G1 report, and tell the
  driver which jobs receive it (a diagnostic dump reaches only the jobs it dumps). They do not key the
  cache; the key follows from what a job receives (G2). Targets may also carry the cross-workspace rule
  (open, below).
- **G11. Reproducible across machines.** The same checkout and the same command give the same
  configuration on any machine: every initial layer lives in the project or on the command line.
  Machine-local layers (system, user) are left out to start. If they are added, they threaten this goal
  (two developers with different user files would get different outputs); a likely rule then is that they
  may set only diagnostic and build-behavior settings.
- **G12. Resolve once, in the driver.** The driver resolves the configuration once per build. Each
  `nomu compile` job receives its resolved settings in its job file, which carries everything the job
  reads; jobs do no resolution of their own. A job receives `key: value` pairs and never a config name, so
  modules whose settings resolve identically under two configs share one cache entry.
- **G13. Binaries record their configuration.** A built program carries the configuration it was built
  with, readable after the fact, for bug and performance reports, for the harness to check that a binary
  matches the case that asked for it, and for reproducing a build.
- **G14. Runtime settings are baked in.** Settings with the `run` target are fixed at build time and stored
  in the binary; changing one means a new binary. Keeping those values in their own data object may make a
  change cost a relink alone. A program's behavior is then exactly what its recorded configuration (G13)
  says. Precedent for run-time overrides is wide (Go's `GOGC`/`GODEBUG`, JVM `-XX` flags, .NET
  `runtimeconfig.json`, OCaml's `OCAMLRUNPARAM`), almost all through environment variables or argv parsing.
  If deployed tuning becomes a need, GHC's model is the possible extension: `-with-rtsopts` bakes defaults
  and `-rtsopts=none|some|all` lets the build decide at link time how much override is allowed.
- **G15. Schema evolution.** A setting can be renamed or deprecated without breaking existing files, through
  aliases with a warning.
- **G16. Grouped names.** Settings are named `<topic>.<key>` (`gc.nursery_reserve`, `opt.inline`,
  `debug.dump_llvm`), so a large file reads as one section per topic. The target lives in the schema (G8,
  G10), which keeps a name stable when a setting's targets change; the G1 report can group by target. A large topic may later gain an optional third level (`<topic>.<group>.<key>`),
  with the schema deciding which topics have it.

  **Config selection.** Config names follow a section or key name, separated by spaces; several names mean
  any of them. Setting names contain no spaces, so the first word is always the name:

  ```yaml
  opt release:
    inline: true
  gc:
    collection_time debug: 60
    collection_time test release: 120
  ```

  A qualifier goes on a section or on a key, never both on one path (`opt release:` containing
  `inline debug:` is an error). Considered and set aside: parenthesized qualifiers (`opt(release):`) and a
  per-config section repeating the topic tree. Considered and set aside: `<topic>.<target>.<key>` (the
  middle segment mostly repeats the topic, and a multi-target setting has no single right segment),
  `<target>.<topic>.<key>` (splits one topic across sections), and free nesting (depth drifts).
- **G17. YAML.** Configuration files are YAML; nested maps read as the G16 sections, and CLI flags spell the
  same names dotted (`--gc.nursery_reserve=64M`). The YAML subset has no flow style beyond the empty map
  and list, so configuration files are block style throughout. Nomu's own YAML parser (a strict subset) is
  [200](200-yaml-parser.md); this design assumes it and leaves parsing out of scope. 198 depends on 200 and
  builds the file layers and the CLI layer together. The manifest's move to YAML is
  [163](163-manifest-yaml.md).
- **G18. Granularity.** Each setting declares the scope it varies over: `module` (may differ per module:
  optimizer switches, diagnostics), `program` (one value per linked binary, which every module must agree
  on: `gc.plan`, which changes barriers in every module, and the runtime settings baked into the binary),
  or `build` (one value per build: the cache location). Program and build settings may
  be set only in the builtin and workspace layers and on the CLI; a package or module file that sets one is
  an error. This restricts which layers may set a setting; it is still one stack and one walk.
- **G19. The builtin layer is viewable.** A user can print the builtin layer as a YAML file: every setting
  at its default, each commented with its meaning, type, allowed values, targets and granularity, plus the
  builtin config declarations. It is generated from the schema (G8), so it always matches the compiler.

## Requirements

- **Every workspace gets a configuration.** The entry workspace, pinned external workspaces and the
  language workspace each compile under a defined configuration. Today only the entry workspace sees the
  build's options (F4 below). External workspaces and the language workspace follow the CLI's selection
  when one is given, so `-c release` makes everything release and `-c debug` everything debug. With no
  `-c`, the entry builds under the subcommand default and externals build under `release`, since their
  code is not under development and fast dependencies are what most people want. Selection is CLI only
  (G4): no file selects a config for an external either. This avoids Cargo's default, where a dev build
  compiles every dependency unoptimized and users commonly add `[profile.dev.package."*"] opt-level = 3`
  to undo it. Precedent for scoping dependencies out by default: Go applies `-gcflags` to command-line
  packages unless `all=` is given, and Cabal's top-level `cabal.project` fields apply to local packages
  only. Building one external under a different config than the rest waits for finer overrides, which
  may come later.

  An external workspace's own `cfg.yaml` files apply when it is consumed, so library authors can ship
  tuned defaults. Its config declarations are invisible, so its qualifiers match only builtin names in the
  flattened list (G4); other names contribute nothing. With `production: release`, `-c production`
  flattens to `[release, production]`, and an external compiles under `release`. When no builtin name is
  in the list (`-c gc_fast`, where `gc_fast` has no parent), it compiles on the unqualified base.
  Consumers see a small surface: the builtin configs and their own.
- **Every current variable has a setting.** GC and memory tuning (collection stress, nursery size, mature
  floor, heap size), optimizer pass switches (inlining, escape analysis, scalar promotion,
  devirtualization) and debug output (collection logging, IR dumps) each get a name, a documented meaning
  and targets. Inventory (`git grep -o 'NOMU_[A-Z0-9_]*' -- src`): compile-time in `llvmgen`, `ssairpasses`
  and the driver: `NO_INLINE`, `NO_ESCAPE`, `NO_SCALAR`, `NO_DEVIRT`, `NO_INLINE_ALLOC`, `PTG_ESCAPE`,
  `PTG_PRECISE`, `DUMP_LLVM`, `DUMP_SSAIR_PASSES`, `TIME_CODEGEN`, `RT_PRELUDE`; program-start in
  `runtime.c`, mirrored into `runtime.nomu` globals: `GC_STRESS`, `NURSERY_RESERVE`, `MATURE_FLOOR`,
  `GC_TRIGGER_RESERVE`, `GC_DEBUG_PRESSURE`, `GC_PRESSURE`, `STW_SELFHOST`, `STW_COLLECT`, `CARRIERS`,
  `GC_DESC_SIZE`; build: `NOMU_CACHE_DIR`. The suite harness translates its settings to variables in
  `src/compiler-test/sources/Settings.swift`.
- **Outputs keyed by configuration.** Builds of one module under different configurations land in different
  output locations, and the driver reports where the binary is. The harness uses the reported path. 176.5.7
  ships a quick version of this; this task replaces it.
- **Parallel compiles of one module again.** 176.5.7's quick version gives each configuration its own binary
  by compiling configurations of the same fixture one after another and copying each binary out. Once
  outputs are placed by configuration, the harness compiles them in parallel again and drops the copy.
- **User surface.** The config names, setting names and spelling users see, decided once for `build`, `run`,
  `test` and `compile`, including how a package or workspace sets defaults.

## Open questions

- **Output path naming.** Builds under different configurations need different output locations. Bazel
  names its output directories after the configuration (a path must be known when actions are planned,
  and a readable name helps debugging), and later added trimming and path mapping for the cost. Lean: follow
  Bazel once incremental caching (172) lands, likely with declared outputs that are cached and undeclared
  outputs left in `build/` for debugging; settled together with 172 and Bazel friendliness.

## Background

Today these settings are environment variables read in several places: optimizer switches in
`LLVMBridge.swift` (`NOMU_NO_INLINE`, `NOMU_NO_ESCAPE`, `NOMU_NO_SCALAR`), prelude and debug switches in the
driver and egress, and collector settings in the runtime at program start (`NOMU_GC_STRESS`,
`NOMU_NURSERY_RESERVE`, `NOMU_MATURE_FLOOR`, `NOMU_GC_DEBUG_PRESSURE`). Which stage reads which variable is
undocumented, the host cache does not see the compile-time ones, and two builds of one module under
different settings write the same output path. The integration suite works around all of it by setting
variables per case.

**Options reach only the entry workspace (190.6 F4).** The driver gives a job the build's `EmitOptions`
only when its module is in the entry workspace; every other job gets defaults (`Driver.swift`, the job loop
in `compile`). So `-O` builds the program at O2 over a debug-compiled `std`, `core` and `runtime`, and
`--mono` reaches the entry workspace only. `EmitOptions` mixes settings of three kinds, which the design
separates: output-affecting for every job (`optimize`, `mono` as `effectiveMono`), entry-scoped
(`allowCoreImport`, `subsetFuncs`, the `--emit-*` dumps, `stopAt`), and per job (`compilingPrelude`).
Accepted until this task:
- No correctness hazard. Optimization and the mono dial change performance only, and modules built under
  different settings interoperate by design; the frame index keeps only the records of the copy the linker
  kept (195). The language workspace is always built one way, so its cache entry is never stale, and no
  module under `build/` is reused across invocations (only host-cache jobs are).
- Every release performance figure so far includes a debug `std`, `perf-tier.py` results included.
- A release program over a release `std` has never been built; it needs a full-tier run when this lands.

## Relationships

- **176.5.7** (the shape matrix in the suite) needs per-configuration outputs now and builds a quick version;
  its harness names settings by meaning, so moving them from variables to the configuration changes the
  harness's translation and leaves the manifest as it is.
- **190** (explicit module builds) owns the driver, the plan and the host cache this task extends; its F4
  moved here.
- **172** (incremental build cache) depends on this task: its key takes the configuration's canonical form.
- **155** (the integration-suite harness) is the main consumer.
- **200** (YAML parser) is a prerequisite: configuration files are read with it (G17).
- **163** (manifest format, JSON to YAML) also depends on 200; manifests and configuration files share the
  format.
