# Bazel friendliness

**Avenue:** Infra · **Type/Lifecycle:** `infra · needs-design` (driver + build orchestration) · **Size:** M ·
**Status:** needs-design · **Source:** raised deciding [190](190-explicit-module-builds.md) D4 (per-host cache).

## Deliverable

Nomu builds that Bazel can drive hermetically. Review where the driver reads and writes outside declared
inputs and outputs, and settle how Bazel supplies them.

## Work

- **Per-host cache.** 190 D4 places the runtime archive and the language workspace in a user cache
  directory with a `NOMU_CACHE_DIR` override. Decide how Bazel provides these: a prebuilt toolchain
  artifact, a declared output, or the override pointed into the execroot.
- **Explicit jobs as actions.** Each 190 job maps naturally to a Bazel action with declared inputs and
  outputs. Decide whether rules invoke one job per action or the whole plan.
- **Hermeticity.** Find remaining reads of host state (environment, `cc`, absolute paths in artifacts).
- **Relative paths in jobs** ([190](190-explicit-module-builds.md) 190.6 F17, moved here). A job file
  (`--emit-jobs`, the `nomu compile` input) holds absolute paths in every field that names a file: `files`,
  the `imports` keys, `outputs` (under `<workspace>/build/` or the host cache), each dependency's `.nmi` and
  `.bir` (often in the host cache), and the disk workspaces' `packageKey` (`<identity>|<absolute package
  root>`; the language workspace's is already `nomu.nomu|<nomu>/std`). A job therefore runs only where it
  was planned: moving the workspace makes `nomu compile` fail with `cannot read '…/main.nomu'`. Builds are
  unaffected, since the driver runs jobs in process. Decide the base each path is relative to (workspace
  root, host cache, execroot, the language workspace's `<nomu>`), and have the driver or the Bazel rule
  resolve it. `packageKey` is read only for a same-package check (`CompileJob`), so identity plus the
  workspace-relative root suffices.
- **Symlinks** ([190](190-explicit-module-builds.md) 190.6 F12, moved here). Goals: be restrictive, to
  prevent footguns; work in every Bazel execution mode. No other preference.
  - *Today.* The package walk skips symlinked directories; `pkg/…` resolution follows them; workspace roots
    and pins go through `realpath`; the entry path goes through Foundation's `standardizedFileURL`, which
    rewrites `/private/tmp` to `/tmp` (the mismatch behind 190.6 F29).
  - *What Bazel presents* (observed on this repository's Bazel build). The execution root used by
    unsandboxed (`local`) actions holds the workspace's top-level entries as symlinks, directories included
    (`src`, `build`, …), and every external repository under `external/` as a symlinked directory. A
    runfiles tree is real directories holding symlinked files. Sandboxed actions see a tree of real
    directories with one symlink per declared input file
    ([sandboxing docs](https://bazel.googlesource.com/bazel/+show/HEAD/site/en/docs/sandboxing.md)).
  - *Bazel's rule for tools:* do not resolve input symlinks; resolving finds undeclared inputs
    (non-hermetic) or breaks path comparisons
    ([Aspect](https://aspect.build/blog/things-a-program-must-not-do-under-bazel)).
  - *Elsewhere.* Go's package walks skip symlinked directories while explicit paths follow them (the same
    split as ours, left as is: [#9054](https://github.com/golang/go/issues/9054)). Node identifies modules
    by real path by default, and `--preserve-symlinks` keeps written paths at the cost of loading a module
    linked from two places twice. Cargo normalizes paths lexically, without resolving symlinks. SwiftPM
    stopped following symlinked source directories in 5.2 and users reported breakage.
  - *Options weighed.* (1) Never follow symlinked directories: simplest, but an unsandboxed execution root
    is made of them. (2) Follow them and identify modules by real path: no duplicates, but resolves inputs,
    against Bazel's rule. (3) Follow them, keep written paths (lexical normalization only, no `realpath`
    anywhere), and record each module or package directory's (device, inode): a second path to a seen
    directory is an error naming both, and a seen directory ends a walk (no cycles); one `stat` per
    directory. (3) fits both goals. Whether the planner's walk runs under Bazel at all depends on how rules
    drive Nomu (one `nomu compile` per action with explicit inputs needs no walk).
  - *Related:* [189](189-multi-remote-workspace-builds.md) may link fetched workspaces into place
    read-only from a shared cache, which this policy must allow.

## Dependencies & triggers

- Follows 190 (jobs, D4 cache). Interacts with [172](172-incremental-build-cache.md), whose content keys
  overlap Bazel's action cache.
