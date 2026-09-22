# `comptime`

**Avenue:** Usability · **Type/Lifecycle:** `language-feature · needs-design` · **Size:** L ·
**Status:** needs-design (design not started) · **Source:** deferred.md (post-M9 raw list)

## What

Compile-time evaluation — run Nomu code at compile time (const evaluation, compile-time computation).
A whole feature; design not started.

## Notes

Adjacent to [macros](140-macros.md) (both are compile-time facilities) and to const/value generics (see
the const-generics fork in [SIMD](126-simd.md)). Whether `comptime` subsumes or complements those is an
open design question.

**Conditional compilation lands here (lean, from the modules design).** Platform/arch/build-mode
gating is intended to be a use-case of `comptime` — platform facts are comptime values and ordinary
`if` at comptime prunes branches (Zig model) — rather than a `#[cfg]`-style declaration-attribute
surface or a Go-style filename convention. Both of those alternatives are rejected: attribute
proliferation and filename-based gating are both disliked. Design the target/platform facts as
comptime-visible values when this is built.

## Refs

deferred.md "Post-M9 backlog" (`comptime`); [macros](140-macros.md), [SIMD](126-simd.md) (const generics).
