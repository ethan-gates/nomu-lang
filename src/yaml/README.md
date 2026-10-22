# yaml/

Nomu's YAML library: a strict subset of YAML 1.2 Core, read by the manifests and `cfg.yaml`. The format is
[spec.md](spec.md); the design and phases are in `design/plans/tasks/200-yaml-parser.md`.

- Standard library only (no Foundation). Errors are values carrying a stable code per spec rule.
- `YAMLDocument(parsing:)` is the entry point (`sources/Document.swift`); it throws every error found. After
  stage 1 (`Validate.swift`), the parser (`sources/Parse.swift`) handles stages 2–4 in one fused loop and stops
  at the first error. The diagnostic path then runs those stages separately (`lexLines`, `buildStructure`,
  `resolveScalars`) and reports every error with recovery. The two must agree: a rule changed in one is
  changed in the other, and `tests/ParseTests.swift` checks them.
- Edits (`sources/Edit.swift`): `YAMLEdits` turns operations into byte replacements and parses the result into
  a new document; bytes outside the edited values are kept exactly.
- Codable: `YAMLDecoder` (`sources/Decode.swift`) decodes in place with the Core types and rejects unknown keys;
  `YAMLEncoder` (`sources/Encode.swift`) writes through the edit renderer.
- `tests/corpus`: accepted documents with their hand-written Core values (`.expected`) and rejected ones with
  their errors (`.errors`); `CorpusTests.swift` describes the notation. Add a case for every rule change.
- Positions are byte offsets (`ByteSpan`); `LineIndex` resolves them to 1-based line and byte column.
- Vector code uses only the SIMD operations listed in `sources/SIMD.swift`; the rest lower to per-lane
  code. Benchmark: `bazel run -c opt //src/yaml/bench:yamlbench -- [megabytes] [iters] [file ...]`; it
  reports decimal MB/s, as simdjson does.
- `sources/CaseFolding.swift` is generated: `python3 src/yaml/tools/gen_casefold.py` (macOS, reads the system
  ICU).
