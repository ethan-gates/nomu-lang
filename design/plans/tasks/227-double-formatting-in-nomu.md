# Double formatting in Nomu — shortest round-trip, no libc

**Avenue:** Usability · **Type/Lifecycle:** `stdlib · language` · **Size:** M · **Status:** staged ·
**Source:** split from [223](223-retire-the-c-floor.md).6, which moved `print(Double)` out of C without
changing its algorithm.

## What

`print(Double)` prints the fewest significant digits that read back to the same value, always with a
decimal point (`42.0`). Since 223.6 a codegen-emitted function does this the way the C floor did: it tries
`snprintf("%.*g")` at increasing precision until `strtod` returns the value, up to 17 attempts per print.
This task replaces that with a shortest round-trip algorithm (Ryu or Schubfach) written in Nomu, in the
stdlib, which also gives `Double` a `String` form.

## Needs

Language surface, each needing agreement:
- the bit pattern of a `Double` as a `UInt64`;
- shifts (Nomu has `&`, `|`, `^` and no shift operator; division by power-of-two tables works but is slow);
- the high 64 bits of a 64×64-bit product (both algorithms multiply by 128-bit table entries).

## Tests

The `double` suite cases' output unchanged, plus a sweep against the libc loop over edge values
(subnormals, powers of ten, the largest and smallest finite values, values just past a rounding
boundary).

## Also gained

`snprintf` and `strtod` run on the carrier's stack through the platform layer's stubs
([104](104-fiber-stack-strategy.md) 104.3.3), about 0.7 ns a call (1.4% on `benchmarks/print_loop`). Nomu's own
routines run on the fiber's stack and drop that cost; measure `print_loop` before and after.
