# YAML Subset Specification

## 1. Scope and Compatibility

This format defines a strict subset of YAML 1.2 using the Core schema.

The format is intended for documents read by both machines and people. Its requirements cover the document's parsed value, its human-readable source content, and preservation of that source content during round-tripping.

Every accepted document must satisfy the following requirements:

1. It is valid YAML 1.2.
2. Its machine-readable value is identical to the value produced by a YAML 1.2-compliant parser using the Core schema.
3. It introduces no additional implicit scalar types or alternate interpretations.
4. Comments and source representation are preserved as required by this specification.

The parser may reject valid YAML 1.2. It must never accept input and assign it a meaning different from its YAML 1.2 Core meaning.

Being a compliant subset serves one purpose: any accepted document means the same thing to every YAML 1.2 Core tool, such as editor and language-server tooling and YAML libraries, as it does to this format. Equivalence is with YAML 1.2 Core only. Tools that apply YAML 1.1 rules may read some accepted spellings differently (`yes`, `010`, `12:30:00`); this format follows YAML 1.2 Core and accepts that difference.

The guiding principle is:

> Match normal YAML behavior when it is unambiguous, useful, and inexpensive to support. Otherwise, simplify or reject it.

A feature that is unsupported must be rejected rather than accepted with a different interpretation.

Code examples may use comments to annotate the resulting value or type. These annotations are explanatory unless the example is specifically illustrating comment preservation.

## 2. Encoding and Character Validity

### 2.1 UTF-8

Input must be valid UTF-8. UTF-16 and UTF-32 input are unsupported.

Malformed UTF-8 must be rejected. Invalid byte sequences must not be replaced with replacement characters or otherwise silently repaired.

A UTF-8 byte-order mark (BOM) is permitted at the beginning of a file. A literal U+FEFF anywhere else is rejected; a double-quoted string can still express it as `﻿`.

A file is at most 2³² − 1 bytes, so every byte offset, including the offset of the end of the file, fits in 32 bits.

### 2.2 Permitted Source Characters

Literal source characters must belong to the printable character set permitted by YAML 1.2:

* U+0009 (TAB), U+000A (LF), and U+000D (CR)
* U+0020–U+007E
* U+0085
* U+00A0–U+D7FF
* U+E000–U+FFFD
* U+10000–U+10FFFF

All other literal code points are rejected. This includes disallowed control characters, surrogate code points, U+FFFE, and U+FFFF.

Three characters in that set are also rejected as literals: U+0085 (NEL), U+2028 (LINE SEPARATOR), and U+2029 (PARAGRAPH SEPARATOR). YAML 1.2 treats them as ordinary characters, while many editors draw them as line breaks, so a line could look broken while parsing as one. A double-quoted string can express them as `\N`, `\L`, and `\P`.

These restrictions apply throughout the source, including comments and quoted or block scalar content.

Valid YAML escape sequences may represent characters that are not permitted literally in the source, subject to the escape rules in this specification. An escape must not represent an invalid Unicode scalar value.

## 3. Documents

A file contains at most one YAML document.

The root value may be a mapping, sequence, or scalar. Scalar-only documents are valid:

```yaml
hello       # string: "hello"
```

```yaml
42          # integer: 42
```

```yaml
true        # boolean: true
```

```yaml
null        # null
```

The optional YAML document start and end markers are supported:

```yaml
---
name: Alice
...
```

Each marker stands alone on its line, optionally followed by a comment. Content on a marker line, such as `--- value` or `--- |`, is rejected. After `...`, only comments and blank lines may follow.

A file containing more than one document is rejected.

YAML directives, including `%YAML` and `%TAG`, are unsupported.

An otherwise empty document is rejected. A document containing only comments, blank lines, or document markers is empty.

## 4. Whitespace and Lines

Newlines are meaningful line boundaries.

Lines end with LF or CRLF, one style per file. A file that mixes the two is rejected, and so is a lone CR. The original line endings are preserved during lossless round-tripping.

The last line may end with or without a line break; round-tripping preserves which.

Horizontal whitespace must have a syntactic or content-related purpose. It may be used for:

