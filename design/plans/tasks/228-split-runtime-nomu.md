# Split `runtime.nomu` into files by subsystem

**Avenue:** Infra · **Type/Lifecycle:** `runtime · refactor` · **Size:** S–M · **Status:** built ·
**Source:** raised during [223](223-retire-the-c-floor.md).6, once the C floor's code had moved into it.

## What

`src/stdlib/runtime.nomu` is one file of about 5,800 lines and 30 sections. Splitting it changes nothing
for the compiler's speed; it makes the runtime easier to read and edit. The runtime stays **one module**
spread over several files: a pure move, with no imports, no visibility changes, and no symbol changes
(the runtime's functions keep their pinned `nomu_fn_<name>` names). Splitting into several modules would
mean deciding cross-module visibility for runtime internals, per-module naming of the pinned symbols, and
init ordering across modules; that waits for a reason to want it.

## Files

Ten files in a `runtime/` directory (approximate line counts at the time of filing):

| File | Contents | Lines |
|---|---|---|
| `startup.nomu` | process-wide state, run settings | ~410 |
| `carrier.nomu` | carrier record, write barrier | ~560 |
| `immix.nomu` | regions, line marking, sweep, forwarding, defrag trigger | ~870 |
| `descriptors.nomu` | GC type descriptors | ~310 |
| `stackwalk.nomu` | stack maps, frame index, pcsp walk, parked-fiber walk, typed-root shadow stack | ~700 |
| `collect.nomu` | evacuation, whole-heap and minor collection | ~680 |
| `gcreport.nomu` | the collector's recorder and report | ~1,170 |
| `scheduler.nomu` | M:N scheduler, timers, actors, live-fiber registry, entry points | ~520 |
| `io.nomu` | line input and the stdin poller | ~220 |
| `verify.nomu` | bump allocator and mark-verify tracer (early-rung code the suite still uses) | ~260 |

`gcreport.nomu` may split again into recorder and report.

## Mechanics

Every place that names the one file:
- **Embedding:** `embed.sh` and the `embedded_sources` genrule take `runtime.nomu` as one argument and emit
  `runtimePreludeName` / `runtimePreludeSource`; they become a list of (file name, source), as
  `stdModules` is. `src/stdlib/BUILD.bazel` exports `*.nomu`; the new directory needs a filegroup.
- **The workspace:** `LanguageWorkspace.packages` gives the `runtime` package one `ModuleFile`; it takes
  the list. Modules already span several files (`std`).
- **Weak origins:** `CompileJob.swift` marks the prelude file names weak-ODR for an ordinary module (it
  matters only for a `test.runtime_prelude` prepend) by bare file name. With ten names, a user file named
  `io.nomu` would match, so the prepend must parse the runtime files under names no user file can have
  (for example `runtime/io.nomu`) and the weak set must use the same names.
- **The white-box prepend:** `prependRuntimePrelude` (`CompileSupport.swift`) parses one source; it
  parses each file and concatenates the declarations.
- **Tests:** `ImportScannerTests.testConformsOnEmbeddedSources` lists the runtime file.
- Comments and docs that cite `runtime.nomu` by name (the task files, `runtime-subset.md`,
  `selfhosted-gc.md`, the C floor's remaining comments) move to the new file names.

## Tests

The full tier, `--check-reproducible`, and the Bazel test targets, unchanged; `nm` on a built binary
showing the same set of runtime symbols before and after.

## As built

- The ten files are in `src/stdlib/runtime/`, with a `README.md` listing them; each starts with a two-line
  header. The split was made by a script that cuts at section headers and at the comment block above a
  named function, since several sections had drifted (the forwarding header sat apart from its code, the
  frame-index check sat inside the descriptors section, and line input sat inside the scheduler's entry
  points). Every line of the old file but its six-line header appears exactly once in the new files.
- `embed.sh` takes the runtime files, a `--`, then the `std` module files, and emits
  `EmbeddedSources.runtimeFiles` as (name, source) pairs; `//src/stdlib:runtime_files` is the filegroup.
- The white-box prepend parses each file as `runtime/<file>` (`runtimePrependFileNames`,
  `CompileSupport.swift`), and an ordinary module's weak-origin set lists those names.
- Six planner golden plans now list the ten files.
- Code comments and the internals docs point at the new files; task write-ups for finished tasks keep
  the old name, as a record of when they were written; open tasks were updated.
- Tests: the full tier (757 passed), `--check-reproducible` (1731 identical), the 18 Bazel test targets,
  and the `hello` binary's 174 symbols identical before and after.

