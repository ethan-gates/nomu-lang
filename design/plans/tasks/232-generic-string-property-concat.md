# A `String` property read through a generic bound lowers to half a value

**Avenue:** Risk · **Type/Lifecycle:** `compiler · bug` · **Size:** S · **Status:** not started ·
**Source:** found while checking the untested demos in `examples/` for [231](231-suite-manifest-and-fixtures.md).

## What

`examples/generics/main.nomu` fails LLVM verification:

```
Call parameter type does not match function signature!
  %fld2 = extractvalue { i64, i64 } %shp.v1, 0
  call { i64, i64 } @…std7prelude6String6concat(i64 %fld2, { i64, i64 } …)
```

The failing line is `x.name.concat(x.draw())` in `fun describe<T: Drawable>(x: T) -> String`, where `name` is
a `String` property the interface requires (`var name: String { get }`). The receiver passed to `concat` is
the first word of the 16-byte `String` (`extractvalue … 0`), where the whole value is expected. The read of a
`String` field through a generic bound takes one word of the shaped value. No suite case covers the demo, so
the failure went unnoticed.

## Work

- **232.1** A minimal fixture in the suite reproducing it, then the fix in the lowering of a shaped field read
  on a generic receiver.

## Refs

`examples/generics/main.nomu`; [176 shaped GC roots](176-shaped-gc-roots.md) (the shaped `String` value).
