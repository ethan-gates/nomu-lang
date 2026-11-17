# Toolchain version manager

**Avenue:** Infra · **Type/Lifecycle:** `tooling` · **Size:** S · **Status:** done (257.1, 257.2) ·
**Source:** [262](262-collector-gaps.md), whose baseline needed the toolchain at an older commit, and the
copy built for it at a new path rebuilt LLVM from nothing.

An inventory of toolchains for compiler developers, local to one host, shaped like rustup with one source:
building the nomu-lang checkout. Each variant is built once, kept with a note of what it was built to try, and
found again later by path. It knows nothing about benchmarks; the comparison tools in
[265](265-compiler-dev-loop.md) take its paths.

## Plan

- **257.1 The inventory tool** (`tools/snapshot.py`). Done:
  - `publish --memo "…" [--label <name>]` builds `bazel build -c opt //src/nomu-cli:nomu` in the tree as it
    stands and stores the binary under `toolchains/<id>/` in the host cache's root (`NOMU_CACHE_DIR`, else
    `~/Library/Caches/nomu` on macOS, as `nomu` chooses it). It finds the binary with `bazel cquery`, so a
    `bazel-bin` repointed to fastbuild does not matter, and takes the identity from `bazel-out/stable-status.txt`,
    then checks that the binary carries it and that the tree did not change during the build.
  - `<id>` is the compiler identity from `tools/workspace_status.sh`: the commit, plus a hash of uncommitted
    changes when there are any. It is shortened for display. Publishing an identity already stored replaces
    its memo and label only.
  - Each entry holds the binary, the memo, the label, the full commit, the publish time and the uncommitted
    diff as a patch, so a variant built from a dirty tree can be read and rebuilt after the tree moves on.
  - `list` shows each entry's id, label, memo and age; `show <id|label>` its metadata and patch;
    `path <id|label>` the binary's path, which is how scripts and benchmarks use it.
  - `edit <id|label> [--memo] [--label]` changes an entry's memo or label; a label belongs to one entry and
    moves to the newest one given it.
  - `rm <id|label>` deletes one entry; `clear` deletes the `toolchains/` directory and nothing else of the
    host cache.
  - A reference is a label, an identity, or a unique prefix of one.
  - No default toolchain and no shim: a caller always names a path.
  - A toolchain is one `nomu` binary: the compiler, the build driver, the runtime and the prelude.
  - This replaces steps 1 to 3 of the comparison done by hand in [265](265-compiler-dev-loop.md): snapshot the
    toolchain before a change, and the old source never has to be copied back into the tree.
  - Builds for an older commit run in the main tree, checked out there. Bazel keys its output directory by
    workspace path, so a copy at another path (`git archive`, a worktree) starts with an empty cache and
    rebuilds LLVM (about 8 minutes); in place, only the targets whose inputs changed rebuild.
  - The script works on the checkout it runs in, so a commit older than the script takes a copy of it kept
    outside the tree (how 262.7 snapshotted `e994115`).
- **257.2** A `tools/README.md` entry for `tools/snapshot.py`. Done.

## Relations

- [265](265-compiler-dev-loop.md): `compiler-test --compiler` and the A/B runner take a snapshot's path.
- [256](256-host-cache-store-only.md): snapshots share the host cache safely, since its entries are keyed by
  compiler identity.
- [262](262-collector-gaps.md) 262.7 compares the toolchain at `e994115` with the current one through 257.1.
