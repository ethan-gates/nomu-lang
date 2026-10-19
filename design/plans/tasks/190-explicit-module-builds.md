# Explicit module builds — dependency scan + build plan

**Avenue:** Infra · **Type/Lifecycle:** `infra · needs-design` (driver + build orchestration) · **Size:** L ·
**Status:** in-progress — D1–D9 decided (§Decisions); 190.1–190.5 done; 190.6 (follow-ups) remains. · **Source:** found closing
[174](174-prelude-as-packages.md): the embedded `std` package compiled `std/prelude` twice per build.

## Deliverable

A split between the compiler and the driver, in the Swift explicit-module-build model.

- **The compiler** (one job) compiles one module: its source files, the artifacts (`.nmi`, `.bir`) of the
  modules it depends on, its implicit imports and its options, into one output directory. It knows nothing
  of workspaces, packages, manifests or discovery, nor where its dependencies came from.
- **The driver** owns workspaces, packages and manifests. It scans the build's imports up front, plans one
  fine-grained graph whose nodes are individual modules (plus the runtime archive and the link), and
  picks the next ready node to run. Every workspace takes the same path, whether it is the one the build
  started in, a pinned external one or the embedded `nomu` one. A workspace differs only in data: where its
  sources come from (disk, or materialized from the compiler's embedded sources) and where its outputs go
  (D2, D4). No workspace builds as one unit.

**Invariant:** when a job runs, every module it imports is already built and its artifacts are handed in.

## Why

- **Separation of concerns.** Today `compile()` both discovers the graph and compiles it, and two nested
  builders (`compileNomuWorkspace`, `buildExternalWorkspace` from [188](188-multi-local-workspace-builds.md))
  call `compile()` recursively, each planning only its own workspace. That shape compiles `std/prelude`
  twice per build (`std/time` imports `pkg/prelude`), rebuilds sibling products of an external workspace,
  and builds and links whole workspaces whether anything imports them or not.
- **A granular graph.** Module-level nodes with declared inputs and outputs let the driver choose what to
  run next: in order (D1) first, then threads ([191](191-threaded-job-execution.md)), skipping unchanged
  modules ([172](172-incremental-build-cache.md)), or Bazel actions ([192](192-bazel-friendliness.md)).

## Shape

1. **Scan.** The driver needs the graph's edges before any job runs, and the full parse lives inside the
   compiler, so the driver reads each file's import block with a scanner. Imports precede every declaration
   (the parser enforces it), so the scanner lexes a file until the first token that starts no import and
   stops. The implicit `import std` is added here, so `std/prelude` is an ordinary graph node.
2. **Plan.** Resolve the scanned imports into one module graph, one canonical ID per module (its origin).
   Every check over the workspace and package model happens here: unresolved imports, product gates, the
   `dependencies` allow-list, package and module cycles, reserved package names, the path-component rule,
   and the `core` import gate (190.1). The output is a job list in dependency order. A job is a
   serializable value: its source files, its dependencies' artifacts, its implicit imports, its options
   (library or binary, runtime-subset by membership, the mangling workspace identity, white-box interface for a
   `test import` target) and its output directory.
3. **Execute.** Run each job after its dependencies. A missing dependency artifact is a planner bug,
   reported as one.
4. **Link.** The final job links every object the plan produced.

**The plan holds exactly the reachable modules, and the link takes every object the plan built.** A module
enters the build only when something imports it. `std/prelude` is always a node through the implicit import;
the embedded `runtime` package always is (`std` and generated code call its functions by bare name, so
nothing imports it); and the runtime archive always is, since every binary links it. There is no separate link-selection step.
This replaces today's over-linking of all of `std` and of every product (plus `__mod_*` intermediate) of a
pinned workspace.

## Phases

- **190.1 — one implicit import; `core` behind `std`.** **Done** (suite 156/156). `core` stops being ambient: the ambient
  visibility (`ambientModules`) and the term go away, and `import std` (resolving to `std/prelude`) is the
  only implicit import. Only `std`'s modules may import `core`; the planner rejects an import of `core`
  from anywhere else, so users reach `core` only through `std`. Where codegen needs `core`'s interface in a
  module (`ManagedBuffer` instantiations such as heap `String` storage), the driver hands it in as a
  dependency, without putting `core`'s names in scope. The fixtures that name `ManagedBuffer` from user
  code (`prelude_core_ambient`, `managed_buffer_scalar_ref_bad`) keep testing it directly through a hidden
  driver flag that lifts the `core` import gate (e.g. `--allow-core-import`, undocumented, for the suite
  only): each gains `import core`, and its suite entry passes the flag through `compile_args`. Codegen in a
  user module needs no `core` interface: heap `String` allocation lowers to the runtime's
  `__stringAllocHeap`, and only source that names `ManagedBuffer` resolves it. Covered by `core-import`
  (the gate lifted) and `core-import-rejected` (the gate's error); `examples/managed_buffer*` also take the
  flag. The gate sits in `resolveImport` until the planner (190.3) takes it.
- **190.2 — scanner.** **Done** (`ImportScanner`, 13 unit tests). The `scanner` sub-target (D5, `//src/planner/scanner`): header-only import scan per file (D3), returning each
  file's raw imports with offsets and line/column, plus errors as data. Its own byte-level recognizer
  (whitespace, `//` comments in any UTF-8, ASCII identifiers, `/`; a non-ASCII character elsewhere is the lexer's error, at the lexer's position), with no dependency on the compiler's lexer or parser. Reads
  only a file's header (one small `pread`, extended only when the import block runs past it), on raw bytes
  with POSIX I/O. API: `scan(path)` over a public pure core `scan(bytes)`; a batch form comes with 191.
  Guarded by a conformance test: for every fixture, example and embedded source (`core`, `runtime`, `std`)
  that parses cleanly, and for UTF-8 header comments, the scanner's imports, offsets and line/column equal the parser's (corpus through the
  root `//:nomu_source_corpus` filegroup). Not yet wired into the driver; 190.3 is its first consumer.
- **190.3 — planner.** The `planner` component (D5), complete and tested on its own before the driver uses
  it (D7). It plans one graph across every workspace the build reaches (the building one, pinned ones and
  their own pins, the embedded `nomu` one), keyed per D6, and places every job's outputs per D2 and D4.
  Discovery, resolution and the checks above move out of `Driver.swift` into it. Each directory is listed
  once per build (the registry walk records each directory's `.nomu` files), and manifests and workspace
  names are read once per build. Embedded sources come through the source-provider interface (D5) and are
  scanned from memory. Per-step timings (registry, listings, scan, resolve) replace today's discovery
  timing. The whole reachable graph is planned before the first job runs, so planner errors precede any
  compile; streaming plan and execution is revisited with 191. Planner errors render as
  `file:line:col: error: message`. Tested against expected plans, without compiling.
  - **190.3.1 — workspaces.** **Done** (`WorkspaceSet`, 11 unit tests). The `//src/planner` target and the source-provider interface (disk, and
    embedded from `EmbeddedSources`). Loading each `nomu.yaml` once: `scope` and `name` validated (D6),
    pins followed at any depth, identity clashes reported. One walk per workspace that lists each
    directory once, recording packages and every directory's `.nomu` files; the manifest cache. The
    repository's and the fixtures' `nomu.yaml` gain `scope:`, and `nomu-lang` becomes `nomu_lang`.
    As built: pin aliases follow the path-component rule; the walk follows no directory symlink (a
    symlinked file counts as a file); a build with no `nomu.yaml` above its entry is a loose workspace
    with the fixed identity `local.main`, rooted at the entry's package; the embedded workspace's
    identity is `nomu.nomu`, and its package list moved from the driver into the planner
    (`EmbeddedWorkspace`), which the driver now materializes from.
  - **190.3.2 — resolution.** **Done** (`ModuleTable`, 11 unit tests). Scanning every reachable file, plus the implicit `import std`. Every import
    form (`pkg/…`, bare package, alias-qualified, external through pins, `std`, `core` behind its gate and
    the planner option that lifts it) and the product, `dependencies`, and same-package `test import`
    checks. Output: the module table and collected diagnostics.
    As built: modules are keyed `ModuleKey` (workspace identity + workspace-relative path) and resolved
    breadth-first from the entry; error messages match the driver's. The implicit `import std` applies to
    every file outside the embedded workspace, pinned workspaces included (today a pinned workspace's
    modules compile without it; that changes when 190.4 runs the plan). The embedded `std` manifest lists
    `core` in `dependencies`, so `std`'s access to `core` goes through the ordinary allow-list. An import
    naming only a pin alias (`import wsa`) is an error asking for a package.
  - **190.3.3 — the plan.** **Done** (`Plan`, 9 unit tests). Module and package cycle checks, job order, output directories (D2, D4), the
    D4 cache key with the git-commit stamp, the runtime-archive node and the link node.
    As built: `Plan(entryFiles:options:)` loads, resolves and plans in one call; with any error the plan
    holds no jobs. Jobs are ordered depth-first from the entry; a cycle is reported at the import that
    closes it. A module job's outputs share its leaf name as stem (a workspace-root module takes the
    workspace's name); the runtime archive goes to `<cache root>/runtime/<key>/nomu-runtime.a`. The
    commit stamp is `//src/buildinfo` (`BuildInfo.gitCommit`, from `tools/workspace_status.sh` through
    `.bazelrc`); the driver passes it as `PlanOptions.compilerIdentity` in 190.4. The runtime-archive key
    and host helpers moved from the driver to `HostCache`, which the driver now uses. Found on the way: two
    compiles publishing the runtime archive at once could leave its path briefly missing (delete, then
    move); publishing is now one atomic `rename`.
  - **190.3.4 — timings and cross-check.** **Done** (`PlanTimings`; `//src/driver:discovery_crosscheck_tests`). Per-step timings, and a test that plans every suite fixture and
    checks the planner's modules and edges against the driver's current discovery, before 190.4 replaces
    one with the other.
    As built: `Plan.timings` gives exclusive seconds per step (workspaces, registry, listings, scan,
    resolve, plan) plus directories listed, files scanned and modules. The cross-check runs the driver's
    discovery (through a temporary `EmitOptions.discoveryObserver`, removed in 190.4) and the planner on a
    copy of every suite fixture: 112 accepted fixtures match module for module and import for import, and
    for the 7 rejected ones every planner error is one the driver reports (or the fixture's expected
    error, where the driver stops before discovery). Fixed on the way: the planner missed a reserved name
    on the entry's own package; the `core` gate walked the whole workspace for a `core` package (as the
    driver does) and now checks the importer's `dependencies` instead; the cache keys hashed every
    embedded source on every plan and now hash them once per process. Planning the whole suite takes
    about 57 ms summed in a debug build (670 directories listed, 303 files scanned, 298 modules).
- **190.4 — the driver runs the plan.** Two components with one boundary between them:
  - **`compile()` is one module's compilation and nothing else.** It takes a value describing one module's
    inputs and expected outputs, and never sees the plan, the planner, workspaces or manifests:
    - the module's identity (its mangling origin) and source files;
    - each import of each file, mapped to the dependency it names;
    - the artifacts (`.nmi`, `.bir`) of every dependency it can see: its direct imports, their re-export
      closures, and the modules whose types their signatures name (Swift's explicit module map), read from
      disk only;
    - its package identity (for `package` visibility) and whether it is a product (may carry `public`);
    - its options: library or binary, white-box interface, runtime subset by membership, emit flags;
    - its output paths (`.o`, `.nmi`, `.bir`, and the binary for a binary job).
    The existing `compileModule` body becomes this function; its reads of the build-wide state (`interfaces`,
    `moduleHome`, `resolveImport`) become reads of its inputs.
  - **The driver orchestrates.** It asks the planner for the plan, turns each job into `compile()`'s inputs,
    runs the jobs in order (D1), builds the runtime archive, and links. Discovery, the scratch embedded
    workspace, `compileNomuWorkspace`, `buildExternalWorkspace` and their nested `compile()` calls go away;
    outputs move to the D2 / D4 layout; a host-cache hit (D4) skips a job. `nomu query` reads the plan in
    place of its own discovery.
  - **190.4.1 — the compile job.** **Done.** `CompileJob` (one module's inputs and outputs, above) and `compile(job)`,
    made from `compileModule`. Discovery still builds the jobs, so the suite stays green across the change.
    The planner's jobs gain each module's transitive imports, direct ones marked.
    As built (`src/driver/sources/CompileJob.swift`): `compile(_:options:timings:)` parses its files, pairs
    each import with the job's resolution of it (a mismatch is a build-system error), loads every
    dependency's `.nmi` (and `.bir` when offered) from disk, and writes `.o` plus, for a library, `.nmi`
    (with escape summaries) and `.bir`. It links nothing: the driver links (`linkBinary`) after the jobs.
    Interfaces keep a module's canonical origin as their re-export paths; `buildInterface` takes the
    module's origin and own files. Dependencies are a module's transitive imports (`ModuleJob.
    visibleDependencies` in the plan). Discovery still parses every file before the jobs run, so parse
    errors still come first until 190.4.2.
  - **190.4.2 — the driver runs the plan.** **Done.** The plan replaces discovery as the source of jobs; the scratch
    embedded workspace and nested workspace builds go; outputs move to D2 / D4; the runtime archive moves to
    the host cache; the link is the plan's link job; the commit stamp is the compiler's identity. The
    cross-check test and `discoveryObserver` are deleted.
    As built: `buildProgram(paths:options:)` plans, runs each job through `compile(job)`, and links; it
    returns the binary's path, which `build` / `run` / `test` use (no more `-o build/<path>` from the
    commands). A module's origin is `[scope, name] + path` (D6). The embedded workspace's files are named
    `<nomu>/…` in jobs and served from the sources the compiler carries. Modules of other workspaces and of
    the embedded one compile with default options, as the nested builds did. The link puts the entry
    object first: the GC shape table (`__nomu_shape_table`) is a weak symbol in every object with
    per-object contents, and the entry's (whole-program) copy must win. A build directory left by the old
    layout (a binary file where a unit directory now goes) must be deleted once.
  - **190.4.3 — host-cache hits.** **Done** (with 190.4.2, which needs it: parallel builds otherwise
    rewrite the shared `std` objects while others link them). A job whose outputs are cached is skipped; entries publish by atomic
    rename. As built: an entry is its unit directory, published whole by one `rename` of a staging
    directory; a present directory is a hit; a losing publisher discards its copy.
  - **190.4.4 — commands.** **Done.** `nomu compile` becomes the job command (D9), its inputs a JSON job file. `build`,
    `run` and `test` go through the plan and take the suite's options (`--runtime-subset`, hidden
    `--allow-core-import`); the harness moves to `nomu build`. `nomu query` reads the plan; the timing report
    includes the planner's steps.
    As built: `nomu compile <job file>` decodes a `JobFile` (the `CompileJob` plus the `EmitOptions` it
    compiles under, JSON) and runs that one job; `-o` and implicit naming are gone. `build` / `run` / `test`
    share one flag set: `-O`, `--mono`, `--runtime-subset`, `--stop`, the `--emit-*` debug views (for the
    entry module), and hidden `--allow-core-import` and `--emit-jobs` (writes each job's file beside its
    outputs; re-running one through `nomu compile` reproduces its object byte for byte). The harness runs
    `nomu build <fixture dir>` and finds the binary under the fixture's workspace `build/`. `nomu query`
    reads the planner's module table. The timing report shows each planning step and the byte and token
    counts (F9). The `modules` library keeps `ModuleID`, module listing and manifests; its discovery helpers
    (`scanWorkspacePackages`, `resolvePackageImport`, `ModuleGraph`) are gone with discovery.
- **190.5 — tests.**
  - **190.5.1 — plan golden tests.** **Done** (11 goldens). `Plan.dump()` renders a plan as text: one block
    per job (package, files, kind, output stem, each import with its location and target, the modules it
    sees), then the runtime archive and the link; a plan with errors lists them instead. Paths render
    relative to named roots (`@<scope>.<name>` per workspace, `$cache` for the host cache) and cache keys
    as `<key>`, so a golden holds on any machine. `PlanGoldenTests` compares in-memory cases (pins,
    library, white-box, the `core` gate lifted, resolution and workspace errors, module and package
    cycles) and three suite fixtures read from disk against `src/planner/tests/golden/*.plan`; on a
    mismatch the actual plan goes to the test's undeclared outputs. Rewriting the goldens:
    `bazel test //src/planner:planner_tests --spawn_strategy=local
    --test_env=NOMU_UPDATE_GOLDENS=$PWD/src/planner/tests/golden`. Hidden `nomu build --stop=plan` prints the
    plan of a real build (also when planning fails).
  - **190.5.2 — build tests.** **Done** (`//src/driver:build_tests`, 4 tests). Each module compiles exactly once per build (a per-origin job count the
    harness can assert, e.g. from the timings report); planner errors (unresolved import, cycle, product
    gate, `core` gate, duplicate or invalid workspace identity) fire before any compile; existing
    multi-package and cross-workspace cases stay green.
    As built: `build(paths:options:)` returns a `BuildResult`: the binary, and the module jobs it compiled
    and took from the host cache, in plan order (the timing report shows the counts; hidden `nomu build
    --report-jobs` prints them). The tests run the `nomu` binary on copies of suite fixtures against a
    private host cache, so they also cover the GC archive embedded in the binary: a module diamond plus the implicit `std`
    compiles each module exactly once and runs; a second build takes every embedded module from the cache
    and compiles only the workspace's own; an unresolved import and a package cycle stop the build with
    nothing compiled and no `build/` written; a pinned workspace's module compiles as a job of the
    consumer's build into its `build/_external/`. The suite (156 cases, multi-package and cross-workspace
    included) runs through `nomu build`.

- **190.6 — follow-ups found while building 190.** Collected during 190; taken up after 190.5. Each is
  the issue, what stands now, and the better fix where one is known.

  *Correctness hazards*
  - **F1 — the GC shape table depends on link order.** `__nomu_shape_table` (and `_count`) is a weak symbol
    in every object, each with its own contents; only the entry's copy describes the whole program. The
    link puts the entry object first so its copy wins (190.4.2). Better: one definition, emitted only by
    the binary job, with library objects referencing it as an external symbol.
  - **F2 — symbol qualifiers can collide.** `Mangle.qualifier` joins origin components with `_`, and
    components may contain `_`, so `a_b/c` and `a/b_c` give the same qualifier. Origins now carry the
    workspace scope and name (`nomu_nomu_lang_…`), so there are more underscores in play. Better: an
    unambiguous encoding (length-prefixed components, as Swift and Itanium manglings do).
  - **F3 — concurrent builds share workspace unit directories.** Host-cache entries publish atomically
    (190.4.3), but a building workspace's unit directories are written in place, so two builds in one
    workspace that share a module (two `nomu build`s, or suite fixtures with a common dependency) can
    write the same files at once. D2 accepts this for now. Better: stage and rename every unit, as the
    cache does, or a per-workspace build lock.
  - **F4 — `-O` and `--mono` do not reach other workspaces' modules.** Pinned and embedded modules compile
    with default options (inherited from the nested builds), so a release build links debug `std`, and
    `PlanOptions.outputOptions` is never filled, so the embedded cache key ignores options. Better: pass
    every output-affecting option to every job and into the key.
  - **F5 — a dirty tree can reuse stale cache entries.** The compiler's identity is its git commit (D4);
    uncommitted compiler changes keep the identity. Accepted by decision; clearing the cache is the remedy.
    Revisit with 172.

  *Robustness and diagnostics*
  - **F6 — an old-layout `build/` blocks the new one.** A binary file where a unit directory now goes
    fails the build with "file exists". Better: a clear message naming the stale path and saying to delete
    it, or removing a non-directory obstacle under `build/`, since the build owns that tree.
  - **F7 — `core` gate message.** A package with its own `core` package but no `dependencies` entry for it
    gets "package 'core' is internal to the standard library". Better: mention the workspace's own `core`
    and the missing `dependencies` entry in that case.
  - **F8 — scanner error positions are unchecked against the parser.** Conformance covers clean files only;
    for `import a/` at end of file the scanner reports the next line. Better: a conformance test over
    malformed headers comparing positions.
  - **F9 — the timing report lost its byte and token counts.** Parsing moved into jobs (190.4.2) and the
    counts were not carried along. Fixed in 190.4.4 (each job adds its counts); close on review.
  - **F10 — embedded diagnostics name virtual paths.** An error in an embedded source reads
    `<nomu>/std/time/time.nomu:…`. Acceptable for compiler-internal code; worth a deliberate format.

  *Behavior changes to review*
  - **F11 — implicit `import std` in pinned workspaces.** Their modules now get it (one path for every
    workspace); before, the nested builds compiled them without it.
  - **F12 — symlinked directories are not followed** by the workspace walk (a symlinked file still
    counts). Before, the registry walk followed them.
  - **F13 — loose builds get the fixed identity `local.main`.** Chosen without discussion in 190.3.1.
  - **F14 — a workspace-root module's outputs take the workspace's name** as their stem (`build/<name>`).
  - **F15 — a module's compile sees only its transitive imports.** Before, it saw every interface compiled
    earlier in the build. The suite shows no difference; the lookup tables (`moduleFuncs`/`moduleTypes`)
    are the place a difference would appear.

  *Design debt*
  - **F16 — the cache key hash is 64-bit FNV-1a.** Fine for a local cache; content addressing for 172 and
    Bazel (192) wants a cryptographic hash (SHA-256).
  - **F17 — plans and jobs hold absolute paths** (outputs, package keys like `<workspace>|<root>`), so a job
    is tied to one machine's layout. Bazel (192) needs workspace-relative paths.
  - **F18 — the runtime recipe version lives in the planner** (`HostCache.runtimeArchiveKey`, `recipe-2`)
    but describes the driver's archive commands. Better: the driver supplies the recipe to the key.
  - **F19 — `ModuleInterface.workspace`** now holds the origin's first component (the scope), and nothing
    reads it. Better: remove it, or store the full workspace identity.
  - **F20 — every library job computes escape summaries and writes its `.nmi`**, where dependents once read
    an in-memory interface. Needed by the job model; its cost is unmeasured.
  - **F21 — the planner's agreement with the old discovery is no longer tested.** The cross-check was
    deleted with discovery (190.4.2); the suite and the planner's unit tests remain.
  - **F27 — the workspace identity-clash message holds absolute paths** (`… both 'me.app': '/w' and
    '/d'`), so a plan golden of that error from disk would be machine-bound. Better: name the workspaces by
    their pins or render the roots relative, as the plan dump does.
  - **F28 — the extracted GC archive is keyed by size only.** The driver writes the archive embedded in
    `nomu` to `$TMPDIR/nomu-gc-<size>.a` and reuses any file of that name, so a new archive of the same
    size as an older one links the stale copy. Better: a content key, in the host cache (D4) beside the
    runtime archive.
  - **F26 — the `tools/` scripts are stale.** About 25 scripts call `bazel-bin/src/nomu-cli/nomuc` (the
    target is `nomu` now; the file left in `bazel-bin` is an old build) on single-file paths such as
    `examples/gc_smoke.nomu` (examples are module directories now). They were broken before 190; with D9
    they need `nomu build <dir>` and the D2 binary path. Better: fix or retire each, or move the ones still
    wanted into the suite.

  *Fixed during 190; the fix is likely satisfactory already (confirm, then close)*
  - **F22 — the runtime archive publish race.** Two compiles publishing the archive at once deleted and
    then moved it, so a concurrent link could find the path missing. Fixed (190.3.3) with one atomic
    `rename`, which replaces an existing archive in a single step.
  - **F23 — reserved name on the entry's own package.** The planner checked reserved package names only in
    the package walk, which a build may never trigger. Fixed (190.3.4): the entry's package is checked when
    the resolver first reads it.
  - **F24 — the `core` gate walked the whole workspace.** It looked for a workspace package named `core`,
    which for a repo-root fixture walked the entire repository (as the old driver did). Fixed (190.3.4): the
    gate checks the importer's `dependencies`, since a workspace's own `core` is importable only when
    listed there.
  - **F25 — cache keys re-hashed every embedded source on each plan.** About 4 ms per plan in a debug
    build. Fixed (190.3.4): the sources are hashed once per process, as are the runtime key and the
    embedded tree.

## Decisions

- **D1 — how jobs run: in-process, sequential.** Each job runs to completion in the driver's process, in
  plan order. The job stays a serializable value, so a different scheduler can replace the loop later.
  Parallel in-process execution is [191](191-threaded-job-execution.md). A subprocess per job (Swift's
  `swift-frontend` model) remains an option for later.
- **D2 — where workspace artifacts live: one directory per unit in the workspace's `build/`.** A unit has
  many outputs (object, `.nmi`, `.bir`, binary, later formats and logs), so its canonical location is a
  directory. Each output takes the module's leaf name as its stem.

  ```
  build/                               the building workspace
    app/cli/                           module app/cli (source app/cli/main.nomu)
      cli                              binary, named after the module's leaf
      cli.o  cli.nmi  cli.bir  …
    greet/                             a library module
      greet.o  greet.nmi  greet.bir
    _external/<scope>.<name>/<module path>/  another workspace's modules, by identity (D6)
  ```

  The building workspace's modules sit directly under `build/` at their workspace-relative path. Every
  other workspace's modules (pinned ones, and the pins of pinned ones) sit under
  `_external/<scope>.<name>/`. An alias is local to one `nomu.yaml`, so once externals of externals are
  followed, only the workspace identity (D6) is unique across the build. Module path components match `[a-z][a-z0-9_]*`
  (modules.md §Filesystem), so `_external` cannot collide with a module and no name is reserved. The
  planner enforces the path-component rule.

  A build assumes the contents of each unit's directory are exactly what this build needs: no
  validation, versioning or sharing across builds. [172](172-incremental-build-cache.md) redesigns this
  layer for incremental compilation.
- **D3 — what the scanner returns: imports only.** Each import with its location, root, path, alias, and its
  `public` / `test` modifiers. The planner reads everything else (test-module status, products,
  dependencies) from manifests.
- **D4 — language-level artifacts live in a per-host cache.** The runtime archive and the embedded `nomu`
  workspace's modules (`core`, `std/*`) are shared by every build on the host and survive
  `git clean -dfx`. The cache root is `NOMU_CACHE_DIR` when set, else the platform user cache directory:
  `~/Library/Caches/nomu/` on macOS, `$XDG_CACHE_HOME/nomu/` (falling back to `~/.cache/nomu/`) on Linux.

  ```
  <cache root>/
    runtime/                           runtime archive, keyed as today
    nomu/<key>/<module path>/          embedded nomu workspace unit directories
  ```

  Shared entries are content-addressed. The runtime archive keeps its current key (embedded sources, host
  architecture, recipe version). The embedded workspace's key hashes its embedded sources, the compiler's
  identity (`.nmi` / `.bir` formats change with it; the git commit the compiler was built from), the host target and every option that changes its
  output. A present entry skips that unit's job. 172 and [192](192-bazel-friendliness.md) (Bazel friendliness)
  revisit this layout.

  The compiler's identity is the git commit it was built from, embedded by Bazel stamping (a
  `workspace_status_command` script, through a `STABLE_` key); an unstamped build uses a fixed placeholder.
  Uncommitted changes leave the identity unchanged, so a compiler built from a dirty tree can reuse entries
  from an earlier build of the same commit. Most changes leave the cached artifacts valid; after one that
  changes the `.nmi` / `.bir` format or the embedded sources' compiled output, clear the cache directory
  (or point `NOMU_CACHE_DIR` elsewhere). Hashing the uncommitted diff into the key, or skipping the cache
  for dirty builds, were the alternatives.

