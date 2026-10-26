# Build configuration — every build and runtime setting part of one configuration system

**Avenue:** Infra · **Type/Lifecycle:** `driver · runtime · design` · **Size:** L · **Status:** done
(198.1–198.7); the rest of the configuration story is [205](205-config-upgrades.md) · **Source:** the 176.5.7 harness design, which needs GC and memory behavior varied per test run and
found it reachable only through environment variables; [190](190-explicit-module-builds.md) 190.6 F4
(build options reach only the entry workspace).

## Deliverable

A designed and built configuration system. A **setting** is one knob that changes what the compiler emits or
how a built program behaves (GC, memory, optimizer passes, diagnostics). A **config** is a named, declared set of
setting values (`debug`, `release`, `test`, or a user's own such as `production`). A **configuration** is
what resolution produces: the full set of settings in force for one module's compile, one link or one run.
Values come from the builtin defaults and the workspace, package and module files; the command line only
selects configs. Ambient environment variables stop changing results.

## Design goals

- **G1. Observable resolution.** Every build writes a configuration record next to its outputs, so any
  artifact or log can be traced to the settings that produced it. The record is a read-only YAML document
  for debugging, read mostly by agents; reproducing a build goes through the source revision it names. It
  lists what resolution read, each layer once with exactly what it declared:

  ```yaml
  command: nomu build -c production
  compiler: 3f9a2c1
  source: 7a37071
  active:
    acme.app:
      - release
      - production
    externals:
      - release
    language:
      - release
  builtin:
    oven.temp: 180
    oven.temp release: 220
    dough.flours:
      - wheat
  workspaces:
    acme.app:
      oven.temp production: 230
      dough.flours:
        - rye
    acme.json:
      oven.temp release: 190
  packages:
    acme.app/net:
      oven.temp: 200
      oven.temp release: 210
  modules:
    acme.app/net/tls:
      dough.flours:
        - spelt
  externals:
    all:
      oven.mode: bake
    json:
      dough.proof: false
  ```

  The top level is a fixed schema. `source` is the project's revision, marked when the working tree has
  uncommitted changes. `active` gives the flattened config list (G4) for the entry workspace, the
  externals and the language workspace. The layer sections run weakest first, keyed by workspace
  identity (`scope.name`), package path, module path, or, under `externals`, `all` and pin alias (G20);
  a layer that declares nothing is left out, and `builtin` lists every setting. Declaration keys are flat,
  `<setting>( <config>)*`, the setting first as in G16, so a search for a setting finds every declaration
  of it. Values are spelled as a file would write them (`64M`), and keys are written in a fixed order so
  the record is deterministic. The lookup rule: a module's value comes from the first layer that declares
  the setting, checked module, package, workspace, then builtin, with an external's `externals` entries
  (alias, then `all`) above its own layers; a qualified declaration counts when it names a config in its
  workspace's list, the latest such config winning within a layer; an appending list joins every layer's
  value, weakest first (G9). How `nomu` shows resolution to users moved to
  [205](205-config-upgrades.md); `cfgresolver` prints the record today.

  Considered and set aside: every setting listed per module with every layer that declared it (size grows
  with modules times settings); one entry per distinct stack with final values and their declarations (the
  entries need explaining, and a shared file's declarations repeat in each); a dense binary format that
  `nomu` expands (unreadable without a matching compiler, which an old log or binary may not have); a
  `kind` field per layer (two extra lines per layer, values a level deeper); a config subcommand (the flag
  covers it). The record is not meant to resemble `cfg.yaml`; it needs only to be clear and parseable.
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
  `builtin < workspace < package < module`. The module is the finest layer, so module-level
  overrides are possible; it is also the compilation and cache unit, which is why no file layer exists.
  The command line sets no values (G6). An external workspace's stack adds two layers the entry
  workspace writes, strongest of all (G20). Layers are generic
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
- **G6. Files only.** Every value is written in a file; the command line carries only config selection
  (`-c`/`--config`, repeated or comma-separated, the value after a space or `=`). The CLI is driven by
  tools and agents more than by people, and a value in a file is explicit, reviewable and reproducible.
  To vary a setting, declare a config that sets it and select it. The compiler, the driver and built
  programs read no `NOMU_*` environment variables, so a variable in a developer's shell cannot change a
  build or a run. Considered and set aside: setting flags (`--gc.nursery_reserve 64M`), which needed their
  own syntax for every type, lists and bools, and gave the same build two spellings.
- **G7. Plain data.** Configuration files, config declarations included, are static data that a tool can
  read without running anything, as `modules.md` §Manifest already requires of manifests. A config is
  declared values; Bazel's Starlark transitions are the contrast.
- **G8. One typed schema.** Each setting is declared once, with a name, type, allowed values, default, doc
  string, target set (G10), granularity (G18) and, for list- and map-valued settings, a merge rule
  (replace by default; append when the schema says so). File validation, docs and the G1 record all come from that
  declaration. An unknown setting name or a bad value is an error. The schema for built-in settings lives
  in the compiler, which reads them; user files set values and define bundles.
- **G9. Deterministic, conflict-checked resolution.** The same inputs always produce the same
  configuration. The order of declarations never matters; Bazel's in-place
  `--config` expansion, where position decides, was set aside. The one deliberate exception is the order
  of selected configs: in the flattened list (G4) a later config beats an earlier one, so
  `-c gc_fast -c small` and `-c small -c gc_fast` can differ, and the G1 record shows the list in order.
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
  runtime, so it declares `[compile, run]`. Targets document a setting and tell the
  driver which jobs receive it (a diagnostic dump reaches only the jobs it dumps). They do not key the
  cache; the key follows from what a job receives (G2). Targets may also carry the cross-workspace rule
  (open, below).
- **G11. Reproducible across machines.** The same checkout and the same command give the same
  configuration on any machine: every initial layer lives in the project.
  Machine-local layers (system, user) are left out to start. If they are added, they threaten this goal
  (two developers with different user files would get different outputs); a likely rule then is that they
  may set only diagnostic and build-behavior settings.
- **G12. Resolve once, in the driver.** The driver resolves the configuration once per build. Each
  `nomu compile` job receives its resolved settings in its job file, which carries everything the job
  reads; jobs do no resolution of their own. A job receives `key: value` pairs and never a config name, so
  modules whose settings resolve identically under two configs share one cache entry.
- **G13. Binaries record their configuration.** A built program carries the short form of its build's
  configuration record (G1), the compiler and the active configs, readable after the fact, for bug and
  performance reports and for the harness to check that a binary matches the case that asked for it. With
  the project's revision, the short form gives back every value; the full record lives next to the outputs.
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
  G10), which keeps a name stable when a setting's targets change. A large topic may later gain an
  optional third level (`<topic>.<group>.<key>`), with the schema deciding which topics have it.
  `configs` and `externals` are top-level keys of `cfg.yaml`, so no topic takes either name.

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
- **G17. YAML.** Configuration files are YAML; nested maps read as the G16 sections. The YAML subset has no flow style beyond the empty map
  and list, so configuration files are block style throughout. Nomu's own YAML parser (a strict subset) is
  [200](200-yaml-parser.md); this design assumes it and leaves parsing out of scope. 198 depends on 200.
  The manifest's move to YAML is
  [163](163-manifest-yaml.md).
- **G18. Granularity.** Each setting declares the scope it varies over: `module` (may differ per module:
  optimizer switches, diagnostics), `program` (one value per linked binary, which every module must agree
  on: `gc.plan`, which changes barriers in every module, and the runtime settings baked into the binary),
  or `build` (one value per build: the cache location). Program and build settings may
  be set only in the builtin layer and the entry workspace's `cfg.yaml`; a package or module file, an
  external workspace's file, or an `externals:` block (G20) that sets one is an error, so every module
  of a program agrees by construction. This restricts which layers may set a setting; it is still one stack and one walk.
- **G19. The builtin layer is viewable.** A user can print the builtin layer as a YAML file: every setting
  at its default, each commented with its meaning, type, allowed values, targets and granularity, plus the
  builtin config declarations. It is generated from the schema (G8), so it always matches the compiler.
- **G20. The entry workspace sets values for externals.** A user config's values would otherwise reach
  only the entry workspace: an external's stack holds its own files, and its config list is cut to
  builtin names (G4). So the entry workspace's `cfg.yaml` may hold an `externals:` section, keyed by pin
  alias from its `nomu.yaml`, plus the reserved key `all` for every external workspace, transitive ones
  included:

  ```yaml
  configs:
    no_inline: debug
  externals:
    all:
      opt no_inline:
        inline: false
    json:
      opt:
        inline: true
  ```

  Under each key, the G16 syntax applies. An external's stack is then
  `builtin < its workspace < its packages < its modules < entry all < entry <alias>`: the entry has the
  final say over its build, and a specific alias beats `all` by layer order, so "everywhere except
  `json`" can be written and the G1 record lists both declarations. Qualifiers in these
  blocks are the entry's: they are checked against the entry's configs and match the entry's full list,
  so `-c no_inline` applies there though the external never declared `no_inline`. An alias names a direct
  pin only; reaching a transitive external by name (its `scope.name`) waits for a need. `all` excludes the
  language workspace, so `std`, `core` and `runtime` build only under builtin-config values: a small fixed
  set of variants, each cacheable and prebuildable. `externals:` blocks set module settings only (G18).
  `all` is reserved: no workspace is named `all` and no pin is aliased `all`. Only the entry workspace's
  `externals:` section applies; an external's own is ignored when it is consumed. Considered and set aside:
  a single block for all externals (no per-external value), per-alias blocks alone (repetitive for
  "everywhere"), an error when `all` and an alias overlap (cannot say "everywhere except"), and entry
  values reaching the language workspace (gives `std` unbounded variants).

## Requirements

- **Every workspace gets a configuration.** The entry workspace, pinned external workspaces and the
  language workspace each compile under a defined configuration. Today only the entry workspace sees the
  build's options (F4 below). External workspaces and the language workspace follow the CLI's selection
  when one is given, so `-c release` makes everything release and `-c debug` everything debug. With no
  `-c`, the entry builds under the subcommand default and externals build under `release`, since their
  code is not under development and fast dependencies are what most people want. (Interim: they build
  under `debug` until 172, since without the build cache an optimized external recompiles on every build;
  `CompilerSettings.externalDefault`.) Selection is CLI only
  (G4): no file selects a config for an external either. This avoids Cargo's default, where a dev build
  compiles every dependency unoptimized and users commonly add `[profile.dev.package."*"] opt-level = 3`
  to undo it. Precedent for scoping dependencies out by default: Go applies `-gcflags` to command-line
  packages unless `all=` is given, and Cabal's top-level `cabal.project` fields apply to local packages
  only. Building one external under a different config than the rest waits for finer overrides, which
  may come later; its values can already differ (G20).

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

## Phases

The machinery is built and proven first, on test settings and temporary compiler sentinels, while every real
setting keeps its current path. Real settings then move over one at a time (198.6, 198.7), each decided
(name, type, default, targets, granularity, builtin config values) as it is threaded through, since gotchas
show up per setting. The open choices fall to the phase that meets them: value types in 198.1, the binary
record in 198.4, interim output paths in 198.5.

**Scope.** 198 carries the minimum that [172](172-incremental-build-cache.md) needs: every input that
changes a compiled object reaches the job file, so a cache keyed on jobs never serves an object built under
other settings. The rest of the configuration story (showing resolution to users, the builtin file,
provenance in the binary, runtime settings off environment variables) is
[205](205-config-upgrades.md).

- **198.1** Configuration library (`src/config`) and resolver. The schema is an input: the library has no
  settings of its own, and the compiler's schema is one user of it. Setting declarations (G8), the layer
  stack (G5), config declarations and flattening (G4), qualifiers (G16), precedence and conflicts (G9),
  granularity rules (G18), merge rules, provenance (G1). Unit tests against a test schema.
  *Done:* `src/config` (34 tests, against the bakery schema below). Decided:
  - **Value types:** `bool`, `int` (optionally ranged), `size`, `choice` (a fixed set of names), `string`,
    and `list` of a scalar type. Maps wait for a setting that needs one. YAML values keep their Core types,
    as the YAML decoder reads them (`shop.name: 42` is an error whose fix quotes it).
  - **Sizes:** a non-negative byte count, or digits with `K`, `M`, `G` or `T`, each a power of 1024
    (`64M`). The canonical form is the byte count, so `64M` and `67108864` key the cache alike.
  - **Append merge:** each layer contributes its winning declaration's list, weakest layer first; within
    one layer, only the winner counts, as for any setting.
  - **Qualifiers** are checked against the config table of the workspace whose files declare them, and
    match against the flattened list passed in. For an external workspace, the driver passes its own table
    and the list cut to builtin names, so its own config names are valid and match nothing.
  - **Canonical form:** `name=value` lines sorted by name; strings quoted, so a value never holds a line
    break. A job file can carry a subset (the settings that job receives).
  - **Errors** are values with stable codes; every error in a step is reported, and a file error renders as
    `file:line:col: error: …`.
- **198.2** File layers and selection: `cfg.yaml` read through `YAMLDocument`, `-c`/`--config` through
  `src/cli`, the `externals:` section with its two layers (G20), and `all` rejected as a workspace name
  or pin alias. Plus `cfgresolver`, a small tool with its own fixed schema that reads a fixture directory
  tree of `cfg.yaml` files and a config selection and prints the configuration record (G1), one module's
  final values, or the G19 dump; golden tests over its output cover selection, layers, qualifiers,
  conflicts, the `externals:` layers, the record and the dump. Its schema is a made-up bakery, so goldens read like real files
  and never change with the compiler's settings:
  - `oven.mode`: choice of `bake`/`broil`/`convect`, module
  - `oven.temp`: int, module
  - `dough.proof`: bool, module
  - `dough.flours`: list of strings, append merge, module
  - `pantry.capacity`: size, program
  - `shop.name`: string, program
  - `shop.ledger`: string, build

  *Done:* `ConfigFile` reads a `cfg.yaml`; `BuildConfiguration` takes every workspace's files, the pins and
  the selection, checks every file once in the scope it resolves in, and gives each module its stack and
  configuration; `record`, `values` and `Schema.builtinFile` write the three outputs; `selection` reads
  `-c` values. `cfgresolver` (`src/config/cfgresolver`) reads a fixture tree the way a build does
  (`nomu.yaml`, `pkg.json`, `.nomu` files, pins followed transitively) with 10 golden cases; the planner
  rejects `all` as a workspace name or pin alias. 58 library tests. Decided along the way:
  - **Program and build settings** resolve once, over the builtin layer and the entry workspace's file
    under the entry's list, and every module, external or language, takes those values.
  - **The language workspace** resolves under the externals' list and takes no `externals:` block.
  - **Errors come in stages:** YAML errors first, then each file's shape (keys, sections, qualifiers),
    then resolution, where every problem across all files is reported together. A later stage runs only
    when the earlier ones found nothing.
  - **A `cfg.yaml` in a directory that is no workspace, package or module root** is an error.
- **198.3** The driver resolves once per build (G12); job files carry resolved values in canonical form and
  key the cache (G2); externals and the language workspace follow the CLI's configs, else `release`. Proven
  on a temporary compiler sentinel, `sentinel.module_tag` (string, compile, module), written by the
  compiler into each module's object as a marker global.
  *Done:* the compiler's schema is `src/settings` (`CompilerSettings`, with `JobSettings` reading what a
  job received). `build` reads the module table, resolves the configuration (`BuildConfig.swift`), then
  plans: the language workspace's compile settings, in canonical form, enter its host-cache key. Each job
  carries `settings`, the canonical values of the settings whose targets include `compile`; `nomu compile`
  reads them from the job file alone. `-c`/`--config` reaches `build`, `run` and `test` (default `debug`,
  `test` for `test`). A non-empty sentinel tag becomes `__nomu_marker.sentinel.module_tag` in the object,
  kept by `llvm.compiler.used`. Build tests cover an entry, an external with its own file and the entry's
  `externals: all` block, the language workspace's cache entry shared across selections, and errors
  stopping the build before any compile; the suite passes unchanged. Decided along the way:
  - **Files read:** the `cfg.yaml` at each workspace root, and at the package and module roots of modules
    the build reaches; a file elsewhere is not read by a build (`cfgresolver` reports it).
  - **The job's settings:** a job receives the settings whose targets include `compile`. A setting a job
    reads but did not receive reads as its default.
  - **Unchanged until 198.7:** `-O`, `--mono` and the dumps still reach only the entry workspace's jobs
    through `EmitOptions` (F4); the language workspace's key changes once, since its canonical settings
    now enter it.