* Structural indentation.
* Token separation.
* Separation before a comment.
* Scalar content.

Empty lines are permitted.

A line containing only horizontal whitespace is rejected unless that whitespace is part of the content of a block scalar.

Trailing horizontal whitespace at the end of a line is rejected, except within block scalar content. Any amount of space between content and a following comment is permitted.

Tabs never separate tokens. A tab is permitted only inside quoted scalars, block scalar content, and comment text (§22).

Whitespace that affects scalar content or document structure must never be silently discarded.

For example, this is valid:

```yaml
name: Alice

age: 30
```

Spaces separating a scalar from a comment are part of the source representation:

```yaml
name: Alice    # string: "Alice"
```

## 5. Structural Indentation

Structural indentation uses spaces only. Tabs are forbidden in structural indentation.

Each level of structural nesting is exactly two spaces. The width is fixed, so a parser never detects it, and every document is indented the same way:

```yaml
root:
  child:
    value: 42
```

Any other indentation is invalid:

```yaml
root:
    child: 42
```

```yaml
root:
  child:
    value: 42
   other: 10
```

The two-space width also fits a mapping that begins on a sequence item's line: `- ` is two characters wide, so the mapping's keys sit one level deeper than the dash (§7).

Nesting is at most 255 levels deep, so a level fits in 8 bits.

Indentation within a block scalar is scalar content indentation, not structural indentation, and follows the block scalar rules (§21).

## 6. Mappings and Keys

Mappings use block-style key-value pairs:

```yaml
name: Alice
age: 30
```

An entry is spelled `key: value`: no space before the colon, and exactly one space after it when a value follows on the line. These are rejected:

```yaml
name : Alice
name:  Alice
```

Mapping keys must be strings. A key is on one line and at most 1024 characters long, as YAML requires of keys written without `?`.

Supported key forms are plain, single-quoted, and double-quoted scalars. Because YAML Core implicitly resolves plain scalars, an unquoted key that would resolve to a non-string value under the Core schema must be rejected as a key. Quote the key to express it as a string:

```yaml
"true": enabled
"42": answer
"null": empty
```

Empty keys are permitted only when explicitly quoted:

```yaml
"": value
```

Complex mapping keys and explicit complex-key syntax using `?` are unsupported. A `?` is an indicator only when followed by a space or line break; elsewhere it follows YAML's lexical rules, so `?foo` and `what?` are ordinary plain scalars.

Duplicate keys are rejected case-insensitively after decoding. Quoted and unquoted keys conflict when their decoded string values match under Unicode simple case folding (the locale-independent `C` and `S` mappings of `CaseFolding.txt`).

For example, this is invalid:

```yaml
name: Alice
"name": Bob
```

This is also invalid:

```yaml
name: Alice
Name: Bob
```

A mapping value must be explicitly provided. A bare mapping entry with no value is rejected:

```yaml
name:
```

Use `""` for an empty string, `[]` for an empty sequence, or `{}` for an empty mapping.

A comment after the colon does not supply a value. This is valid, because a nested collection follows:

```yaml
name: # the user's name, split in parts
  first: Alice
```

This is rejected, because nothing follows:

```yaml
name: # no value
```

## 7. Sequences

Sequences use explicitly indented block-style entries. A sequence indicator `-` is followed by exactly one space when a value follows on its line, or by the line break (or a comment) when the value is a nested collection below it. `-   one` is rejected.

```yaml
items:
  - one
  - two
  - three
```

Indentless sequences are unsupported. The sequence must be indented relative to its parent:

```yaml
items:
- one
- two
```

Nested sequences may not begin on the same line as their parent sequence item.

This is unsupported:

```yaml
matrix:
  - - a
    - b
```

This is supported:

```yaml
matrix:
  -
    - a
    - b
```

Sequences of mappings are supported:

```yaml
users:
  - name: Alice
    age: 30
  - name: Bob
    age: 40
```

The expanded form is also supported:

```yaml
users:
  -
    name: Alice
    age: 30
  -
    name: Bob
    age: 40
```

