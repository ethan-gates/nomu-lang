# YAML parser — Nomu's own strict YAML subset

**Avenue:** Infra · **Type/Lifecycle:** `tooling · driver` · **Status:** done — 200.1–200.9 and 200.12.1–200.12.3; the open items moved to [204](204-yaml-parser-upgrades.md) · **Source:** [163](163-manifest-yaml.md) (manifests move to YAML)
and [198](198-build-configuration.md) G17 (configuration files are YAML).

## Deliverable

Nomu's own YAML parser, reading a strict subset of YAML 1.2 Core: block style only (`{}` and `[]` are the
sole flow forms), one-line scalars except block scalars, two-space indentation, and lossless
round-tripping. It owns the format: the subset, its parsing, and its error messages. Moving existing
formats over is 163; reading configuration files is 198.

## Format definition

The format is specified in [`src/yaml/spec.md`](../../../src/yaml/spec.md). Accepted documents mean the
same to every YAML 1.2 Core tool as to Nomu. The code under `practice/saml/` is a sketch for ideas only;
the library starts from scratch.

## Constraints

- The format is **declarative data**, never a program (the standing manifest rule, `modules.md` §Manifest).
- Reimplementable in Nomu for self-hosting, which favors owning a small strict subset over a large
  dependency.
- Configuration (198) needs source positions on parsed values, so the resolution report can say which file
  and line set a setting (198 G1).

## Design

**Location.** `src/yaml`, module `yaml`, laid out like `src/cli`: `sources/`, `tests/`, a `swift_library`
and a `swift_test`. It imports only the Swift standard library (no Foundation), which keeps it small and
fast and leaves nothing for a Nomu port to replace. `Codable`, `Decoder` and `Encoder` are standard-library
protocols, so Codable support needs no Foundation.

**The format is line-oriented.** Every scalar is one line except block scalars, indentation is a fixed two
spaces, and separators are exact, so each line is classified on its own. The only state carried between
lines is the level stack and whether a block scalar is open. No backtracking, no lookahead past a line.

**Pipeline.**
1. **Validate and index** (one SIMD pass): UTF-8 validation; rejection of forbidden characters (control
   characters, NEL, U+2028, U+2029, a BOM past offset 0, U+FFFE, U+FFFF); line endings (a CR must be
   followed by LF, one style per file). Output: line start offsets (`[UInt32]`). ASCII goes through
   64-byte vector blocks in simdjson's style: each byte class collapses to a 64-bit mask, and line starts
   come straight from the LF mask. A block holding non-ASCII is decoded byte by byte for 16 bytes before a
   block is retried. Swift's SIMD types lower to NEON only for a subset of operations (`SIMD.swift` lists
   it, checked against `-c opt` disassembly): comparisons, `SIMDMask` and the swizzle subscript become
   per-lane code, so comparisons are built from lane arithmetic and masks gathered with a multiply. With no
   table lookup, simdjson's lookup-table UTF-8 method is unavailable; non-ASCII takes the byte-by-byte
   decoder, the same split as simdjson's ASCII fast path.
2. **Lex lines** (a loop over lines, scanning through byte-class masks): indentation, line kind (blank, comment, marker, sequence item, mapping
   entry, scalar, block header, block content), spans for key, value and trailing comment, quoted scalars
   scanned within the line, exact-spacing checks. Output: one 32-byte `LineRecord` per line (kind, level,
   a packed shape byte, and `UInt32` offsets for key, value, comment and content), written once per line.
   Parallel arrays were the first plan; their per-field uniqueness and bounds checks held the lexer to
   615 MB/s, against 920 MB/s for one write per line. Scans jump between interesting bytes through
   simdjson-style 64-bit masks per 64-byte block (`LexMasks.swift`): non-space bytes for indentation, plain
   scalar stops (a tab, a colon before a separator, `#` after a space) and quote bytes. A block is
   classified when a scan first reaches it, from three loads (the block, and the block shifted one byte
   each way), so the neighbor conditions combine within lanes and each class takes one mask gather.
