# Explicit module builds — dependency scan + build plan

**Avenue:** Infra · **Type/Lifecycle:** `infra · needs-design` (driver + build orchestration) · **Size:** L ·
**Status:** done — D1–D9 decided (§Decisions); 190.1–190.6 done. 190.6's open items moved to their own
homes: F1 → 195 (done), F2 → 203, F3/F5/F6/F16 → 172, F4 → 198, F12/F17 → 192, F20 → 202. ·
**Source:** found closing [174](174-prelude-as-packages.md): the language workspace's `std` package compiled
`std/prelude` twice per build.

## Deliverable

A split between the compiler and the driver, in the Swift explicit-module-build model.

- **The compiler** (one job) compiles one module: its source files, the artifacts (`.nmi`, `.bir`) of the
  modules it depends on, its implicit imports and its options, into one output directory. It knows nothing
  of workspaces, packages, manifests or discovery, nor where its dependencies came from.
- **The driver** owns workspaces, packages and manifests. It scans the build's imports up front, plans one
  fine-grained graph whose nodes are individual modules (plus the runtime archive and the link), and
  picks the next ready node to run. Every workspace takes the same path, whether it is the one the build
  started in, a pinned external one or the language workspace. A workspace differs only in data: where its
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
the language workspace's `runtime` package always is (`std` and generated code call its functions by bare
name, so nothing imports it); and the runtime archive always is, since every binary links it. There is no
separate link-selection step. This replaces today's over-linking of all of `std` and of every product (plus
`__mod_*` intermediate) of a pinned workspace.

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
  their own pins, the language workspace), keyed per D6, and places every job's outputs per D2 and D4.
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
    with the fixed identity `local.main`, rooted at the entry's package; the language workspace's
    identity is `nomu.nomu`, and its package list moved from the driver into the planner
    (`LanguageWorkspace`), which the driver now materializes from.
  - **190.3.2 — resolution.** **Done** (`ModuleTable`, 11 unit tests). Scanning every reachable file, plus the
    implicit `import std`. Every import form (`pkg/…`, bare package, alias-qualified, external through pins,
    `std`, `core` behind its gate and the planner option that lifts it) and the product, `dependencies`, and
    same-package `test import` checks. Output: the module table and collected diagnostics. As built: modules
    are keyed `ModuleKey` (workspace identity + workspace-relative path) and resolved breadth-first from the
    entry; error messages match the driver's. The implicit `import std` applies to every file outside the
    language workspace, pinned workspaces included (today a pinned workspace's modules compile without it;
    that changes when 190.4 runs the plan). The language workspace's `std` manifest lists `core` in
    `dependencies`, so `std`'s access to `core` goes through the ordinary allow-list. An import naming only a
    pin alias (`import wsa`) is an error asking for a package.
  - **190.3.3 — the plan.** **Done** (`Plan`, 9 unit tests). Module and package cycle checks, job order, output directories (D2, D4), the
    D4 cache key with the git-commit stamp, the runtime-archive node and the link node.
    As built: `Plan(entryFiles:options:)` loads, resolves and plans in one call; with any error the plan
    holds no jobs. Jobs are ordered depth-first from the entry; a cycle is reported at the import that
    closes it. A module job's outputs share its leaf name as stem (no module sits at a workspace root;
    190.6 F14); the runtime archive goes to `<cache root>/runtime/<key>/nomu-runtime.a`. The
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
    runs the jobs in order (D1), builds the runtime archive, and links. Discovery, the scratch language
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
    language workspace and nested workspace builds go; outputs move to D2 / D4; the runtime archive moves to
    the host cache; the link is the plan's link job; the commit stamp is the compiler's identity. The
    cross-check test and `discoveryObserver` are deleted.
    As built: `buildProgram(paths:options:)` plans, runs each job through `compile(job)`, and links; it
    returns the binary's path, which `build` / `run` / `test` use (no more `-o build/<path>` from the
    commands). A module's origin is `[scope, name] + path` (D6). The language workspace's files are named
    `<nomu>/…` in jobs and served from the sources the compiler carries. Modules of other workspaces and of
    the language workspace compile with default options, as the nested builds did. The link puts the entry
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
  - **190.5.2 — build tests.** **Done** (`//src/driver:build_tests`, 4 tests). Each module compiles exactly
    once per build (a per-origin job count the harness can assert, e.g. from the timings report); planner
    errors (unresolved import, cycle, product gate, `core` gate, duplicate or invalid workspace identity) fire
    before any compile; existing multi-package and cross-workspace cases stay green. As built:
    `build(paths:options:)` returns a `BuildResult`: the binary, and the module jobs it compiled and took from
    the host cache, in plan order (the timing report shows the counts; hidden `nomu build --report-jobs`
    prints them). The tests run the `nomu` binary on copies of suite fixtures against a private host cache, so
    they also cover the GC archive embedded in the binary: a module diamond plus the implicit `std` compiles
    each module exactly once and runs; a second build takes every language-workspace module from the cache and
    compiles only the workspace's own; an unresolved import and a package cycle stop the build with nothing
    compiled and no `build/` written; a pinned workspace's module compiles as a job of the consumer's build
    into its `build/_external/`. The suite (156 cases, multi-package and cross-workspace included) runs
    through `nomu build`.