A sequence item must have a value, by the same rule as a mapping entry (§6). A bare `-` with nothing on its line and no nested collection below it is rejected, with or without a trailing comment.

## 8. Empty Collections and Flow Style

The format uses block-style YAML, with two exceptions for empty collections.

The empty sequence `[]` and empty mapping `{}` are supported:

```yaml
items: []
options: {}
```

These are the only supported flow-collection forms, spelled exactly `[]` and `{}`. Inner whitespace, as in `[ ]` or `{ }`, is rejected.

Non-empty flow collections are rejected:

```yaml
items: [a, b]
```

```yaml
options: {a: 1}
```

The distinction between an empty string and an empty collection must remain explicit:

```yaml
name: ""
items: []
options: {}
```

A bare mapping value such as `items:` is not an alternative representation of an empty value or collection; it is rejected.

## 9. Plain Scalars

Plain scalars follow YAML 1.2 lexical rules, subject to the restrictions in this specification.

Indicator characters are interpreted contextually. They are not globally forbidden after a plain scalar has begun.

For example:

```yaml
value: -foo
```

The value is the string `-foo`.

```yaml
url: https://example.com/path
```

The value is a string.

```yaml
name: Alice:Bob
```

The value is a string.

A colon followed by whitespace terminates a plain scalar where required by YAML's lexical rules.

A plain scalar must not be accepted as a string if YAML Core would resolve it to another type. If that spelling is unsupported by this format, it must be rejected; otherwise, quote it when a string is intended.

### 9.1 Single-Line Scalars

Every plain and quoted scalar begins and ends on one physical line. Only block scalars (§20) span lines.

A mapping value starts on the same line as its key unless it is a block collection. A scalar value on the line after its key is rejected:

```yaml
key:
  value
```

A plain scalar continued onto a following line is rejected. YAML would fold this into the single string `hello world`:

```yaml
key: hello
  world
```

Use a block scalar for multi-line text.

## 10. Comments and Human-Readable Meaning

Comments are meaningful parts of this format. They can explain intent, document constraints, and provide information that is not represented by the parsed mapping, sequence, or scalar values.

A `#` begins a comment at the beginning of a comment position or when preceded by separation whitespace, according to YAML's lexical rules.

A comment may end any line except a line of block scalar content, where `#` is content. A block scalar's header line (`|`, `>-`, and so on) carries no content, so it may end with a comment. A comment on its own line may be indented by any number of spaces; comment indentation is not structural.

For example:

```yaml
name: Alice # The user's display name
```

The parsed scalar value is `Alice`, but the comment remains part of the document.

A `#` within a plain scalar is preserved when YAML's lexical rules treat it as scalar content:

```yaml
url: https://example.com/path#fragment
```

```yaml
value: foo#bar
```

Quoted strings treat `#` as literal content:

```yaml
value: "this contains # literally"
```

Comments, their placement, and their text must be preserved by lossless round-tripping. Their significance to human readers must not be dismissed merely because they do not contribute to YAML Core's abstract data value.

## 11. Implicit Scalar Typing

Implicit scalar resolution follows the YAML 1.2 Core schema, subject to the format's explicit rejection rules.

The supported implicit types are:

* String.
* Integer.
* Float.
* Boolean.
* Null.

A scalar that matches a Core implicit type receives that type. A scalar that matches none of those types is a string.

This format introduces no additional implicit types.

When a scalar would receive a non-string Core type but a string is intended, it must be quoted.

If a Core-recognized spelling is explicitly excluded by this format, it must be rejected rather than reinterpreted as a string.

## 12. Integers

Integers follow YAML 1.2 Core integer semantics for accepted spellings. Only decimal integers are accepted, with an optional leading `-`:

```yaml
42          # integer: 42
-42         # integer: -42
001         # integer: 1
```

An integer must fit in a signed 64-bit integer (−2⁶³ to 2⁶³−1). An integer outside that range is rejected; YAML libraries disagree on such values, some reading a big integer, some a float, some an error.

The following spellings are rejected. Quote them when a string is intended:

