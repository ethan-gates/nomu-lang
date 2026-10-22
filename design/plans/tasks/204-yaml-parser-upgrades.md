# YAML parser upgrades

**Avenue:** Infra · **Type/Lifecycle:** `tooling · evaluate` · **Size:** M · **Status:** evaluate — each item
taken up on its own trigger, below · **Source:** [200](200-yaml-parser.md), the items left open when it closed.

## What

The YAML library (`src/yaml`) is complete for its consumers ([163](163-manifest-yaml.md) manifests,
[198](198-build-configuration.md) configuration): the strict subset parses at 1.0–1.15 GB/s on configuration
files with every check kept, edits preserve comments, Codable decodes and encodes, and an equivalence corpus
pins the values. These items would make it faster in places no consumer exercises yet, or test it harder.
None blocks a consumer. Task 200's doc holds the design and the measurements these build on.

## Items

- **204.1** Fuzzing (was 200.10). Random and mutated inputs, checked for crashes and hangs, and for the
  parser and the diagnostic path agreeing at scale (`assertPathsAgree` already runs on 8,000 generated
  documents). No comparison against another YAML parser. *Ready to build.*
- **204.2** Duplicate-key hashing on the shared fast hash (was 200.11). Today's `KeyHash` is a word-at-a-time
  multiply-xorshift with SplitMix64 constants: untested for distribution, no final mix, a fixed seed. Hash
  quality affects only speed, since equal hashes always lead to a full key comparison. *Blocked* on
  [172](172-incremental-build-cache.md) question 7, which settles the hash.
- **204.3** Faster Codable, decoding and encoding (was 200.8.1). Decoding the synthetic packages runs at
  101 MB/s against 723 MB/s for the parse alone; what remains is Codable's own cost (a type-erasing box per
  keyed container, a metadata lookup per container, dynamic dispatch and an existential key per field).
  Encoding is unmeasured: it builds a `YAMLValue`, writes it through the edit renderer onto a placeholder
  document, checks each scalar spelling with a probe parse, and parses the result. Options: a small
  non-Codable reading protocol (`init(yaml:)` with typed field access) with hand-written readers for one or
  two hot types; an in-repo generator writing such readers per type (Swift macros need swift-syntax, a
  third-party dependency); for encoding, a direct writer with the spelling rules decided without probe
  parses. *Profile-guided:* taken up when a workload shows decoding or encoding mattering.
- **204.4** A reusable parser that keeps its output buffers across parses, as simdjson's does (was
  200.12.4). The 64 MB synthetic input parses at 0.58 GB/s, held back mostly by first-touch page faults on
  the ~4 bytes of output per input byte. Matters for large files and batches of files.
- **204.5** Calibration (was 200.12.4): simdjson on this machine, on a JSON form of the same data, outside
  the repo, so the 1 GB/s figures have a reference from the same hardware.
- **204.6** A position list in place of masks (was 200.12.4). Stage 1 would flatten its masks into the
  offsets of every candidate (line ends, plain stops, quotes) and the parser would walk them, with no mask
  shifts or loops at block boundaries. Against it: stage 1 writes about 1 byte per input byte more, and
  candidates inside quoted scalars, comments and block scalars must be stepped over. *Profile-guided:*
  taken up only if a profile shows the mask scans dominating; on the samples the parser's time is mostly
  structure and keys.

## Refs

- [200](200-yaml-parser.md) — the parser, its design, phases and measurements.
- `src/yaml/README.md`, `src/yaml/spec.md`.
