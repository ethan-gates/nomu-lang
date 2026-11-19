# Compiled-once performance

**Avenue:** Performance · **Type/Lifecycle:** `compiler · performance` · **Size:** L · **Status:** not started ·
**Source:** [253](253-finish-generics.md) 253.7, moved out once 253's correctness work was done.

## What

Generic code compiled once (the debug default, `mono: none`, and an exported generic's erased body in any build)
is a goal of its own, as specialized code is. Sizes are dictionary words read at entry (251.2.2); the rest of a
compiled-once body's cost has not been measured.

**Done means:** a compiled-once benchmark set exists, and each step below is measured against it and kept only for
what it saves.

## Steps

- **268.1** A compiled-once benchmark set, bounded generics included, built with `-c mono_none` and with
  `-c release -c mono_none`, beside the same programs specialized.
- **268.2** Precomputed field offsets and enum layouts in the dictionary, where a body now computes them from the
  witnesses.
- **268.3** Buffers reused: a copy in a loop allocates stack on every iteration; reuse the buffer and hoist its stack
  check.
- **268.4** The write barrier skipped by the witness's POD flag.
- **268.5** A closure made and called in compiled-once code goes through the call adapter, then the entry adapter,
  where a specialized call is one indirect call: the call adapter could check for an erased body's closure and call
  the body directly (251.2.4).

## Refs

`generics.md`; `backend.md` §4; [251](251-erased-generic-objects.md); [253](253-finish-generics.md).
