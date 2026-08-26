# Runtime Subset

**Status:** design draft (task 149). The mechanism that lets code *inside* the runtime avoid recursively
invoking the services it implements — no implicit GC allocation, no write barrier, no compiler-inserted
safepoint, and bounded stack growth. Nomu's analog to Go's `//go:nosplit` / `//go:nowritebarrier` /
`//go:noescape`. Status tags: **Decided**, **Leaning**, **Deferred**, **Open**.

**API scope.** The surface is **module-default subset + a narrow per-function keyword refinement**
(surface A, Decided with Ethan). The runtime tier is designated subset-by-default so the module-wide
constraints carry no in-source marker; the one per-function refinement (nosplit / bounded stack) is a
**keyword modifier** on `fun`, spelled `nosplit fun f()` (Leaning). No attribute grammar is introduced.
The marker appears only in privileged runtime code — user code never writes it, and the compiler refuses
it outside the runtime tier.

**Frame.** A hard prerequisite for writing any of the runtime in Nomu
([128](../plans/tasks/128-self-hosting-runtime.md)): without it the first line of the self-hosted
collector would call the collector. It governs the code that *uses* the 125 primitives, and it ships
before collector code ([150](../plans/tasks/150-selfhosted-gc-ladder.md)). It is frontend/compiler-
contained and independent of backend maturity, so it sits on the build-now critical path beside
[125](../plans/tasks/125-unsafe-raw-memory.md).

**Siblings:** the four emission points it suppresses live in `runtime.md` §6 (safepoint poll, write
barrier, mutator alloc) and `backend.md` (statepoints, the inlinable alloc/barrier/poll); the raw
primitives it hands runtime code are `unsafe-memory.md` (task 125); the tier separation it designates
against is `c-types.md` §6; the (undesigned) module system that will eventually own the designation is
`modules.md` (stub).

---

## 1. The problem

The runtime — GC and scheduler — is being written in Nomu. That code *implements* the services ordinary
Nomu code receives for free, so it cannot use them on itself. Four emissions the compiler normally
inserts would be self-referential inside runtime code:

1. **Implicit GC allocation.** Ordinary code allocates through `rt_alloc` (`runtime.md` §6). The
   allocator *is* that path; an allocator that allocated would recurse. Runtime code obtains memory
   through the 125 off-heap surface (`RawPtr.alloc`) instead.
2. **Write barrier.** Codegen emits `__nomu_write_barrier` on managed-pointer stores (`runtime.md` §6);
   the barrier code is what that call lands in. Barrier code emitting a barrier recurses. (Runtime code
   works over `addrspace(0)` raw memory, which has no managed stores to barrier.)
3. **Compiler-inserted safepoint.** Codegen drops `__nomu_poll` at loop back-edges so a fiber can be
   stopped for collection (`runtime.md` §6). Code running *during* a stop-the-world pause cannot itself
   hit a poll that tries to stop the world.
4. **Bounded stack (nosplit).** Functions that run where the stack cannot grow — a signal / STW context,
   or the stack-growth path itself — must fit in the guaranteed stack and skip the growth-check prologue.
   This one depends on the fiber-stack strategy ([104](../plans/tasks/104-fiber-stack-strategy.md),
   deferred), so it is partly forward-looking; the first three bite immediately.

Go hit the same wall and solved it with per-function pragmas. Nomu needs the same guarantee: a way to
mark code as runtime-subset, plus a compiler check that the marked code stays within the subset.

## 2. The constraints, and their grain

The four constraints split by grain, which is what shapes the surface:

- **Module-wide (three):** no implicit GC allocation, no write barrier, no compiler-inserted safepoint.
  These hold for the whole collector/scheduler tier uniformly. — the module default carries them.
- **Narrow (one):** nosplit / bounded stack applies to a subset of the subset (signal / STW / stack-
  growth-path functions) and depends on 104. — the per-function keyword carries it.

## 3. The surface (A)

**Module-default, designated at the tier boundary.** The runtime is already a distinct compilation unit
(`c-types.md` §6). Its functions default to the three module-wide constraints, so most collector code
carries **no marker at all** — the module boundary is the marker. The designation is attached at the
build / module level rather than in source: the runtime tier is a known, privileged compilation unit
compiled with the subset default on. (The module system that will own this cleanly is undesigned,
`modules.md`; the interim is a designated file set / compiler input. — **Open**, tracked there.)

**Per-function refinement — a keyword modifier.** The nosplit constraint is spelled as a keyword before
`fun`:

```
nosplit fun collectMinor() { … }
```

It fits the existing `fun`-declaration grammar (the `fun`-begins-its-line rule, `syntax.md` §2), adds no
attribute sublanguage, and appears only in privileged runtime code. Spelling is **Leaning** until the
first nosplit function is written.

