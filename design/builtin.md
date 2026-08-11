# Adding a C-backed builtin

How to add a builtin method, property, or free function whose implementation lives in the C runtime
floor, and wire it through the compiler. This is the path `concat`, the numeric `.double` / `.int`
conversions, and `Array.count` / `Array.append` already take.

**The lexer and parser need no changes.** Method-call syntax `recv.name(args)`, property syntax
`recv.name`, and free-call syntax `name(args)` already lex and parse into `.member` / `.call` AST nodes
for any receiver. A builtin is added by intercepting in **Sema** (desugar to a named builtin call),
lowering in **codegen** (emit the C call), and providing the **C function**. Three seams, plus a
safepoint classification.

Worked example below: a method `str.byteAt(i) -> Int` on `String`.

## 1. Runtime (C)

Declare in `src/runtime/runtime.h`, define in `src/runtime/core.c` (the pure value floor) — or
`runtime.c` for privileged/blocking primitives.

```c
// runtime.h
int64_t rt_str_byte_at(String s, int64_t i);

// core.c
int64_t rt_str_byte_at(String s, int64_t i) {
    if (i < 0 || i >= s.len) rt_bounds_trap(i, s.len);
    return (int64_t)(unsigned char)s.data[i];
}
```

`String` is `{ char* data, int64_t len }` (runtime.h); it is passed by value.

## 2. Sema — intercept by receiver type, desugar to a `__builtin` call

Type-check the receiver, then, keyed on its type, emit a call to a reserved builtin name
(`__strByteAt`) that codegen recognizes. The receiver is passed as the first argument.

**Method** (`str.byteAt(i)`) — in `checkCall`, after `let recv = checkExpr(base)`, next to the
`Array` method branch (`case .array`):

```swift
if recv.type == .string {
    switch name {
    case "byteAt":
        let idx = coerce(checkExpr(args[0].value, expected: .int), to: .int)
        let callee = IRExpr(type: .void, span: span, kind: .varRef("__strByteAt"))
        return IRExpr(type: .int, span: span, kind: .call(callee: callee,
            args: [IRArg(label: nil, value: recv), IRArg(label: nil, value: idx)], typeArgs: []))
    default:
        diags.error("value of type 'String' has no method '\(name)'", at: span)
        return IRExpr(type: .error, span: span, kind: .intLit(0))
    }
}
```

**Property** (`str.length`) — same shape, but in `checkExpr`'s `.member` case, next to the numeric
`.double` / `.int` conversions. No argument list; the receiver is the sole builtin argument.

**Free function** (`foo(a, b)`) — instead register a signature in the prelude and lower by name:
`funcs["foo"] = FnSig(params: […], ret: …)` (see `concat`), then a `case "foo"` in codegen.

## 3. Codegen — recognize the name, emit the C call

In `lowerCall`'s name switch (`Lowering.swift`, alongside `concat` / `__int_double_double`):

```swift
case "__strByteAt": return lowerStrByteAt(args, span)
```

The helper, mirroring `lowerConcat`:

```swift
private func lowerStrByteAt(_ args: [IRArg], _ span: Span) -> LLVMValueRef? {
    guard let s = lowerExpr(args[0].value), let i = lowerExpr(args[1].value) else { return nil }
    let (fn, ty) = runtimeFn("rt_str_byte_at", ret: i64, params: [strTy, i64], varArg: false)
    return buildCall(fn, ty, [s, i])
}
```

`runtimeFn` declares/caches the extern; `strTy` is the codegen `{ i8* data, i64 len }` matching the C
`String`. Return `Int` → `i64`, `Bool` → `i1`, `Double` → `f64`, `String` → `strTy`.

## 4. Codegen — safepoint classification

In `exprHasSafepoint` (`Lowering.swift`), classify the builtin. A pure C leaf that does not allocate
GC memory or block is **not** a safepoint — recurse into its arguments only:

```swift
case "__strByteAt": return args.contains { exprHasSafepoint($0.value) }
```

If the builtin instead **returns a heap `String`, allocates GC memory, or blocks**, it is not a leaf:
return `true`, and a returned managed value must go through the immortal / managed-buffer path (the
open String heap-boxing work, Q6 — see `c-types.md`). A raw heap pointer must never be held by C
across an allocation under the moving collector.

## Touch-point summary

| Seam | File | What |
| --- | --- | --- |
| C function | `runtime.h` + `core.c` (or `runtime.c`) | declaration + definition |
| Sema intercept | `Sema.swift` | method → `checkCall`; property → `checkExpr` `.member`; free fn → `funcs[…]` prelude |
| Codegen lower | `Lowering.swift` | `case "__name"` in `lowerCall` + a helper using `runtimeFn` |
| Safepoint | `Lowering.swift` | a `case` in `exprHasSafepoint` (leaf vs. allocating/blocking) |

No lexer or parser change is needed.

## Existing examples to copy

- **Free function:** `concat` (`Sema` prelude `funcs["concat"]`, `lowerConcat`, `rt_str_concat`).
- **Property-style conversion:** `Int.double` / `Double.int` (`Sema` `.member` intercept,
  `lowerIntToDouble` / `lowerDoubleToInt`, `llvm.round` + `rt_print_double` for the print seam).
- **Method with args + GC:** `Array.append` (`Sema` `.array` branch, `lowerArrayAppend`) — note it is a
  safepoint (`true`) because the buffer grow allocates.