```yaml
+42         # unary plus
0x2a        # hexadecimal (an integer under Core)
0o52        # octal (an integer under Core)
-0x2a       # signed hexadecimal (a string under Core)
0X2a        # uppercase prefix (a string under Core)
0b1010      # binary (a string under Core, an integer under YAML 1.1)
1_000       # underscores (a string under Core, an integer under YAML 1.1)
```

Each reads to a person as a number, so accepting the Core string meaning would surprise a reader, and decimal covers every integer value.

Precisely, a plain scalar is rejected as numeric-looking when, after an optional sign, it is `0x`, `0o` or `0b` (either case) followed by only digits of that base and underscores, or when it contains underscores, does not start with one, and would be a decimal integer or float with them removed (`1_000`, `1_0.5`, `1__`). Otherwise it keeps its Core meaning: `0xyz`, `0b2` and `2026_report` are strings.

## 13. Floats

Floating-point values follow YAML 1.2 Core semantics, with an optional leading `-`:

```yaml
3.14
.5
1.
1e10
-2.5E+03
```

These are floating-point values under the Core schema. A float is an IEEE 754 double-precision value, rounded to nearest. A finite spelling whose value would round to infinity, such as `1e400`, is rejected.

A unary `+` is rejected, as for integers (`+1.5`, `+.inf`).

Of YAML Core's special values, only infinity is accepted, in lowercase:

```yaml
.inf
-.inf
```

NaN is rejected in every casing, with or without a sign (`.nan`, `.NaN`, `.NAN`, `.Nan`, `-.nan`). Every casing of infinity other than `.inf` is rejected rather than reinterpreted as a string (`.Inf`, `.INF`, `-.iNf`).

Other spellings that YAML Core would resolve as floats must either be supported with the same meaning or rejected. They must not be accepted as strings.

## 14. Booleans

Only lowercase boolean spellings are accepted:

```yaml
true
false
```

These represent boolean values.

Every other casing is rejected, including those YAML Core reads as strings:

```yaml
True
TRUE
False
FALSE
tRUE
```

They are not reinterpreted as strings. To express these words as strings, quote them:

```yaml
"True"
"FALSE"
```

## 15. Null

Only lowercase `null` is accepted as an implicit null value:

```yaml
null
```

`~` and every other casing of `null` are rejected, including those YAML Core reads as strings:

```yaml
Null
NULL
~
nULL
```

They are not reinterpreted as strings. To express these values as strings, quote them.

## 16. Other Scalar Types and Numeric Compatibility

Timestamp-looking values remain strings under the YAML 1.2 Core schema:

```yaml
2026-10-04
12:30:00
```

No timestamp type is introduced.

Binary values are not implicitly recognized as a separate type. Explicit binary tags such as `!!binary` are unsupported.

YAML 1.1-specific implicit typing is not applied. Spellings that YAML 1.1 typed differently take their YAML 1.2 Core meaning: `yes`, `no`, `on`, `off`, sexagesimal forms such as `12:30:00`, and the merge key `<<` are strings, and `010` is the integer 10. Binary and underscore forms are the exception, rejected as numeric-looking (§12).

More generally, when a scalar spelling has a meaning under YAML 1.2 Core, this format must preserve that meaning or reject the spelling. It must not accept the spelling with a different type or value.

## 17. Single-Quoted Strings

Single-quoted scalars follow YAML single-quoted string semantics.

An apostrophe is represented by doubling it:

```yaml
name: 'O''Brien'
```

The resulting string is `O'Brien`.

Backslashes have no special escape meaning in single-quoted strings.

Single-quoted strings must begin and end on the same physical source line. Multiline single-quoted strings are rejected.

## 18. Double-Quoted Strings

Double-quoted strings must begin and end on the same physical source line. Multiline double-quoted strings are rejected.

The standard YAML 1.2 escape sequences are supported:

```text
\0  \a  \b  \t  \n  \v  \f  \r  \e
\   \"  \/  \\  \N  \_  \L  \P
```

Here, `\ ` represents an escaped space.

Unicode escapes are supported:

```text
\xHH
\uHHHH
\UHHHHHHHH
```

