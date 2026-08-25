# Internals — the as-built design

**How the compiler and runtime actually work**, accurate to the code, for a dev or LLM making a
change. The detailed design, rationale, and invariants behind each subsystem.

Each doc maps to what's implemented; it cites code where that helps. For the programmer-facing
*intent* (shorter, faster to read), see [`../language/`](../language/readme.md); for exact detail,
the code itself. This is the middle fidelity — more exact than the contract, cheaper to read than
the source.

Today these are the full design docs (they carry both intent and internals); as the `../language/`
contract layer is authored, the programmer-facing intent distills up and out of here.
