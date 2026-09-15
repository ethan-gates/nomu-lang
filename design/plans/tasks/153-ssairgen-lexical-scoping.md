# Lexical scoping of locals in SSAIR generation

**Avenue:** Infra · **Size:** M · **Status:** ready-to-build — the compiler-crash sub-case is fixed
(see below); the silent shadow-leak is open.

## What

`SSAIRGen` tracks locals in name-keyed maps (`slots`, `varType`, `currentDef`) with no lexical-scope
stack. A name reused across scopes is not properly disambiguated, so bindings from one scope leak into
another. Two symptoms, one root cause (no scope push/pop):

1. **Compiler crash (fixed).** A name bound as a value-aggregate (`let w = Wrap(...)` → a stack `slots["w"]`)
   in one scope and as a scalar (`var w = 0`) in a sibling scope kept the stale aggregate slot; `readVar`
   prefers `slots`, so `while w < 3` loaded a `Wrap` and emitted `ICmp(Wrap, Int)` — an LLVM
   `AssertOK` failure ("Both operands to ICmp instruction are not of the same type"). Fixed by making
   `bind` clear the opposite-kind binding on rebind (a scalar bind clears `slots[name]`; an aggregate bind
   clears `varType[name]`), so the latest binding wins by kind. This removes the crash but does not give
   correct lexical shadowing.

2. **Silent shadow-leak (open).** Nested shadowing binds the wrong value after the inner scope exits:
   ```
   fun main() {
       let w = 100
       var i = 0
       while i < 1 {
           let w = 5
           print(w)     // 5
           i = i + 1
       }
       print(w)         // prints 5 — should be 100
   }
   ```
   prints `55` instead of `5100`. The inner `let w` overwrites the SSA binding for the name and the outer
   `w` is never restored on block exit.

## Why

Correctness. Shadowing is accepted by Sema (it scopes names correctly — same-scope reuse of a `let` is a
proper error, sibling/nested reuse is legal), but the lowering flattens names and silently returns the
wrong value. This is a foundation bug: any program relying on lexical shadowing is miscompiled.

## How

Introduce real lexical scoping in `SSAIRGen`: a scope stack that, on block/scope entry, saves the current
name→binding state (`slots`/`varType`/`currentDef` entries for names it will rebind) and restores it on
scope exit. The `bind`/`readVar`/`lowerAssign` paths key off the innermost binding. The current
`bind`-clears-cross-kind fix becomes subsumed by proper save/restore. Cross-check against the SSA
construction (Braun) `currentDef`-per-block machinery so scope restore and block sealing compose.

## Repro / verification

The two snippets above (crash repro now compiles + runs correct; shadow-leak repro should print `5100`).
Add ssairgen unit tests for both, plus an example exercising nested and sibling shadowing across loops.

## Refs

`src/midend/ssairgen/sources/SSAIRGen.swift` — `bind` (the cross-kind fix), `readVar`, `write`, the
`slots`/`varType`/`currentDef` maps.