- **190.6 — follow-ups found while building 190.** **Done:** each is settled here or moved to its home.
  Collected during 190; taken up after 190.5. Each is the issue, what stands now, and the better fix where
  one is known.

  *Correctness hazards*
  - **F1 — GC stack scanning is unsound across objects.** Lost stackmaps (only the first object's are read,
    in both walkers), colliding shape ordinals, linear record lookup, duplicate copies' records. Moved to
    its own task, [195](195-link-time-gc-frame-index.md) (a frame index built by the driver after the link);
    190 closes after it.
  - **F2 — symbol qualifiers can collide.** `Mangle.qualifier` joins origin components with `_`, and
    components may contain `_`, so `a_b/c` and `a/b_c` give the same qualifier. The boundary between
    qualifier and name collides the same way: `fun helper` in module `app/util` and `fun util_helper` in
    module `app` are both `nomu_fn_<ws>_app_util_helper`. Generic instances use a second scheme (raw `/`,
    `@`, `<`, `>`, `,`, as `Monomorphize` builds them), so producer and consumer names come from two code
    paths. The entry module and the runtime both use bare names, and the actor and spawn thunks take no
    qualifier. A collision between strong symbols fails the link; one involving a weak symbol (a generic
    specialization, the runtime's weak-ODR set) silently links the wrong definition.
    **Decided** (the 9-escape of `backend.md` §3, built as specified and extended) and **moved to its own
    task, [203](203-symbol-encoding.md)**, with the decision, its reasoning and the work.
  - **F3 — concurrent builds share workspace unit directories.** Host-cache entries publish atomically
    (190.4.3), but a building workspace's unit directories are written in place, so two builds in one
    workspace that share a module (two `nomu build`s, or suite fixtures with a common dependency) can
    write the same files at once. The binary itself is published by rename
    ([195](195-link-time-gc-frame-index.md) 195.3). Overlapping builds can see three hazards: torn reads (a
    consumer compiles against, or links, a file another build is rewriting), mixed configurations (a debug
    and a release build writing the same unit files), and mixed sources (a source edit between overlapping
    builds pairs an old `.nmi` with a new `.o`). A single build is unaffected, and nothing under `build/` is
    reused across invocations.
    **Moved to [172](172-incremental-build-cache.md); accepted until then, torn reads included.** 172
    replaces how unit outputs are stored, and its content-addressed store removes all three hazards by
    construction (immutable outputs at input-keyed paths), so interim fixes (per-file or per-unit atomic
    publish, a build lock) would be replaced. Mixed configurations also go away with
    [198](198-build-configuration.md)'s per-configuration output locations.
    The harness half is fixed: the suite once found a case's binary by fixture path alone, so cases building
    one fixture under different settings ran whichever binary was built last; each configuration now gets
    its own binary under `build/compiler-test/` (155 Phase 3).
  - **F4 — `-O` and `--mono` do not reach other workspaces' modules.** *Closed by 198.6:* the optimization
    level and mono are settings every job receives, and the language workspace's key includes them. Pinned and language-workspace modules
    compile with default options (inherited from the nested builds), so a release build links debug `std`, and
    `PlanOptions.outputOptions` is never filled, so the language workspace's cache key ignores options.
    **Moved to [198](198-build-configuration.md)** (build configuration), which designs per-workspace
    configurations and the cache key together; accepted until then. No correctness hazard: the settings change
    performance only, the language workspace's entry is always built one way, and nothing under `build/` is
    reused across invocations. Costs: release performance figures include a debug `std`, and a release `std`
    is untested.
  - **F5 — a dirty tree can reuse stale cache entries.** The compiler's identity is its git commit (D4);
    uncommitted compiler changes keep the identity, so a compiler edit that changes codegen, the `.nmi` /
    `.bir` formats, layouts, GC metadata or symbol names reuses `std`/`core`/`runtime` objects from the
    previous compiler (a link error or a silent mismatch). Edits to the embedded `.nomu` sources do change
    the key. **Moved to [172](172-incremental-build-cache.md)**, whose module cache needs the same identity;
    accepted until then, with clearing the cache as the remedy.

  *Robustness and diagnostics*
  - **F6 — an old-layout `build/` blocks the new one.** A binary file where a unit directory now goes
    fails the build with "file exists". The layout also clashed with itself on a clean build: a child
    module named like the workspace took `build/<workspace name>/`, the root module's binary path, and the
    binary's rename failed with "Is a directory" (reproduced). That clash is gone with F14 (no module sits
    at a workspace root). The stale-layout half is **moved to [172](172-incremental-build-cache.md)**,
    which redesigns `build/`; accepted until then. Workaround: delete `build/`.
  - **F7 — `core` gate message.** A package with its own `core` package but no `dependencies` entry for it
    gets "package 'core' is internal to the standard library". **Done. Decided: the language workspace's
    `core` does not exist for user workspaces** (`modules.md` §Imports). From a user workspace, `import core`
    resolves exactly as any other package name: through the `dependencies` allow-list to the workspace's own
    or a pinned workspace's `core`, failing with the same message any unknown or unlisted name gets. No
    diagnostic names or confirms the language workspace's `core`; the "internal to the standard library"
    message goes. User workspaces may name a package `core`. The hidden `--allow-core-import` (suite fixtures
    that test `core` directly) stays as a test-only escape. Built in `Resolution.target`; covered by
    `ResolutionTests.testCoreGate` (unlisted, listed-and-own, listed-and-missing, the hidden flag), the
    `resolution_errors` plan golden and the suite case `core-import-rejected`. Also to check: other
    diagnostics that reveal the language workspace's `core` to user code, such as `<nomu>/core/…` paths in
    errors (F10) or `core` types named in type errors.
  - **F8 — scanner error positions are unchecked against the parser.** Conformance covers clean files only;
    for `import a/` at end of file the scanner reports the next line. **Done.** The planner reports the
    scanner's error for a malformed header (planning stops before any compile), so it is what users see. A
    missing name is now reported just past the token that wants it, on the import's own line, with one
    wording in both the scanner (`expectComponent`) and the parser (`expectImportName`):
    `1:10: expected a name after '/'`, `… after 'as', got keyword 'fun'`. `TokenKind.keywordSpelling` gives
    the parser keyword spellings. `ImportScannerTests.testMalformedHeadersMatchParser` checks ten malformed
    headers for the same message and position in both.
  - **F9 — the timing report lost its byte and token counts.** Parsing moved into jobs (190.4.2) and the
    counts were not carried along. **Resolved:** the counts were restored in 190.4.4 (each job adds its
    own), and the report's redesign for the job model is [193](193-compiler-performance-report.md).
  - **F10 — language-workspace diagnostics name virtual paths.** An error in a language-workspace source reads
    `<nomu>/std/time/time.nomu:…`, and the language workspace's debug info names `<nomu>/…` directories, so
    lldb, profilers and crash reports could not open stdlib source. **Done.** The driver keeps one copy of the
    embedded sources at `<cache root>/source/` (`LanguageSourceCopy`), replaced whenever a compiler with
    different embedded sources uses it (a `.digest` file names the sources it holds); writing it costs about 3
    ms, checking it about 0.03 ms. The copy is for reporting only: compiling still reads the sources carried
    in the compiler, and `<nomu>/…` stays each file's identity inside the compiler (`SourceMap.name`; Sema and
    interfaces key on it). The reported path is `SourceMap.displayName`, passed to language-workspace jobs as
    `CompileJob.reportedPaths`; diagnostics and debug info use it. A binary built by an older compiler may
    point at newer sources. lldb lists stdlib source with no setup. Tests:
    `BuildTests.testLanguageSourcesCopiedForReporting`, `LexerTests.testDiagnosticsReportTheDisplayName`.
    Revisit with LSP and editor support ([137](137-tooling-lsp-formatter.md)), which may want the sources
    presented differently.
  - **F29 — loose builds reject imports of their own modules.** A build with no `nomu.yaml` above it,
    rooted at its `pkg.json`, fails on `import pkg/left` with "'…/left' lies outside workspace
    'local.main'". Cause: a path-spelling mismatch. The entry directory comes from
    `standardizedFileURL` (which turns `/private/tmp` into `/tmp`), a `nomu.yaml` root goes through
    `realpath`, and a loose root does not, so under a symlinked directory the loose root and its module
    paths disagree. A loose copy under `~/` builds correctly.
    **Done. Decided: no loose builds** (`modules.md` §Manifest). `nomu build`, `run`, `test` and `query`
    require a `nomu.yaml` at or above the target and fail with "no nomu.yaml found at or above '<dir>' — a
    build needs a workspace: a nomu.yaml declaring its 'scope' and 'name'"; `nomu compile` needs neither
    `nomu.yaml` nor `pkg.json` (its job file carries everything; checked by hand). This removes the failing
    path and settles F13. Built: `resolveModule` (shared by the four commands) checks for the workspace
    first; the planner reports the same error (`WorkspaceSet.missingWorkspace`) and resolution then adds
    nothing; the loose branch and `looseWorkspaceIdentity` are gone. Tests:
    `WorkspaceTests.testNoWorkspaceIsAnError`, `BuildTests.testCommandsRequireAWorkspace`. The F29 copy
    with a `nomu.yaml` added builds and runs under `/private/tmp`.

  *Behavior changes to review*
  - **F11 — implicit `import std` in pinned workspaces.** Their modules now get it (one path for every
    workspace); before, the nested builds compiled them without it. **Kept:** every file outside the
    language workspace gets the implicit `import std`, as `modules.md` §Imports says, so a workspace
    compiles the same whether built directly or pinned. Covered by `ResolutionTests.testPinnedWorkspaces`.
    Opting out of or narrowing the implicit import is [201](201-implicit-import-control.md).
  - **F12 — symlinked directories are not followed** by the workspace walk (a symlinked file still
    counts). Before, the registry walk followed them. `pkg/…` resolution does follow them (it lists a
    directory through `opendir`), so a package behind a symlinked directory is not found by name ("…is
    external but no workspace pinned in nomu.yaml provides it") while a module behind one resolves.
    **Moved to [192](192-bazel-friendliness.md)** (Bazel friendliness), with the goals and findings there;
    accepted until then.
  - **F13 — loose builds get the fixed identity `local.main`.** Chosen without discussion in 190.3.1.
    **Done:** settled by F29; loose builds are removed, and every build has its workspace's identity.
  - **F14 — a workspace-root module's outputs take the workspace's name** as their stem (`build/<name>`).
    This path clashes with a child module named like the workspace (F6); the layout is 172's.
    **Done. Decided:** packages live in subdirectories of their workspace, so there is no workspace-root
    module to name. A `pkg.json` at a workspace root is an error ("a package may not sit at the root of
    workspace '…' — move its pkg.json and modules into a subdirectory"), and a module at the root is in no
    package; every module therefore has a path, and its outputs are named after its last component. Why: a
    root package cannot coexist with a second package (packages do not nest), so a project that starts at
    the root must move its files to grow; `nomu init`'s template puts the first package in a subdirectory,
    and that becomes the only layout. It also removes F6's layout clash.
    With it, every module must be in a package: a `pkg.json` declaring `name` at or above it within its
    workspace (`modules.md` §Manifest). The implicit package `main` (`defaultPackageName`) is gone, and
    package names are checked against `[a-z][a-z0-9_]*` by the planner (before, only the reserved names
    were). Built: `Resolution.run` reports a root package (once per workspace, `WorkspaceSet.hasRootPackage`,
    which the package walk also uses), a module at the root, or a module in no package, and stops;
    `packageNameProblem` checks names for the entry's package and for every package the walk finds.
    Migration: a name-only `pkg.json` for 45 fixture directories (11 fixtures, 34 `shape_matrix` cases),
    each named after its directory (the examples were already one package, `examples/pkg.json`); the two
    reserved-name fixtures moved their package into `app/`; module keys and symbols are otherwise unchanged (both come from the workspace-relative path).
    Tests: `ResolutionTests.testModuleInNoPackage`, `testNothingAtTheWorkspaceRoot`,
    `testPackageNamesFollowThePathComponentRule`, `PlanTests.testPackageRootModuleAndFlags`; planner
    unit-test trees put their packages in `/w/app/`; plan goldens show the moved paths and the fixtures'
    own package names.
  - **F15 — a module's compile sees only its transitive imports.** Before, it saw every interface compiled
    earlier in the build. The suite shows no difference; the lookup tables (`moduleFuncs`/`moduleTypes`)
    are the place a difference would appear. **Kept:** a compile loads the interfaces of its transitive
    imports (`ModuleJob.visibleDependencies`). The transitive closure is required: §100.5 decided that a
    release compile's input set is the transitive `.nmi` closure plus its dependencies' `.bir`, because a
    specialized body can call anything its producer could see (a debug compile needs only direct `.nmi`).
    Name visibility does not depend on that set: Sema resolves names through each file's own imports
    (`fileVisibleModules`); the closure supplies what lies beyond names (layouts of types in visible
    signatures, conformances, the declarations specialized bodies reference). The old set depended on build
    order; the closure is deterministic and is what a per-action build (Bazel) declares. Reviewing this
    found that the compile does not yet declare functions from the closure beyond its direct imports, so a
    release build of a three-module generic chain fails: [171](171-modules-cleanup.md) 171.8.

  *Design debt*
  - **F16 — the cache key hash is 64-bit FNV-1a.** Fine for a local cache; content addressing for 172 and
    Bazel (192) wants a cryptographic hash (SHA-256). **Moved to [172](172-incremental-build-cache.md),
    reframed:** Nomu's own cache serves a single execution host, and remote caching and remote execution
    go through Bazel, so only accidental collisions matter and no cryptographic hash is needed. FNV-1a stays
    until 172 chooses its key hash against the requirements recorded there.
  - **F17 — plans and jobs hold absolute paths** (outputs, package keys like `<workspace>|<root>`), so a job
    is tied to one machine's layout. Bazel (192) needs workspace-relative paths. **Moved to
    [192](192-bazel-friendliness.md)**, which decides how jobs map to actions and so what the paths are
    relative to; accepted until then, since builds run jobs in the driver that planned them.
  - **F18 — the runtime recipe version lives in the planner** (`HostCache.runtimeArchiveKey`, `recipe-2`)
    but describes the driver's archive commands. Better: the driver supplies the recipe to the key.
    **Done:** the driver's `runtimeArchiveRecipe` lists the commands it runs (`cc` per source, `ar rcs`),
    `PlanOptions.runtimeRecipe` carries it to the planner, and `HostCache.runtimeArchiveKey(recipe:)`
    hashes it in place of the hand-bumped `recipe-2`. A changed command now rebuilds the archive.
  - **F19 — `ModuleInterface.workspace`** now holds the origin's first component (the scope), and nothing
    reads it. Better: remove it, or store the full workspace identity. **Done: removed.** Each job gets its
    dependencies' origins from the plan (`CompileJob.Dependency.origin`), and the `.nmi`'s `modulePath`
    already holds the full identity (`[scope, name] + path`).
  - **F20 — every library job computes escape summaries and writes its `.nmi`**, where dependents once read
    an in-memory interface. Needed by the job model; its cost is unmeasured. **Measured, then moved to
    [202](202-one-inference-phase.md):** writing the `.nmi` costs under 1 ms; the cost is a second lowering
    and escape computation (about 170 ms for `runtime`, 20% of a cold build). 202 lowers each module once
    and runs module inference once.
  - **F21 — the planner's agreement with the old discovery is no longer tested.** The cross-check was
    deleted with discovery (190.4.2); the suite and the planner's unit tests remain. **Closed:** with one
    implementation there is nothing to compare; the plan goldens and the suite cover the planner.
  - **F27 — the workspace identity-clash message holds absolute paths** (`… both 'me.app': '/w' and
    '/d'`), so a plan golden of that error from disk would be machine-bound. Better: name the workspaces by
    their pins or render the roots relative, as the plan dump does. **Closed:** this is the error that
    keeps identities unique (D6); a user needs the two directories that claim the identity, and absolute
    paths name them unambiguously. Today's golden uses an in-memory tree, so it is portable. If a golden of
    a clash from disk is added, the plan dump can rewrite known roots in message text to `@scope.name`.
    [189](189-multi-remote-workspace-builds.md) rewrites the message when root pins resolve a duplicate.
  - **F28 — the extracted GC archive is keyed by size only.** The driver writes the archive embedded in
    `nomu` to `$TMPDIR/nomu-gc-<size>.a` and reuses any file of that name, so a new archive of the same
    size as an older one links the stale copy. Better: a content key, in the host cache (D4) beside the
    runtime archive. **Moot:** the archive left with MMTk ([197](197-retire-mmtk-and-c-scheduler.md)); the
    driver extracts no GC archive, and the only runtime archive is keyed by content (`runtimeArchiveKey`).
  - **F26 — the `tools/` scripts are stale.** About 25 scripts call `bazel-bin/src/nomu-cli/nomuc` (the
    target is `nomu` now; the file left in `bazel-bin` is an old build) on single-file paths such as
    `examples/gc_smoke.nomu` (examples are module directories now). They were broken before 190; with D9
    they need `nomu build <dir>` and the D2 binary path. Better: fix or retire each, or move the ones still
    wanted into the suite. **Resolved:** `tools/` now holds `escape-diff.sh`, `perf-tier.py`, `install/`
    and `workspace_status.sh`; none calls `nomuc`, and the two that build programs use
    `bazel-bin/src/nomu-cli/nomu build <dir>`.
  - **F30 — rename "embedded workspace" to "language workspace".** The workspace the compiler carries
    (`core`, `runtime`, `std`) is the heart of the language from the user's view; "embedded" names how it
    ships, not what it is. **Decided:** call it the *language workspace*, in docs and in code. Its identity
    stays `nomu.nomu`. Scope: the workspace concept: `EmbeddedWorkspace`, `isEmbedded`, `includeEmbedded`,
    `loadEmbedded`, `embeddedWorkspaceKey`, `embeddedDir`, `EmbeddedSourceCopy`, the test names that use
    them, comments, and the design docs that say "embedded workspace" (about 24 Swift files, 9 docs).
    **Renamed:** `LanguageWorkspace`, `isLanguageWorkspace`, `includeLanguageWorkspace`,
    `loadLanguageWorkspace`, `languageWorkspaceKey`, `LanguageSourceCopy` and the tests that use them;
    comments, fixtures and design docs say "language workspace" (`modules.md` §Imports defines it).
    "Embedded" stays where it names something else: the C floor, code signatures, value fields, resource
    embedding (160). **Done.** The mechanism keeps "embedded": the `//src/runtime/embedded` target and
    `EmbeddedSources` hold all the source text compiled into the binary, the C floor included, which is
    outside the language workspace. The digest of the workspace's files is `languageSourcesDigest`.

  *Fixed during 190; confirmed and closed*
  - **F22 — the runtime archive publish race.** Two compiles publishing the archive at once deleted and
    then moved it, so a concurrent link could find the path missing. Fixed (190.3.3) with one atomic
    `rename`, which replaces an existing archive in a single step. **Closed.** The contention itself goes
    away with the direction for 172: one `nomu` invocation at a time per workspace, with several root
    modules allowed in one build, so the planner compiles the runtime once.
  - **F23 — reserved name on the entry's own package.** The planner checked reserved package names only in
    the package walk, which a build may never trigger. Fixed (190.3.4): the entry's package is checked when
    the resolver first reads it. **Closed;** F14 broadened the check to the path-component rule
    (`packageNameProblem`).
  - **F24 — the `core` gate walked the whole workspace.** It looked for a workspace package named `core`,
    which for a repo-root fixture walked the entire repository (as the old driver did). Fixed (190.3.4): the
    gate checks the importer's `dependencies`, since a workspace's own `core` is importable only when
    listed there. **Closed;** superseded by F7, which removed the gate: `core` resolves like any other name.
  - **F25 — cache keys re-hashed every embedded source on each plan.** About 4 ms per plan in a debug
    build. Fixed (190.3.4): the sources are hashed once per process, as are the runtime key and the
    embedded tree. **Closed;** to be re-audited with 172's keys.

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
- **D4 — language-level artifacts live in a per-host cache.** The runtime archive and the language
  workspace's modules (`core`, `std/*`) are shared by every build on the host and survive
  `git clean -dfx`. The cache root is `NOMU_CACHE_DIR` when set, else the platform user cache directory:
  `~/Library/Caches/nomu/` on macOS, `$XDG_CACHE_HOME/nomu/` (falling back to `~/.cache/nomu/`) on Linux.

  ```
  <cache root>/
    runtime/                           runtime archive, keyed as today
    nomu/<key>/<module path>/          language workspace unit directories
  ```

  Shared entries are content-addressed. The runtime archive keeps its current key (embedded sources, host
  architecture, recipe version). The language workspace's key hashes its embedded sources, the compiler's
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
  (language workspace).
- Precedes 172: the cache keys on 190's jobs.
- Precedes 191: threaded execution schedules 190's jobs.
- Depends on all of [195](195-link-time-gc-frame-index.md) (done): GC stack scanning across objects (190.6 F1).
- Depends on [176](176-shaped-gc-roots.md) 176.5: one shape per type (stale `String` buffer pointers after a moving
  collection). GC correctness is soundness, Nomu's first priority, so 190 closes after both.

## Refs

- `src/driver/sources/Driver.swift` — `compile()` (discovery, topological loop, `compileModule`),
  `compileNomuWorkspace`, `buildExternalWorkspace`.
- `src/frontend/parse/sources/Parser.swift` — `parseImports` (the top-of-file import block the scanner
  mirrors).
- Swift: explicit module builds (`swift-frontend -scan-dependencies`, libSwiftScan,
  `-explicit-swift-module-map-file`).
