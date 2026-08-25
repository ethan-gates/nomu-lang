# Monomorphization cost model

**Avenue:** Infra (perf) · **Type/Lifecycle:** `perf · needs-grounding` · **Size:** S ·
**Status:** evaluate (deferred-only) · **Source:** deferred.md (2026-08-18)

## What

The code-size / compile-time cost of whole-program monomorphization (M5) — every generic instantiated
per concrete type — and the tradeoff against dictionary / witness-passing (which Nomu already has for
`any`).

## Assessment (2026-08-18): low far-reaching derivatives

A tuning knob — measure code-size / compile-time, and if it bites, offer witness-passing for
size-sensitive generics. The consequential version of this question is the
separate-compilation-vs-whole-program fork in the [modules](100-modules.md) item, which is where the real
decision lives.

## Roadmap assessment

**Deferred-only.** No wide derivative. Revisit if binary size becomes a problem (also relevant to the
[self-hosting](128-self-hosting-runtime.md) < 999 KB ceiling).

## Refs

deferred.md "Monomorphization cost model"; [modules](100-modules.md) (the real fork).
