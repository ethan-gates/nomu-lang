# Adding a C-backed builtin

How to add a builtin method, property, or free function backed by the C runtime floor, and wire it
through the compiler. There are two kinds:

- **C-leaf builtins** — a pure C function (no GC allocation, no blocking). These follow a naming
  convention and are dispatched generically through the `Builtins` registry: adding one is a C
  function, a one-line Sema branch, and one registry entry — no new codegen.
- **Codegen-native builtins** — lowered to LLVM directly, not a C call: `Array.append` (grows in
  codegen), `Array.count` (field load), `Int.double` / `Double.int` (`sitofp` / round). These keep an
  explicit `lowerXxx` + a `case` in `lowerCall`.

The lexer and parser need no change either way — `recv.name(args)`, `recv.name`, and `name(args)`
already parse into `.member` / `.call` for any receiver.

## The naming convention

A C-leaf builtin's mangled name encodes its whole signature and **is** its C symbol name:

    __<receiver>_<name>_<return>[_<arg>...]

e.g. `__string_eq_bool_string` = receiver `String`, method `eq`, returns `Bool`, one `String` arg — and
the C function is named `__string_eq_bool_string`. Because the name carries the signature, both Sema
and codegen read the types off it (`Builtins.signature` in `Builtins.swift`), so no case is hand-written
per builtin.

Worked example below: `str.byteAt(i: Int) -> Int`, mangled `__string_byteAt_int_int`.

## 1. Runtime (C)

Define the function under its mangled name in `core.c` (the pure floor) or `runtime.c`
(privileged/blocking). A `Bool` return is an `int64_t` 0/1 — codegen truncates it to i1, which keeps a
portable ABI (no platform boolean type).

```c
// core.c
int64_t __string_byteAt_int_int(String s, int64_t i) {
    if (i < 0 || i >= s.len) rt_bounds_trap(i, s.len);
    return (int64_t)(unsigned char)s.data[i];
}
```

`String` is `{ char* data, int64_t len }`, passed by value. A `runtime.h` declaration is optional —
codegen declares the extern itself.

## 2. Sema — intercept by receiver type, build the call from the registry

Type-check the receiver, then emit the builtin call through `BuiltinsSema`, which reads the return and
argument types off the mangled name.

**Method** (`str.byteAt(i)`) — in `checkCall`, in the `String` branch next to `Array`'s, after
`let recv = checkExpr(base)`:

```swift
if recv.type == .string {
    switch name {
    case "byteAt":
        let idx = coerce(checkExpr(args[0].value, expected: .int), to: .int)
        return BuiltinsSema.method("__string_byteAt_int_int", recv, [idx], span)
    default:
        diags.error("value of type 'String' has no method '\(name)'", at: span)
        return IRExpr(type: .error, span: span, kind: .boolLit(false))
    }
}
```

`BuiltinsSema.method` builds `.call(.varRef(mangled), [recv, args…])`, typed by the name's return.
Arg count/types are checked by the caller (which holds the diagnostic sink).

**Property** (`str.hash`) — the same, in `checkExpr`'s `.member` case, via
`BuiltinsSema.member(mangled, recv, span)` (no argument list).

**Free function** (`foo(a, b)`) — register a prelude signature `funcs["foo"] = FnSig(…)` and lower by
name (see `concat`); this is not part of the C-leaf registry.

## 3. Register it — one line, and that is the codegen wiring

Add the mangled name to `Builtins.cLeaf` in `Builtins.swift`:

```swift
static let cLeaf: Set<String> = [
    "__string_hash_int",
    "__string_eq_bool_string",
    "__string_byteAt_int_int",   // new
]
```

`lowerCall` routes any `cLeaf` name through the generic `lowerCLeafBuiltin`, which parses the signature,
maps each type to its LLVM type (`String` → `strTy`, `Int` → `i64`, `Double` → `f64`, `Bool` → i1 via a
truncated i64), and calls the same-named C symbol. No per-builtin codegen.

Codegen-native builtins that are **not** same-named C calls — `append`, `count`, the numeric
conversions — stay out of `cLeaf` and keep an explicit `case` + `lowerXxx` in `lowerCall`.

## 4. Safepoint classification

C-leaf builtins are pure leaves (no GC allocation, no blocking), and `exprHasSafepoint` already treats
every `cLeaf` name as a leaf (recurses into arguments only) — nothing to add. A builtin that **allocates
GC memory, returns a heap `String`, or blocks** is not a C-leaf: keep it out of `cLeaf`, give it an
explicit lowering, and return `true` from `exprHasSafepoint`. A raw heap pointer must never be held by
C across an allocation under the moving collector — this is why `Array.append` grows in codegen, and why
heap-returning string ops wait on Q6 (`c-types.md`).

## Touch-point summary

| Kind | C function | Sema | Codegen |
| --- | --- | --- | --- |
| **C-leaf** (pure C call) | mangled-name fn in `core.c` / `runtime.c` | one branch → `BuiltinsSema.member` / `.method` | one entry in `Builtins.cLeaf` — no code |
| **Codegen-native** (not a C call) | — | one branch building the `.varRef` call | explicit `case` + `lowerXxx` + an `exprHasSafepoint` case |

No lexer or parser change is needed.

## Existing examples to copy

- **C-leaf property:** `String.hash` → `__string_hash_int` (in `Builtins.cLeaf`; C `__string_hash_int`
  in `core.c`).
- **C-leaf method:** `String.eq(other)` → `__string_eq_bool_string`.
- **Codegen-native conversion:** `Int.double` / `Double.int` — `sitofp` / `llvm.round`+`fptosi`, explicit
  `lowerIntToDouble` / `lowerDoubleToInt`.
- **Codegen-native + GC:** `Array.append` — explicit, and a safepoint (`true`) because the buffer grow
  allocates.
- **Free function:** `concat` — prelude `funcs["concat"]`, `lowerConcat`, `rt_str_concat`.