3. **Build structure**: walk the line records with a level stack. Each new level is exactly one deeper;
   one level holds mapping entries or sequence items, never both; every entry has a value; depth is at
   most 255; duplicate keys are rejected under case folding. Output: a node arena (kind, parent, first
   child, next sibling, line record index). Node kinds are mapping, sequence, scalar and entry; an entry's
   key is on its line and its one child is the value, so a mapping's children are its entries. `[]` and
   `{}` are a childless sequence and mapping.
   Duplicate keys compare decoded text under Unicode simple case folding. Each key keeps only a hash:
   plain ASCII keys (nearly all) hash straight from the source eight bytes at a time, folding with SWAR;
   other keys are decoded (`ScalarText.swift`) and folded through a table generated from ICU
   (`tools/gen_casefold.py`, `CaseFolding.swift`). Full keys are compared only when hashes match. A mapping
   past 32 keys indexes them in an open-addressing table.
4. **Resolve scalars**: typing and every rejection run eagerly at parse time (`True`, `+42`, `0x2a`,
   NaN, 64-bit overflow, float overflow, malformed escapes), since any of them rejects the document.
   String values (escape decoding, `''` collapsing, block folding and chomping) are built lazily, when
   read.

**Parser and diagnostic path.** Stages 2–4 exist twice. The parser (`Parse.swift`) fuses them into one
loop per line and stops at the first error; every valid document goes through it alone. The diagnostic
path runs them as separate stages (`Lex.swift`, `Structure.swift`, `Resolve.swift`) and recovers after
each error, so a broken file reports every error; it runs only after the parser stops. Both implement the
same rules and give identical output on valid documents, which `ParseTests.swift` checks; a rule changed
in one is changed in the other.

