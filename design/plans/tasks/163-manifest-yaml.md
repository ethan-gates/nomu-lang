# Manifest format — switch from JSON to YAML

**Avenue:** Usability · **Type/Lifecycle:** `tooling · driver` · **Size:** S ·
**Status:** needs-design — deferred from modules ([100](100-modules.md)); JSON ships first; waits on the
YAML parser ([200](200-yaml-parser.md))

The package manifest ships as **JSON** initially ([173](173-package-model-driver-cli.md) §173.1) because it parses
dependency-free in the Swift host (Foundation). Switch it to **YAML** once the module system is in use,
for a human-friendlier authoring format (comments, less punctuation noise).

## Why

JSON is the pragmatic bootstrap — zero dependency — but it is a poor human-authoring format: no
comments, heavy punctuation. The manifest is human-authored (name, version, `sealed`, `bin`, tests,
later deps), so it wants a comment-bearing, low-noise format. This is a format swap over a stable
schema, not a schema change.

## Scope

- The YAML flavor and its parser are [200](200-yaml-parser.md); this task moves existing formats onto it.
- Keep the manifest **declarative data**, never a program (the standing rule from 100).
- Migration: read both during a transition, or a one-shot converter; the schema is unchanged.

## Dependencies

- Modules [100](100-modules.md) — the manifest schema and the JSON bootstrap it replaces.
- YAML parser [200](200-yaml-parser.md) — the parser these formats move onto.

## Refs

- Contract: [`../../language/modules.md`](../../language/modules.md) (Manifest section).
- StrictYAML, KDL, Yams (Swift YAML).
