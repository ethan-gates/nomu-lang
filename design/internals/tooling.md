# Tooling — query architecture

**Status:** working draft. The tooling-first stance and the query-based compiler architecture. Where this sits in the pipeline is in [`architecture.md`](architecture.md). Status tags: **Decided**, **Deferred**, **Open**.

## Tooling-first / query architecture — Decided (architectural commitment)

Architect the compiler **as a server** from early on — query-based, so an LSP can cheaply ask "what's the type here?", with incremental compilation and stable parser error-recovery.

Great tooling (Rust, TypeScript) comes from designing the compiler as a server early, not bolting an LSP on later. Tooling is one of Nomu's deltas over Nim and a first-class deliverable, so this is committed up front while it's still cheap.

**Same engine as fine-grained incremental compilation.** The query server and fine-grained incremental (intra-module, per-file — "20 files, edit 2, rebuild 2") are the *same* engine: memoized per-decl queries + fingerprint invalidation, memoizing against the interface/implementation module split ([`architecture.md`](architecture.md)). The soundness property that makes it work — **modular checking** (bodies depend only on referenced signatures) — is held today; the prerequisites (multi-file input, per-unit codegen, dependency/fingerprint layer) are unbuilt but not foreclosed. The one live blocker is the frontend's `exit(1)`-on-first-error path (`src/frontend/README.md`).

## Open

- **Incremental compilation + cached monomorphizations** — the shape that keeps LLVM iteration bearable; ties to the query architecture above and to monomorphization (`generics.md` §6). Backlog in `plans/deferred.md`.