The required number of hexadecimal digits must be present.

Unicode escapes must represent valid Unicode scalar values. Surrogate values and values greater than U+10FFFF are rejected. Any additional character restrictions on escaped values must follow YAML 1.2's escape rules rather than imposing source-literal restrictions on the escape's resulting value.

Unknown or malformed escape sequences are rejected.

For example:

```yaml
value: "\n"
```

The escape represents a newline in the resulting string. It does not continue the physical source line.

Tabs may occur directly in quoted strings where YAML permits them, or be represented using `\t`.

## 19. Quoted Scalar Boundaries

After a quoted scalar closes, only YAML-permitted separation or a comment may follow.

Valid:

```yaml
name: "Alice" # comment
```

Invalid:

```yaml
name: "Alice"xyz
```

An unterminated quoted scalar is a parse error.

## 20. Block Scalars

Literal block scalars use `|`:

```yaml
message: |
  hello
  world
```

Folded block scalars use `>`:

```yaml
message: >
  hello
  world
```

Literal scalars preserve ordinary line breaks according to YAML block-scalar semantics.

Folded scalars apply YAML's folding rules, converting appropriate adjacent line breaks into spaces while preserving the significance of blank lines and more-indented lines.

Both forms support YAML chomping indicators.

### Clip

With no chomping indicator:

```yaml
message: |
  hello
```

The resulting scalar uses clip chomping, which retains a single trailing line break when the scalar's content has a final line break.

### Strip

```yaml
message: |-
  hello
```

Strip chomping removes trailing line breaks from the resulting scalar.

### Keep

```yaml
message: |+
  hello
```

Keep chomping preserves trailing line breaks in the resulting scalar.

The same chomping rules apply to folded scalars.

Explicit block-scalar indentation indicators are unsupported:

```yaml
|2
>4
```

The header line holds only the indicator, its optional chomping indicator, and an optional comment (§10). Content starts on the next line.

A block scalar has at least one non-blank content line. A header followed only by blank lines before a less-indented line or the end of the document is rejected, although YAML reads it as an empty string: it reads as a value that was left out. Write an empty string as `""`.

```yaml
message: |
next: 1
```

A file that ends inside a block scalar ends with a line break. YAML 1.2 readers disagree on whether the end of the input stands for a final line break: the grammar ends the last line at "a line break or the end of input", while the YAML test suite reads `|` followed by `  x` at the end of a file as `"x\n"`. Requiring the line break gives the scalar one meaning under both readings.

## 21. Block Scalar Indentation

Block scalar indentation follows YAML 1.2 block-scalar indentation semantics. It is distinct from structural collection indentation.

The first non-blank content line is indented exactly two spaces deeper than the node that owns the block scalar: the key for `key: |`, the dash for `- |`, and the key again for `- key: |`, whose key sits two columns right of the dash. That column is the content indentation, the same one YAML's inferred-indentation rules would find. Leading blank lines do not establish it. Later lines may be more indented, and their additional indentation is content. A non-blank line indented less than the content indentation ends the block scalar.

For example:

```yaml
message: |
  hello
    world
```

The resulting scalar is:

```text
hello
  world
```

A first content line indented by any other amount is rejected:

```yaml
message: |
    hello
```

Because indentation indicators are unsupported, content whose first line begins with spaces cannot be written as a block scalar; use a double-quoted string with `\n` escapes.

Tabs are permitted in block scalar content, subject to character validity and YAML's rules.

A root block scalar is supported. Once a block scalar indicator is encountered in a valid scalar position, subsequent lines are interpreted according to block-scalar rules rather than being treated automatically as nested collections.

## 22. Tabs

Tabs are forbidden in structural indentation.

Tabs are permitted in scalar content, including quoted strings and block scalar content, where YAML 1.2 allows them.

Tabs are permitted in comment text, after the `#`. A tab cannot separate a value from its comment.

The general character-validity requirements still apply.

## 23. Collection Structure

Collection nesting is determined by YAML 1.2 block-structure rules, restricted by the indentation and collection rules in this specification.

