# A body that ends without `return` compiles and traps

**Avenue:** Risk · **Type/Lifecycle:** `compiler · bug` · **Size:** S · **Status:** not started ·
**Source:** found while testing [253](253-finish-generics.md) 253.3.6.

## What

A function or closure with a result type whose body can reach its end without `return` compiles, and traps at run
time when it does:

```
fun f(x: Int) -> Int {
    x * 2
}
let g = { (v: Int) -> Int in v * 2 }
```

Both build with no diagnostic, and calling either stops the program with `SIGTRAP`: the lowering ends such a body in
`unreachable`. The body reads like an expression body, which the language does not have, so the mistake is easy to make.

## Work

- **266.1** A compile error, at the body's end, when a body with a non-`Void` result can reach it without `return`.
  A suite case for each of a function, a method and a closure.

## Refs

`FunctionLowerer` (the `.unreachable` that ends such a body).