- **198.4** Runtime settings baked into the binary (G14) and the binary's configuration record (G13).
  Proven on a temporary sentinel, `sentinel.program_tag` (string, compile and run, program).
  *Done:* at link time the driver emits a settings object, one exported constant per `run` setting, and
  the runtime reads each through an `extern` declaration (`nomu_setting_sentinel_program_tag`). The
  record's short form goes in the binary's `__TEXT,__nomu_config` section through the linker's
  `-sectcreate`. The sentinel lands in every object as a marker, the language workspace's included, and the
  runtime prints a non-empty tag at startup. A build test covers both selections, the markers, the
  language workspace's second cache entry, and the section; the suite passes unchanged. Decided along the way:
  - **Typed globals:** the produced binary parses nothing at startup. A setting is an `int64_t` (int,
    size), a `uint8_t` (bool) or a NUL-terminated `const char[]` (string, choice); lists wait for a run
    setting that needs one. The symbol is the name with each `.` as `_` under `nomu_setting_`, checked
    unique. A runtime declaration the driver does not emit fails the link.
  - **Run settings are program settings:** the schema rejects a `run` setting of any other granularity,
    since a program has one runtime.
  - **The record in the binary** is the short form: `compiler` and `active`. `command` and `source` stay
    out, so the same checkout and selection give the same binary (G11). (`source` is deterministic for a
    checkout, so adding it later keeps G11; that and the full record are 205's.)
  - **A section** keeps the record out of the symbol table, so `-dead_strip` and `-x` leave it alone, as
    with the frame index.
- **198.5** Outputs placed by configuration (interim naming until 172).
  *Done:* a build's outputs go under `build/<configs>/`, the entry's active list joined with `-`
  (`build/debug/`, `build/debug-tagged/`), externals' under `build/<configs>/_external/`; the language
  workspace stays in the host cache. The planner takes the directory as `PlanOptions.outputConfig`. The
  harness copies the binary from the path the build reports (`--report-jobs`) instead of computing it;
  `tools/escape-diff.sh` and `tools/perf-tier.py` look under `build/debug/`. A planner test and the build
  tests cover two configurations' outputs side by side; the suite passes unchanged. Decided along the way:
  - **Naming:** the quickest correct choice, since 172 replaces the layout (its doc records the direction).
    The same files and list always resolve the same values, so the name is enough; two selections that
    resolve alike build separately. Config names are words, so the `-` join is unambiguous and never meets
    `compiler-test` or `_external`.
- **198.6** The optimization level and mono become settings, reaching every job, the language workspace's
  and externals' included (closes 190.6 F4).
  *Done:* `opt.level` (choice `none`/`o2`, default `none`, `release`: `o2`) and `opt.mono` (choice
  `none`/`edge`/`all`, default `none`, `release`: `all`), both compile-target module settings, replace
  `EmitOptions.optimize`, `mono` and `effectiveMono`; each job reads them from its settings, so externals and
  the language workspace follow `-c release` (closes 190.6 F4). `-O`/`--release` and `--mono` are gone. The
  suite's `optimize` leg passes `--config=release`; its seven `--mono` cases select `mono_all` or `mono_edge`,
  configs declared in the repository's new root `cfg.yaml`. `tools/perf-tier.py` passes `-c release`. A
  build test checks the app, an external, `std/prelude` and `runtime` get `none`/`none` with nothing selected
  and `o2`/`all` under `-c release`, in a second language-workspace cache entry. The suite passes on both
  tiers (318 fast, 729 full). Decided along the way:
  - **Externals default to `debug`** until 172 (above, under Every workspace gets a configuration).
  - **No derived default:** mono no longer follows the optimization level; `release` sets both, so a file
    that sets only `opt.level: o2` keeps mono `none`.
  - **The CLI carries only `-c`:** `-c release` replaces `-O`; mono is set in a `cfg.yaml`.
- **198.7** The other inputs that change compiled objects become settings: the optimizer gates read from the
  environment in `LLVMBridge` (`NOMU_NO_INLINE`, `NOMU_NO_DEVIRT`, `NOMU_NO_ESCAPE`, `NOMU_NO_SCALAR`,
  `NOMU_PTG_ESCAPE`, `NOMU_PTG_PRECISE`), `NOMU_NO_INLINE_ALLOC` in codegen and `NOMU_RT_PRELUDE` in the
  driver. The harness's compile legs (`release`, `noinline`, `escape: false`, `rt_prelude`) move to configs
  declared in the repository's root `cfg.yaml`; its run legs keep their environment variables, which change
  no object (codegen loads the GC values at run time), so the GC legs still share one binary. The
  sentinels come out. 198 closes here.
  *Done:* `opt.devirt`, `opt.inline`, `opt.escape`, `opt.scalar`, `opt.inline_alloc` (bools, default
  `true`), `opt.escape_provider` (choice `legacy`/`graph`/`graph_precise`, default `legacy`) and
  `test.runtime_prelude` (bool, default `false`), all compile-target module settings. `emitObject` takes
  them as `OptimizerSettings`; no environment variable that changes an object is read any more. The root
  `cfg.yaml` declares parentless configs that each set one setting, so they combine (`-c release -c
  no_escape`): `no_devirt`, `no_inline`, `no_escape`, `no_scalar`, `rt_prelude`, `mono_all`, `mono_edge`.
  The harness selects them for its compile legs (`--config=no_escape`); `tools/escape-diff.sh` and
  `tools/perf-tier.py` select them too, perf-tier reading each binary's reported path. The sentinels, the
  object markers and the runtime's sentinel read are gone; the settings object is still linked, empty until
  a run setting moves (205.5), and the binary still carries its `__nomu_config` section. The build tests
  check per-module values, the `externals: all` block and the shared language-workspace entry through
  `--emit-jobs` job files, and the binary's record under `debug` and `release`. The suite passes on both
  tiers (729 full); `escape-diff.sh` finds 89 identical, none differing. Decided along the way:
  - **One provider choice:** `NOMU_PTG_ESCAPE` and `NOMU_PTG_PRECISE` became one choice, since the precise
    query exists only on the graph.
  - **Parentless configs as mixins:** each suite config sets one setting and has no parent, so a selection
    combines them freely. A selection of only mixins (`-c no_escape`) carries no builtin name, so externals
    take the unqualified base, which is `debug`'s values today.
  - **Debug-output switches stay environment variables:** `NOMU_DUMP_LLVM`, `NOMU_DUMP_SSAIR_PASSES` and
    `NOMU_TIME_CODEGEN` write diagnostics and change no object.

## Open questions

- **Output path naming.** Interim: `build/<configs>/` (198.5). Settled in 172, likely following Bazel; its
  doc holds a starting sketch (hash-named artifacts in the host cache, symlinked into `build/`) and the
  questions it raises.

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