- **D5 — components.** Build planning leaves the driver:

  ```
  scanner   file → raw imports                              (no dependencies)
  modules   manifests, registry, ModuleID, graph            (exists)
  planner   scanner + modules → Plan (jobs, outputs, checks)
  compiler  one job → artifacts                             (today's per-module pipeline)
  driver    command → plan → run jobs → link → report
  ```

  The planner reads and never writes: it returns a `Plan` value, testable against expected plans without
  compiling, and a candidate input for Bazel ([192](192-bazel-friendliness.md)). Embedded sources reach it
  as data through a source-provider interface shared with on-disk workspaces; materializing them (or using
  the host cache) is an execution step. The scanner is a sub-target of the planner
  (`//src/planner/scanner`): part of planning, separately optimized and tested, and reusable by tools that
  need only imports.

- **D6 — module identity: workspace identity + module path.** Every module in the plan is keyed by its
  owning workspace's identity, `scope` + `name` (189 §Decided — workspace identity), and its
  workspace-relative path; mangling uses the same key. Both fields are required in `nomu.yaml` and match
  the path-component rule `[a-z][a-z0-9_]*`, with no fallback to the directory name, so the pair is usable
  unchanged as a graph key, a `build/_external/<scope>.<name>/` directory and a mangling prefix. Two
  distinct workspaces in one build with the same identity are a planner error (local-path pins cannot be
  told apart from one project yet; 189 makes a root path pin an override). Keying by workspace root would
  need the same check; keying by alias breaks once a pinned workspace's own pins are followed. 190.3 reads
  and enforces both fields; the repository's own `nomu.yaml` (`name: nomu-lang`) and the fixtures gain a
  valid `scope` and `name` when the check lands. `nomu init`, which proposes a scope, is 189's.

  Path pins are allowed at any depth in 190: every external is a local path today, so restricting them to
  the root (189 §Decided) would leave transitive pins unusable. Two pins resolving to one directory are one
  workspace. 189 applies the root-only rule once remote sources exist.