After a collection item, subsequent meaningful lines determine whether the current collection continues, a nested collection begins, or the current collection terminates. Blank lines and comments are permitted where YAML allows them and must be preserved.

Structural nesting is two spaces per level.

Block scalar content is interpreted according to block-scalar rules and must not be mistaken for collection structure.

The format does not support indentless sequences or nested sequence indicators on the same line as a parent sequence item.

## 24. Unsupported YAML Features

The following YAML features are unsupported:

* Anchors, such as `&name`.
* Aliases, such as `*name`.
* Tags, including `!foo` and `!!str`.
* Explicit typing.
* Non-empty flow collections.
* Indentless sequences.
* Explicit complex-key syntax using `?`.
* Complex mapping keys.
* Explicit block-scalar indentation indicators.
* Multiline quoted strings and multiline plain scalars.
* YAML directives.
* Multiple documents in a single file.
* Content on a document marker line.
* UTF-16 and UTF-32 input.
* Malformed UTF-8 and disallowed literal Unicode code points, including literal NEL, U+2028, U+2029, and a BOM past the start of the file.
* Lone CR line endings and mixed line endings.
* Hexadecimal, octal, and binary integers, numeric underscores, unary `+`, and NaN.
* Integers outside the signed 64-bit range and floats that overflow to infinity.

Empty flow collections `[]` and `{}` are the sole exceptions to the general prohibition on flow collections.

Rejecting a YAML feature must not result in the same source being accepted with different semantics.

## 25. Lossless Document Preservation

This format requires lossless preservation of the source document, independently of the parsed machine-readable value.

### 25.1 Unmodified Documents

If a document has not been modified, rendering it must reproduce the original input byte-for-byte.

This guarantee includes:

* Comments and their placement.
* Blank lines.
* Structural indentation and other whitespace.
* Line endings.
* Scalar spelling and quoting.
* Escape spelling.
* Document markers.
* The original UTF-8 BOM, if present.

Two source documents that produce the same YAML Core value may still be distinct documents under this format because their comments or source representations differ.

### 25.2 Modified Documents

When a document is modified, the modification must not silently discard or rewrite unrelated source content.

Comments and formatting outside the intended modification must be preserved. A change to a parsed value does not by itself authorize removing comments, normalizing line endings, changing quote styles, or reformatting other parts of the document.

The scope of an intentional modification determines which source content may change. Everything outside that scope remains subject to the preservation requirement.

### 25.3 Document Meaning

For this format, document meaning includes both:

1. The machine-readable value defined by YAML 1.2 Core.
2. The human-readable information conveyed by comments and source representation.

Lossless preservation is therefore a normative format requirement, not an optional rendering convenience.

## 26. Design Invariants

The format maintains the following invariants.

### YAML semantic compatibility

Every accepted document has the same machine-readable interpretation under YAML 1.2 Core.

### UTF-8 and character validity

Input is valid UTF-8 and contains only permitted literal source characters, except where YAML escape rules permit a character to be represented through an escape.

### Deterministic indentation

Structural indentation is two spaces per level, in every document, and block scalar content starts two spaces deeper than the key or dash that owns it.

### Bounded sizes

A file is at most 2³² − 1 bytes and nests at most 255 levels deep, so offsets fit in 32 bits and levels in 8.

### Visually explicit collections

Nested collections are structurally indented and visually distinguishable from their parents.

### Block-style syntax

Collections use block syntax except for the empty collection forms `[]` and `{}`.

### Core-schema typing

Implicit scalar typing follows YAML 1.2 Core. Unsupported Core-recognized spellings are rejected rather than assigned different types.

### Explicit strings when necessary

Values that would otherwise receive a non-string Core type must be quoted when a string is intended.

### Meaningful whitespace

Whitespace is never silently ignored when it affects structure, scalar content, or source fidelity.

### Human-readable meaning

Comments and source representation are meaningful parts of the document format and must be preserved.

### Lossless round-tripping

An unmodified document renders byte-for-byte identically to its original input.

### Simple rejection over ambiguity

When a YAML feature introduces substantial complexity without sufficient benefit, it is rejected rather than given a special interpretation.
