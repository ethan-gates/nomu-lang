# String Unicode views — scalar, grapheme, normalization

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · stdlib` · **Size:** L · **Status:** not
started — split out of [121 String/UTF-8 model](121-string-utf8-model.md) so 121 can close on the byte-level
type. The byte core it builds on (UTF-8 storage, `count`/`byte(at:)`/`bytePointer`, SSO) is **done** (121.1 +
121.2). · **Source:** the "layered Unicode API" half of 121, pulled out.

## Goal

Layer full Unicode interpretation on top of `String`'s UTF-8 byte core, without reshaping that core. The byte
layer stays the low-level unit a parser wants; scalar and grapheme semantics are **views** added here. This is
interpretation, not storage — every view reads the existing byte surface (`count` / `byte(at:)` /
`bytePointer`) and is agnostic to whether the bytes are `small`, `immortal`, or `heap`.

## Model (decided, carried from 121)

- **Bytes now, scalar/grapheme views layered.** UTF-8 bytes are the backing and the public low-level unit;
  Unicode scalars and grapheme clusters are views on top, so the type grows into full Unicode without
  reshaping its core. (Chosen over opaque-index-only from the start.)
- **No separate `Char` primitive.** A grapheme is a `String` (a small one); a Unicode scalar is a
  `UInt32`-carrying value from the scalar view. Revisit only if ergonomics demand it.
- **Opaque indices.** Scalar and grapheme indices are opaque, so variable-width access is never mistaken for
  O(1) byte indexing.

## Phases

- **184.1 — `UnicodeScalarView`.** UTF-8 decode, scalar iteration, an opaque scalar index. A scalar is a
  `UInt32`-carrying value. Pairs with [117 `for … in`](117-for-in-iteration.md) for `for scalar in s.scalars`.
- **184.2 — `GraphemeView` + normalization.** Grapheme-cluster iteration (a grapheme is a small `String`) and
  Unicode normalization — the correctness top layer. Needs the Unicode data tables (grapheme-break /
  normalization properties); how those tables are embedded is part of this phase.

## Dependencies & triggers

- **Built on:** [121 String/UTF-8 model](121-string-utf8-model.md) — the byte layer + SSO are complete; the
  views are storage-agnostic reads over `byte(at:)` / `count`. The heap buffer reserves header room for a
  cached scalar count and an `isASCII` fast-path flag (121 Representation), which these views populate/consume.
- **Couples with:** [117 `for … in`](117-for-in-iteration.md) — scalar and grapheme iteration are the natural
  `for … in` consumers (bounds-check-free by construction).
- **Unblocks / serves:** [163 manifest/YAML](163-manifest-yaml.md) and any text processing that needs
  Unicode-correct scalar or grapheme semantics (the byte-level parser already works without this).

## Refs

[121 String/UTF-8 model](121-string-utf8-model.md) (the byte core + the *Model* decisions this inherits);
`interfaces.md` (iteration protocol, when `for … in` lands).