**The internal model — a per-function property set.** Subset-ness is represented inside the compiler as a
**resolved property set per function** (`{noAlloc, noBarrier, noSafepoint, nosplit}`), *seeded* by module
membership and *refined* by the keyword. Module-default and the keyword are two **inputs** that populate
the same table; the checker and codegen read the resolved set, never the surface. — **Decided.** This is
the design's forward hedge: adding per-function sources later (explicit per-function keywords, or an
attribute grammar) is a new input to the same resolution, so the coarse module-default surface relaxes
into a finer per-function one as a front-end addition, without touching the checker or codegen (see §7).

## 4. Checking

Two layers, both reading the resolved property set (§3):

- **Static call-graph closure (primary).** An IR pass over the resolved call graph: a function carrying a
  property may call only functions that also carry it (or an allowlisted leaf, §5). A violation — subset
  code reaching a callee that allocates, barriers, or polls — is a compile error naming the offending
  call. Runs post-Sema on the call graph, where callees are resolved. Conservative: a call whose target
  the pass cannot prove subset-legal is rejected.
- **Codegen-site guards (backstop).** At each of the four emission points, codegen consults the enclosing
  function's property set. A `noSafepoint` / suppressed poll is *elided*; an implicit `rt_alloc` or
  `__nomu_write_barrier` that the closure check somehow admitted is a hard error at the emission point.
  The two layers agree; the guard is the belt to the closure check's suspenders.

Diagnostics surface as ordinary Sema-level errors (the property set is known before codegen).

## 5. The escape hatch — the allowlist

Subset code does real work by calling primitives that are subset-legal by construction. The allowlist:

- **The 125 raw-memory surface** (`unsafe-memory.md`). `RawPtr` / `Ptr<T>` ops are gc-leaf, touch no
  managed heap, and emit no barrier or poll (their alloc/free go to `rt_raw_alloc` / `rt_raw_free`, off
  the managed heap). They pass the subset check with no special case — the interlock that makes the
  allocator (150 rung 1) written in 125 primitives legal, and the reason 125 lands first.
- **Named runtime intrinsics** — `park` / `unpark`, the raw alloc entry, and GC-internal helpers blessed
  as subset leaves. These are the privileged calls `c-types.md` §6 reserves for the language/runtime
  tier, reached only from runtime code.

A subset function reaching outside this allowlist to an ordinary allocating/barriering callee is the
error §4 reports.

## 6. Relationship to the runtime tasks

- **125 (unsafe raw memory).** Complementary: 125 supplies the primitives, 149 constrains the code around
  them. The two meet at 125 §3.3 (interior-of-moving-heap raw pointers): a `noSafepoint` region is the
  no-collection guarantee that makes an interior raw pointer valid for its extent. So this task's third
  constraint is also 125's deferred gate.
- **150 (GC ladder), rung 1 NoGC.** The first client written under these rules — the bump allocator,
  built from 125 primitives, checked to stay in the subset. 149 need not fully precede 150's first rung
  (the NoGC allocator over off-heap memory leans on it lightly), but it is in place before any code that
  could recursively invoke a service it implements. Ordering: `horizon.md`.

## 7. Held back / deferred

- **Per-function attributes (Go's granular model).** `@nogc` / `@nosplit` / `@nowritebarrier` per
  function. Deferred in favor of A's module-default; revisit only if runtime code proves to need many
  per-function *exceptions* within one module (functions that legitimately allocate). Because the
  internal model is a per-function property set (§3), attributes would be a new front-end source over the
  unchanged core, and would stay confined to privileged code. — **Deferred.**
- **Capability / context parameter.** Thread a runtime-capability value gating the primitives via the
  type system. No declaration syntax, but viral plumbing through every runtime function, and it cannot
  express nosplit (a codegen property, not a held value). — **Deferred.**
- **nosplit itself.** Depends on the fiber-stack strategy (104); the constraint and its check are
  specified here, but the bounded-stack guarantee stages in with growable stacks. The three module-wide
  constraints do not wait. — **Deferred (staged behind 104).**
- **Escape-analysis pragma (`//go:noescape` analog).** Go's third pragma asserts a callee does not let an
  argument escape. Nomu's escape analysis is a compiler pass (`memory-model.md` §6.1), so an assertion
  form is unmotivated at the floor; note it and move on. — **Open.**

## 8. Open questions

- **Module designation mechanism** — how the runtime tier is marked subset-by-default before the module
  system exists (`modules.md` is a stub): a designated file set, a compiler input, or an interim in-source
  module marker. Settles with the module system.
- **nosplit keyword spelling** — `nosplit` vs. another word, pinned against the first nosplit function.
- **Granularity of module exceptions** — whether the runtime tier is uniformly subset or wants a
  per-function opt-*out* from day one (the one real driver toward the deferred finer surfaces, §7).
- **Checker placement precision** — how much of the closure check runs on NOIR vs. SSAIR, and how it
  interacts with monomorphization for the rare generic runtime function.