**Lossless representation.** The line records and the node arena together are the lossless syntax tree.
The spacing rules fix most of a line's bytes, so a record accounts for every byte; the variable spans
(space before a trailing comment, a comment line's indentation, block content) are recorded. An unmodified
document renders by writing out the original buffer. A tree of token and trivia objects (Roslyn,
rust-analyzer) was set aside: the format places whitespace in few places, so the records suffice.

**API layers.**
- **Document API** (the base): values with byte spans, comments, and offset-to-line/column through a
  binary search over line starts. Comment-preserving edits (spec §25.2) go through it: changing one value
  changes only its bytes. 198 reads `cfg.yaml` here, since its qualified keys (`opt release`) are dynamic
  and layer resolution must tell an unset setting from one set to its default.
- **Codable on top**: `YAMLDecoder` decodes a document into `Decodable` structs, building strings as
  fields read them and checking Core types (a quoted `"42"` given to an `Int` field is an error).
  Unknown keys are rejected by default: the decoder tracks which keys each container read and reports the
  rest. While decoding it records a side table from each coding path to its source span. `YAMLEncoder`
  writes a fresh document from an `Encodable` value (new files, such as `nomu init`'s); it has no comments
  to keep, so updates to an existing file go through the document API. The manifests (163) fit Codable
  directly.

**Errors.**
- An error is a value the library returns, never prints (as `src/cli` does): a stable code (an enum case
  per rule, such as `trailingWhitespace`, `unaryPlus`, `duplicateKey`, `invalidUTF8`, each tied to a spec
  section), a byte span (two `UInt32`), a message, and an optional fix ("quote it: `\"True\"`", "did you
  mean `inline`?"). Tests assert codes, so messages can be reworded freely.
- Line and column are computed when rendering, from the line starts. Columns count bytes, 1-based,
  matching the compiler (`SourceMap.location` in `src/support`); a language server can convert from the
  stored offset.
- A parse collects errors, up to a cap of about 100. Stage 1 stops after invalid UTF-8, since line
  boundaries past bad bytes cannot be trusted. Stage 2 and stage 4 errors are independent and all
  reported. After a stage 3 structure error, the parser skips to the next line at the same or a shallower
  level, so one mistake does not cascade.
- Decoding uses the library's own error type, carrying the span (from the coding-path side table), the
  code and the coding path; Codable's `DecodingError` has no position. Unknown keys are collected across
  the whole decode and reported together, each with an edit-distance suggestion from the struct's keys. A
  type mismatch or missing key ends the decode, as Codable's `init(from:)` requires.
- Rendering is one line, matching the compiler: `cfg.yaml:4:9: error: unary '+' is not allowed; write
  42`. A source-and-caret form may come later without changing the error value. The library does not
  depend on `src/support`; the driver adapts YAML errors to its `Diagnostic`.

**Testing.**
- Unit tests per stage in `src/yaml/tests`. Stage 1 covers every forbidden character, every malformed
  UTF-8 shape, and multibyte characters straddling a 32-byte SIMD chunk boundary. Stage 4 is table-driven
  over every accepted and rejected spelling in spec §12–§16. Error tests assert code and span, never
  message text.
- Losslessness: rebuild the bytes from the line records alone and compare to the input (rendering an
  unmodified document from the buffer proves nothing).
- Semantic equivalence: a corpus under `src/yaml/tests/corpus`, each case an input file plus its expected
  value, written by hand. The expected encoding keeps the distinctions plain JSON loses (integer versus
  float, infinity), so it is a typed form. Cases focus on where equivalence is subtle: block scalar folding
  and chomping, double-quoted escapes, and Core typing. The few yaml-test-suite cases inside the subset
  (mainly block scalars) may be copied in, since their expected values were checked by the suite's
  authors. Set aside: depending on the whole suite (most of its cases use features the subset rejects),
  and generating expected values with a reference parser (the subset is small enough to check by hand).
- A benchmark target like `src/bench/parsebench`: throughput on large generated files.
- The test target may use Foundation (`JSONSerialization` for expected values); the library stays
  Foundation-free.
- Follow-up phase: fuzzing (the parser never crashes) and differential testing of accepted documents
  against a reference YAML 1.2 parser. Needs Linux (Apple's macOS toolchain ships no libFuzzer) or an
  external parser.

**Not planned.** Parallel lexing: configuration files are small, and block scalars cross lines, which
complicates splitting the input.

## Phases

- **200.1** Scaffold `src/yaml` (Bazel targets, `sources/`, `tests/`), move the spec to
  `src/yaml/spec.md`, and define the error type. *Done:* `ByteSpan`, `LineIndex`, `YAMLError` (a code per
  spec rule, span, message, fix, compiler-format rendering) and `YAMLErrors` (collection capped at 100);
  `//src/yaml:yaml_tests` green.
- **200.2** Stage 1: SIMD validation and the line index, with its tests and the benchmark target.
  *Done:* `Validate.swift` (stage 1), `SIMD.swift` (64-byte blocks, arithmetic comparisons, multiply
  movemask), `Buffer.swift` (growable buffer with batch reservation); `//src/yaml/bench:yamlbench`
  (synthetic inputs or given files). Tests cover every error, every malformed UTF-8 shape, block-edge cases,
  and a randomized check of the vector path against the byte-by-byte path. Throughput (`-c opt`, arm64):
  4.7 GB/s on 64 MiB of ASCII configuration text, 3.9 GB/s with a non-ASCII character every ~270 bytes,
  4.9–5.1 GB/s on the 17–146 KB samples in `practice/saml`. Measured along the way: the byte-by-byte path
  alone runs 1.4 GB/s, SWAR words 3.2 GB/s, and `Array.append` of line starts cost about 30%.
- **200.3** Stage 2: the line lexer and line records, with the lossless rebuild test. *Done:* `Lex.swift`;
  one error per line (later ones on the line are follow-ons); block scalar content owned by its key or
  dash (the spec's rule was corrected from "the indicator's line"); new codes `sequenceOnKeyLine`,
  `mappingOnValueLine`, `emptyKey`, `reservedIndicator`. Tests cover every line form, every stage 2 error,
  block scalar ownership, and rebuilding seven documents (CRLF, BOM, no final break, block scalars,
  comment gaps) from records alone. 0.92–1.08 GB/s on synthetic input and the samples, which all lex
  cleanly, with a byte loop for scanning (200.4 replaced it with masks).
- **200.4** Stage 2 speed: byte-class masks. *Done:* `LexMasks.swift` (non-space, plain-stop and quote
  masks per 64-byte block, built lazily as scans reach a block; the quote mask only when a quoted scalar is
  scanned); records written in place into the result array (the line count is known), which removes a copy
  of every record; error reporting and indicator handling kept out of line, with a bitmap test passing
  ordinary first characters. A test lexes documents behind prefixes of every length from 2 to 131 bytes and
  checks records and errors move only by the shift. Throughput (`-c opt`, arm64): 1.39–1.60 GB/s on the
  samples (from 1.01–1.25) and 1.22 GB/s on synthetic input (from 0.94). The synthetic lines average 18
  bytes, so per-line work dominates: after the change, mask classification is about 15% of samples and the
  rest is the per-line branches in `lexLine`, `lexEntry` and `lexNode`. Measured along the way: six masks
  per block (one gather per class, neighbors shifted in the mask domain) cost 27% of samples; three loads
  with one gather per class brought it to 15%.
  Two spec rulings land with it: tabs are permitted in comment text (§4, §22), and a block scalar with no
  non-blank content line is rejected (`emptyBlockScalar`, §20). YAML reads the latter as an empty string,
  but it looks like a value left out; `""` is the way to write one.
- **200.5** Stage 3: structure and the node arena, including duplicate keys and error recovery. *Done:*
  `Structure.swift`, `ScalarText.swift` (quoted-key decoding, simple case folding; stage 4 will reuse the
  decoder), `CaseFolding.swift` and its generator. New codes `bareScalar` (a scalar line with no key or
  dash inside a collection) and `contentAfterRootScalar`. Recovery: after an error, lines deeper than the
  failing line are skipped; an error where an owed value belongs marks it so it is not also reported
  missing; an indentless sequence is reported once, skipping its dash lines; a document-level error
  (`multipleDocuments`, content after `...` or after a root scalar) ends the walk. Stage 2 change: a block
  header alone on an indented line (`key:` then `|` below) takes the lines indented at least as far as its
  content, so stage 3 reports one `valueOnNextLine` instead of an error per line; `practice/saml/sample.yml`
  uses that form and now gets exactly that error. Tests cover every structure error, recovery, the arena's
  links, and duplicate keys through each hashing path. Throughput (`-c opt`, arm64): 0.96 GB/s on synthetic
  input, 1.22–1.79 GB/s on the samples. Measured along the way: copying and folding every key's bytes into
  per-mapping storage, with `Array` writes and a `Dictionary` of arrays, ran at 370 MB/s; hashes only
  reached 810 MB/s, and word-at-a-time hashing with the open-addressing table 955 MB/s.
- **200.6** Stage 4: scalar typing and rejections, and lazy string decoding. *Done:* `Resolve.swift`
  (`resolveScalars`: a `ScalarType` per node, every typing rejection, `nonStringKey`, and escape checks
  for double-quoted keys and values) and the read path in `ScalarText.swift` (quoted decoding through one
  escape decoder shared with the checks; block scalars with folding and clip, strip and keep chomping;
  CRLF content reads as LF). Every casing of `true`, `false`, `null`, `.inf` and `.nan` other than the
  lowercase one is rejected, beyond the Core spellings the spec listed; the spec now says so and gives the
  exact numeric-looking patterns (§12–§15). A plain key that types as a non-string is `nonStringKey`; a
  rejected spelling as a key reports its own code. Numbers are parsed again when read (`integerValue`,
  `floatValue`), so the arena carries only a type byte per node. Tests are table-driven over §12–§16's
  spellings plus near misses, every escape, and block scalar folding and chomping; the folding cases,
  including the YAML 1.2.2 example 8.10, match Ruby's Psych. Throughput (`-c opt`, arm64): 2.0–3.7 GB/s,
  ahead of stages 2 and 3.
- **200.7** Document API. Decisions:
  - `parse` throws the error list; a document exists only for valid input.
  - The public model holds values, keys and spans; comments stay in the source bytes and line records,
    so rendering an unedited document returns its bytes exactly.
  - Nodes are handles into the arena, valid for the document they came from.
  - Key lookup matches exact decoded text, linearly up to 32 entries and through an index past that.
    Case-variant keys are already duplicate-key errors, so a folded lookup would only add leniency.
  - An edit is a byte range and its replacement. A batch of edits is sorted, checked for overlap, and
    copied into a new buffer in one pass; the result is parsed again, which returns a new document and
    retires the old handles. A whole re-parse runs at about 1 GB/s; incremental re-parsing waits for a
    profile that needs it.
  - Comments on their own lines stay where they are. A trailing comment goes with its line: removed
    with it, and moved with it when keys are sorted.
  - New and changed strings are written plain when the plain spelling lexes as one scalar and types as a
    string; otherwise single-quoted when the text has no line breaks or characters that need escapes;
    otherwise double-quoted. A quoted value whose new text can be plain loses its quotes. An option
    replaces this default, for example to always double-quote.
  - Multi-line text keeps the style it was parsed in, block or double-quoted. A block scalar falls back
    to double quotes when the new text holds a character a block cannot (a carriage return or a control
    character). New multi-line text is double-quoted until it has two line breaks or its double-quoted
    spelling passes 40 bytes, then written as a `|` block with the chomping indicator its ending needs.
    An encoder option chooses always-block or always-double-quoted instead.
  - **200.7.1** Read API: `parse`, typed values, key lookup, iteration, spans with line and column.
    *Done:* `Document.swift`. `YAMLDocument(parsing:)` runs the four stages and throws `YAMLErrors`;
    `YAMLNode` is the document plus a node index, with `kind`, typed accessors (`string`, `integer`,
    `float`, `boolean`, `isNull`, each nil for another type), `items`, `entries`, `count`, `[key]`,
    `[position]`, `span` and `location`. A mapping past 32 entries (16 when first built) is looked up through stage 3's
    duplicate-key table, which stage 3 now keeps instead of discarding: the table holds entry nodes by
    folded-key hash, so a lookup hashes the folded query and compares exact decoded text. Indexing keys
    a second time in the document had cost 25% of a whole parse. Spans: a block scalar runs from its
    header to its last non-blank content line; a collection from its first key or dash to the end of its
    last value. Throughput (`-c opt`, arm64, synthetic): a whole parse at 341–347 MB/s, against
    375–383 MB/s for the four stages chained without a document.
  - **200.7.2** Edits: set, insert and remove, key sorting, scalar spelling, rendering. *Done:*
    `Edit.swift`. `YAMLEdits` collects operations on a document (`set` a value, `set` a key in a mapping,
    `remove` a key or an item, `append` to a sequence, `sortKeys`) and `apply` turns them into byte
    replacements, copies once, and parses the result into a new document; `YAMLDocument.replacing` takes
    raw replacements. `YAMLValue` describes new values, with literals (`["a": 1, "b": [true]]`), and
    `YAMLStyle` overrides quoting (always double-quoted) and multi-line style (always block, always
    double-quoted). Operations in one batch must not overlap. Choices made here:
    - Comments inside a removed or replaced value go with it; own-line comments outside it stay. Removing
      the first entry of `- k: v` moves the next entry onto the dash line.
    - A collection emptied by removals becomes `{}` or `[]`; appending to `{}` or `[]` writes block
      style. A mapping given as a sequence item puts its first entry on the dash line.
    - A value moving onto its key's line keeps the line's trailing comment after it (`a: v # c`).
    - Every spelling except double-quoted is verified by parsing a one-entry probe document, so a
      spelling is used only when it reads back exactly; this replaces a hand-kept list of what plain and
      single-quoted scalars may hold. Blocks fall back to double quotes when they cannot hold the text (a
      leading space on the first line, a carriage return, nothing but line breaks).
    - An edit reaching the end of a file without a final line break adds one, so a block scalar written
      there keeps its last line break. NaN cannot be written and makes `apply` throw `notANumber`.
    Tests: exact-text cases for every operation, and a property test that writes random value trees
    (awkward keys and strings: Core-typed words, colons, `#`, quotes, multi-line text, escapes) through
    the renderer, reads them back, then applies random edits and compares against a model; it found that
    a `|+` block's trailing empty lines are content, which edits must keep with it. 400 rounds run in the
    suite; 4,000 with another seed passed once.
- **200.8** Codable: `YAMLDecoder` with unknown-key rejection and the span side table, then `YAMLEncoder`.
  *Built:* `Decode.swift` and `Encode.swift`. The decoder reads the parsed document in place (option A of
  the decoding question): containers are node handles, a plain or escape-free quoted string is built
  straight from the source, numbers are parsed from checked spellings, and key lookup keeps a cursor per
  mapping, since fields are usually decoded in file order. Types are the Core types a YAML 1.2 parser
  resolves, so a decoded value means what the document means to any such parser: `42` is an integer and
  is rejected for a `Double` (fix: write `42.0`), as a quoted `"42"` is for an `Int`. Unknown keys are rejected by default (`unknownKeys: .ignore` turns it off): each
  entry read is marked, and when decoding ends every unread entry of a mapping decoded as a keyed
  container is an `unknownKey` error, its fix suggested from the keys the container asked for and did not
  find. In place of a side table recorded while decoding, `YAMLDocument.node(at: codingPath)` finds the
  node of any decoded value on demand, so decoding pays nothing for spans. The encoder builds a
  `YAMLValue` and writes it through the edit renderer (`encodeValue` hands one to `YAMLEdits`), with
  `sortedKeys` for Swift dictionaries' unstable order.
  Throughput, decoding the 1 MB synthetic input into `[String: Package]` (`-c opt`, decimal MB/s): parse
  alone 723 MB/s, parse and decode 101 MB/s. The first version ran at 71; coding paths built only for
  errors and nested decoders, strings built without a copy, per-node tables in raw memory (no exclusivity
  checks) and word-wise key comparison gave the rest. What remains is Codable's own: a type-erasing box
  allocated per keyed container (`_KeyedDecodingContainerBox`), a generic metadata lookup per container,
  dynamic dispatch and an existential `CodingKey` per field, and coding-path arrays for nested values.
  Codable stays the decoding API: decoding takes microseconds for the manifests and `cfg.yaml` files that
  read it, and the shared parse is where speed counts.
  - **200.8.1** Faster decoding and encoding: moved to [204](204-yaml-parser-upgrades.md) 204.3.
- **200.9** The hand-written equivalence corpus. *Done:* `tests/corpus`, run by `CorpusTests.swift`. 35
  accepted documents, one or more per spec area (documents, lines, structure, keys, plain scalars, each
  Core type, quoted and block scalars), each with the value a YAML 1.2 Core parser gives it, written by
  hand from the spec as a typed tree (`int 42`, `float 42.0` and `str "42"` differ); 64 rejected documents
  with every error the parse reports, as line and code. Writing them found four cascades in the diagnostic
  path, each now one report: a `%YAML` directive counted as content, so the `---` after it was a second
  document; a deeper line with a key under a plain value was called a multi-line plain scalar (now
  `indentationJump`); a line holding a stage 1 error (a lone CR) was lexed again; and a tab-indented line
  left the key above it reported as missing a value.
  Checked once against the yaml-test-suite data (no other parser, nothing kept in the repo): of 402 cases,
  all 94 invalid ones are rejected, 268 valid ones fall outside the subset, and the 40 inside it give the
  suite's values, typing included, except one: a block scalar running to the end of a file without a
  final line break, which the suite reads as ending with a line break and the 1.2.2 grammar does not. Such
  a file is now rejected (`blockScalarAtEndOfFile`, spec §20), so an accepted document has one meaning
  under either reading.
- **200.10** Fuzzing: moved to [204](204-yaml-parser-upgrades.md) 204.1. Differential testing against
  another parser was dropped; the corpus (200.9) and the parser-against-diagnostic-path checks cover it.
- **200.11** Duplicate-key hashing on the shared fast hash: moved to [204](204-yaml-parser-upgrades.md) 204.2.
- **200.12** The shared core at ≥1 GB/s. Every parse runs stages 1–4, whichever API reads the result
  (document, Codable, generic values), so they get a budget of 1 ns per byte, single-threaded, with every
  check kept; work one API needs (decoded strings, number values, lookup indexes, Codable containers) stays
  outside it, lazy or layered on top. Today the core costs about 2.5 ns per byte on synthetic input (stage 1
  0.21, lex 0.82, structure 1.03, resolve 0.47). The plan follows simdjson: stage 1 validates UTF-8 and
  marks candidate positions in the same pass over each block (line ends, end of indentation, a colon before
  a separator, a dash before a space, `#` after a space, quotes); then one loop per line takes the
  candidates that apply in context and lexes, builds structure and types scalars, writing records and nodes
  once. Candidates are positions only: quotes and `#` can sit inside plain scalars and comments, and nothing
  is structural inside a block scalar, so stage 1 cannot settle them as simdjson settles strings.
  - **200.12.1** Spike. First, add the classes to stage 1 and run today's lexer on the precomputed masks,
    to see whether moving classification pays for itself. Then a fused per-line loop for the common line
    shapes (`key: value`, `- item`, comments, blank lines), as masks and as a position list, to find the
    per-line cost reachable. Calibrate against simdjson on a JSON version of the same data, on this
    machine, outside the repo.
    *Findings* (`-c opt`, arm64, MB/s with MB = 2²⁰ bytes):
    - Lane comparisons (`.==`, `.<`) reinterpreted as a vector at once lower to one `cmeq` or `cmhi` in
      Swift 6.3; `SIMD.swift`'s arithmetic compares took five instructions. Switching sped stage 1 from
      4.7 to 5.4 GB/s and the lazy lexer from 1.17 to 1.27 GB/s.
    - Stage 1 now walks blocks aligned to offset 0, so it can hand the lexer one set of classes per block;
      blocks holding non-ASCII take the vector path too, with only multibyte characters decoded one by one.
    - Classifying in stage 1 costs 0.15 ns per byte (5.4 → 3.0 GB/s) and saves the lexer about as much
      (1.27 → 1.49 GB/s): a wash for the staged pipeline, about 1.0 ns per byte for both either way.
    - The fused loop (`Spike.swift`, checked equal to the staged pipeline's records, nodes and types)
      runs at 826 MB/s alone on the synthetic input, 638 MB/s with stage 1 (1.57 ns per byte, against
      2.9 for the staged parse). On the sample files with stage 1: 1019 MB/s on `naruto.yaml` (146 KB),
      810 on `hp.yml`, 756 on `aircraft.yml`, against 462–562 staged.
    - Its cost on the synthetic input, by switching parts off: lexing 0.48 ns per byte, duplicate keys
      about 0.3 (typing each key, hashing, comparing in small mappings), the 240,000-key root's hash table
      0.1 (cache misses; real files have no such mapping), value typing about 0.15 after fast paths for
      the common first bytes, exact words and short integers, node building about 0.15, stage 1 0.33.
    - Not covered: escapes, quoted keys, a BOM and every error decline to the staged path; the position
      list and the simdjson calibration were not run.
  - **200.12.2** The fused parser, first called the fast path. *Done:* `Parse.swift` fuses stages 2–4
    into one loop over the lines of a document stage 1 accepted, reading stage 1's classes and writing
    records, nodes, types and key tables once, in arrays built in place. It accepts exactly what the separate stages accept, with
    identical output; at the first error it stops and `YAMLDocument` runs the separate stages, now the
    diagnostic path, which report every error with recovery (simdjson stops at the first error; the
    diagnostic path adds the full report, at the cost of a second pass only for a broken file). The
    diagnostic path is also the reference: every document the Lex, Structure and Resolve tests build is
    checked through both paths (`assertPathsAgree`), and so are 8,000 generated documents, about 1,200 of them valid;
    injected faults (a skipped duplicate check, a mistyped scalar) fail hundreds of those checks. Whole
    parse through `YAMLDocument` (`-c opt`, arm64, MB = 2²⁰ bytes): 958 MB/s on `naruto.yaml`, 748 on
    `hp.yml`, 694 on `aircraft.yml` (462–562 staged); 508 on the 64 MB synthetic input (345 staged),
    where about a third of the gap to the in-cache rate is first-touch page faults on the ~4 bytes of
    output each input byte produces.
  - **200.12.3** Tuning toward 1 GB/s on the samples. *Done.* The benchmark now reports decimal MB/s
    (10⁶ bytes), the unit of simdjson's GB/s figures; entries above use 2²⁰. Whole parse through
    `YAMLDocument` (`-c opt`, arm64, best of 9, each file parsed repeatedly in cache, as simdjson
    measures): 1.15 GB/s on `naruto.yaml`, 1.03 on `aircraft.yml`, 1.01 on `hp.yml`; 0.58 on the 64 MB
    synthetic input, where first-touch page faults remain. Changes, in the order measured:
    - Stage 1 computes one class, plain-scalar stops, with a separator test of one `cmhi` (any byte up
      to a space; documents stage 1 accepted hold no other controls). The parser finds indentation a
      word at a time and builds a quote mask for the 64 bytes from where a quoted scalar is scanned,
      without caching it (a cached, aligned mask made the scan's state mutable and cost more than it
      saved). The diagnostic path's lexer classifies its own blocks again (`LexMasks`), with the exact rules.
      Stage 1 went from 2.7 to 4.3 GB/s on `naruto.yaml`.
    - Floats without an exponent of at most 300 integer digits type without parsing (`Double(String)`
      ran for every float to rule out overflow): `aircraft.yml` 787 → 868 (MB = 2²⁰).
    - A mapping indexes its keys past 32 entries instead of 16: each index cost three allocations and a
      dictionary insert, about 10% on `aircraft.yml`.
    - A 256-bit filter per open mapping, one bit per key from its hash, skips the duplicate scan for a
      key whose bit is clear: about 10% on `aircraft.yml` and `hp.yml`.
    - Stage 1's per-block step inlined: 4.0 → 4.7 GB/s.
  - **200.12.4** The reusable parser, the simdjson calibration and the position list: moved to
    [204](204-yaml-parser-upgrades.md) 204.4–204.6.

## Consumers

- [163](163-manifest-yaml.md) — `pkg.json` and the other JSON formats move to YAML.
- [198](198-build-configuration.md) — configuration files.

## Refs

- StrictYAML, KDL, Yams (Swift YAML).
- simdjson UTF-8 validation: Keiser and Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte".
- yaml-test-suite, a source of block scalar cases to copy into the corpus.
