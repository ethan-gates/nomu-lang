# Resource embedding (compile-time embed + explicit manifest include)

**Avenue:** Usability · **Type/Lifecycle:** `language-surface · modules` · **Size:** M ·
**Status:** needs-design (split out of modules [100](100-modules.md); lean recorded, not built)

Bundle non-source files (assets, templates, embedded data) into a package so they reach the
final program. Nomu emits a native binary, so the working model is **compile-time embedding into
the binary**, matching every AOT-native peer, rather than a runtime resource bundle shipped beside
the executable.

## Why

A native binary has no package directory to read at runtime, so resources a program needs at
runtime are embedded into the binary at build time. Two separable pieces:

1. **Embed intrinsic** — a compile-time mechanism that turns a resource in the package tree into
   embedded bytes in the binary (bytes / string / a read-only directory handle).
2. **Distribution selection** — which non-source files travel with a distributed package.

## Lean

- **Explicit include for distribution.** Files that ship with a package are listed explicitly in
  the package manifest (`include`/`exclude`), rather than Go's "whole tree by default." Matches the
  project preference for explicit, auditable manifests.
- **Native-embed model.** A compile-time embed intrinsic bakes the resource into the binary. The
  precedents: Go `//go:embed` + the `embed` package (`string`/`[]byte`/`embed.FS`), Rust
  `include_bytes!`/`include_str!` plus `include_dir`/`rust-embed` for directories, Zig `@embedFile`.

## Open questions

- Intrinsic spelling/surface — a builtin (`@embedFile`-style) vs a stdlib function vs an attribute.
  Adds language surface; needs agreement before any syntax is chosen.
- Embed result types — raw bytes, a UTF-8 string form, and a directory/manifest handle for embedding
  a whole subtree.
- Glob support in the manifest `include` and in a directory-embed intrinsic.
- Path resolution — resource paths resolved relative to the referencing source file vs the package
  root (flat layout, `import pkg/foo` → `<pkgroot>/foo`).
- Interaction with the build tool once external dependencies land: a resource embedded from a
  dependency package vs from the local package.

## Dependencies

- Modules [100](100-modules.md) — the package manifest (home of `include`/`exclude`) and the
  package tree the resource paths resolve against.

## Refs

- Go: `//go:embed`, `embed` package.
- Rust: `include_bytes!`, `include_str!`; `include_dir`, `rust-embed`; Cargo `include`/`exclude`.
- Zig: `@embedFile`.
