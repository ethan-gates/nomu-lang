# Bazel friendliness

**Avenue:** Infra · **Type/Lifecycle:** `infra · needs-design` (driver + build orchestration) · **Size:** M ·
**Status:** needs-design · **Source:** raised deciding [190](190-explicit-module-builds.md) D4 (per-host cache).

## Deliverable

Nomu builds that Bazel can drive hermetically. Review where the driver reads and writes outside declared
inputs and outputs, and settle how Bazel supplies them.

## Work

- **Per-host cache.** 190 D4 places the runtime archive and the embedded `nomu` workspace in a user cache
  directory with a `NOMU_CACHE_DIR` override. Decide how Bazel provides these: a prebuilt toolchain
  artifact, a declared output, or the override pointed into the execroot.
- **Explicit jobs as actions.** Each 190 job maps naturally to a Bazel action with declared inputs and
  outputs. Decide whether rules invoke one job per action or the whole plan.
- **Hermeticity.** Find remaining reads of host state (environment, `cc`, absolute paths in artifacts).

## Dependencies & triggers

- Follows 190 (jobs, D4 cache). Interacts with [172](172-incremental-build-cache.md), whose content keys
  overlap Bazel's action cache.
