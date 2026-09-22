# Manifest format — switch from JSON to YAML

**Avenue:** Usability · **Type/Lifecycle:** `tooling · driver` · **Size:** S ·
**Status:** needs-design — deferred from modules ([100](100-modules.md)); JSON ships first

The package manifest ships as **JSON** initially (module work, 100.3.1) because it parses
dependency-free in the Swift host (Foundation). Switch it to **YAML** once the module system is in use,
for a human-friendlier authoring format (comments, less punctuation noise).

## Why

JSON is the pragmatic bootstrap — zero dependency — but it is a poor human-authoring format: no
comments, heavy punctuation. The manifest is human-authored (name, version, `sealed`, `bin`, tests,
later deps), so it wants a comment-bearing, low-noise format. This is a format swap over a stable
schema, not a schema change.

## Scope

- Pick the YAML flavor — likely custom strictyaml parser with flow-style and boolean literals added
- Keep the manifest **declarative data**, never a program (the standing rule from 100).
- Migration: read both during a transition, or a one-shot converter; the schema is unchanged.
- Consider self-hosting: whatever is chosen must be reimplementable in Nomu (favors owning a small
  strict subset over a large dependency).

## Dependencies

- Modules [100](100-modules.md) — the manifest schema and the JSON bootstrap it replaces.

## Refs

- Contract: [`../../language/modules.md`](../../language/modules.md) (Manifest section).
- StrictYAML, KDL, Yams (Swift YAML).
