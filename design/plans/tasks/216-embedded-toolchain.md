# Embedded toolchain — `nomu` links, archives and gathers debug info in-process

**Avenue:** Infra · **Type/Lifecycle:** `driver · needs-design` · **Size:** M–L · **Status:** needs-design ·
**Source:** [214](214-link-caching.md)'s open item: the link and the runtime archive run system tools (`cc`, `ld`,
`ar`, `dsymutil`, `strip`, `codesign`) and read the SDK, so `nomu` depends on Xcode or the Command Line Tools,
and their versions enter cache keys by query (`Toolchain`). The model is Zig's: one download that links native
binaries with no system toolchain.

## What

`nomu` is a single binary. Everything a build runs is inside it: the linker, the runtime archive, debug-info
gathering, stripping, signing, and the system library stubs the link resolves against. The compiler's identity
(206) then covers the whole toolchain, and `Toolchain` and its record go away.

## Each tool and its replacement

The LLVM overlay `nomu` already builds from source has the libraries (`@llvm-project//lld:MachO`,
`//llvm:dsymutil-lib`, `//llvm:DWARFLinker`, `//llvm:ObjCopy`).

| Today | Embedded |
|---|---|
| `cc` + `ar` build `nomu-runtime.a` per host cache | Build the archive when `nomu` is built (a Bazel `cc_library` over the runtime's C and asm) and embed its bytes; the runtime archive's cache entry goes away |
| `cc` → `ld` | LLD's Mach-O linker in-process (`lld::macho::link`), with today's flags (`-dead_strip`, `-x`, `-sectcreate`, `-map`, `-oso_prefix`) |
| `dsymutil` | `dsymutil-lib` / `DWARFLinker` in-process |
| `strip -S` | ObjCopy, or the driver's own Mach-O rewrite (beside `FrameIndex` and `CodeSignature`) |
| `codesign` (fallback) | Removed: `CodeSignature` signs |
| The SDK's `libSystem.tbd` | Embedded stubs listing the symbols the runtime and emitted code import, generated from an SDK when `nomu` is built |

## Open questions

1. **The stubs' provenance.** Embedding stubs generated from Apple's SDK needs a reading of the SDK license; Zig
   ships such stubs. The fallback keeps everything else embedded and reads only the SDK from the Command Line
   Tools.
2. **ld64-specific code.** `FrameIndex` parses ld64's link-map format and `CodeSignature.resign` expects ld64's
   linker-signed signature; both are checked against LLD's output and adapted.
3. **Size.** `nomu` grows by LLD, DWARFLinker and ObjCopy; measure it per tool. The budget: under 100 MB on macOS
   (the Swift runtime is a shared library there) and under 160 MB on Linux (the Swift runtime linked statically);
   the release `nomu` is 57 MB today. Build time is no concern: Bazel caches the embedded tools, so they rebuild
   only when the LLVM pin moves. A `nomu` bootstrapped in Nomu is expected to be well under both budgets.
4. **Linux.** LLD's ELF port and a libc (musl, or glibc stubs) follow the same shape when a Linux target lands.

## Work

- **216.1** Embed the runtime archive, built with `nomu`; drop the host-cache runtime job.
- **216.2** Link with LLD in-process; adapt `FrameIndex` and `CodeSignature` to its output.
- **216.3** `dsymutil` and the debug-map strip in-process.
- **216.4** Embedded `libSystem` stubs (after question 1), with deployment target and SDK version fixed by `nomu`.
- **216.5** Remove `Toolchain` and the `tool:*` key inputs; the compiler's identity covers the toolchain.
- **216.6** Size check: the release `nomu`'s size against the budget (question 3), reported per added library.
- **216.7** Tests: a build with no developer directory selected (`DEVELOPER_DIR` pointing nowhere, no `/usr/bin`
  tools reachable) links and runs; the suite and `--check-reproducible` pass on LLD output.

## Refs

`linkBinary`, `cachedRuntimeArchive`, `runtimeArchiveRecipe` (`src/driver/sources/Driver.swift`); `Toolchain`
(`src/driver/sources/Toolchain.swift`); `FrameIndex`, `CodeSignature`; `bazel/llvm_extensions.bzl`.