- **D7 — the planner is designed whole, up front.** 190.3 plans every workspace and places every output
  (D2, D4) from the start, so the plan's full shape is settled and tested before the driver changes how it
  runs anything (190.4). Splitting by workspace (local first, externals later) was the alternative.
- **D8 — each job parses its own module.** The planner reads only import blocks; a module's full parse
  happens in its job. Resolution, cycle and gate errors all report before any compile; a module's parse
  errors report when its job runs, after its dependencies compiled. This is the explicit-module model
  (Swift's), and it keeps full parsing off the critical path to the first job. Parsing every module before
  the first job would keep today's error order at the cost of that throughput.

- **D9 — `nomu compile` is the per-module job.** It compiles exactly one module from explicit inputs (the
  `compile()` inputs of 190.4) into explicit output paths, and does no planning, discovery or linking. It is
  a tool interface, not a user command: it exists so a build can be divided at the process level (Bazel
  actions, 192; subprocess jobs, D1), the role `swift-frontend` plays for Swift. Every output name comes
  from its caller; nothing is derived from the input file names. Whole builds go through `nomu build`
  (and `run` / `test`). Keeping `nomu compile` as the whole-build command for explicit file lists, with a
  required `-o`, was the alternative.

## Non-goals

- Reusing user or external-workspace artifacts across builds. Every build still compiles each of those
  modules once; skipping unchanged modules is [172](172-incremental-build-cache.md). The per-host cache of
  language-level artifacts (D4) is the one exception.
- Sub-module (query-level) incrementality — [136](136-incremental-compilation.md).

## Dependencies & triggers

- Builds on 100 (separate compilation), 187 (multi-package), 188 (local external workspaces) and 174
  (embedded `nomu` workspace).
- Precedes 172: the cache keys on 190's jobs.
- Precedes 191: threaded execution schedules 190's jobs.

## Refs

- `src/driver/sources/Driver.swift` — `compile()` (discovery, topological loop, `compileModule`),
  `compileNomuWorkspace`, `buildExternalWorkspace`.
- `src/frontend/parse/sources/Parser.swift` — `parseImports` (the top-of-file import block the scanner
  mirrors).
- Swift: explicit module builds (`swift-frontend -scan-dependencies`, libSwiftScan,
  `-explicit-swift-module-map-file`).
