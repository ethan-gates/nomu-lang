# Modules cleanup — cross-module generics residuals

**Avenue:** Infra · **Type/Lifecycle:** `compiler-hardening` · **Size:** M · **Status:** ready-to-build
(mixed: some edges need-design) · **Source:** spun out of [100](100-modules.md) §100.4.3 — the erased
cross-module generics work landed its core surface (functions, types, fields, methods on struct/enum/class,
static methods, computed properties, read/write) and noted edges as deferred at each sub-phase. This task
is the home for those edges so the remaining module-generics scope has one place with its own phase numbers.

## Scope

Collects the deferred edges of cross-module (erased) generics that have no home outside task 100. Method's
**own** type parameters (`Box<T>.map<U>`) are out of scope — owned end to end by
[170](170-method-level-generics.md). As other task-100 deferrals surface without a dedicated home, they
move here.

Each edge below was noted inline in [100](100-modules.md) where the surrounding work landed; this doc owns
the follow-through. The core erased surface is green (105/105); these are the uncovered corners.

### 171.1 — Requirement dispatch on a bounded field of a generic class

A method on a generic **class** `Ref<T: I>` that dispatches a requirement on a `T`-typed field
(`self.item.val()`) fails LLVM verification today:

```
Call parameter type does not match function signature!
  %aoff = getelementptr i8, ptr addrspace(1) %2, i64 8
  %3 = call i64 %slot(ptr addrspace(1) %aoff)
```

The erased self-field read yields the field's **address inside the object** (`ptr addrspace(1)`, since the
class self is a `p1`), and that `p1` is handed to `witnessDispatchErased`, whose slot ABI expects an addr0
value-buffer self (`i8ptr`).

Reproducer:

```nomu
// dependency
public interface Valued { fun val() -> Int }
public class Ref<T: Valued> {
    var item: T
    fun total() -> Int { return item.val() }
}
// consumer
struct Coin { var n: Int; fun val() -> Int { return n } }
let r = Ref(item: Coin(n: 7))
print(r.total())            // want 7; fails module verification instead
```

A bare addrspacecast to addr0 would satisfy the verifier but is **GC-unsound** when the thunk has a
safepoint — the collector could move the object mid-dispatch, leaving the addr0 copy stale. A correct fix
keeps the requirement self GC-visible: a `p1` slot ABI for a class-held erased receiver, or a typed-root pin
across the dispatch. Distinct from the bounded **function** path (§100.4.3.3.3, where the conformer value is
a managed arg buffer) and from the unbounded generic-class method (§100.4.3.9) — this is a **bound on the
owner type's parameter** exercised through a field requirement.

*Refs:* `witnessDispatchErased` (`src/llvmgen/LLVMGenWitness.swift`); the erased `.witness` call lowering
(`src/llvmgen/SSAIRToLLVM.swift`); `selfFieldRead` (`src/midend/ssairgen/sources/FunctionLowerer.swift`).

### 171.2 — Bounded requirement-dispatch conformer gaps

The conformer kinds still rejected in the erased bounded-dispatch thunks (deferred in §100.4.3.3.3):

- 171.2.1 — **actor conformers.** Same reference ABI as a class, but synchronous erased dispatch on an actor
  is untested — rejected in `bridgeErasedThunkSelf`.
- 171.2.2 — **covariant-`Self` requirements** — rejected in `methodThunkErased`.
- 171.2.3 — **importing a conformer whose method impls live in the producer** — needs producer-exported
  witness tables (the consumer today synthesizes the witness instance from a locally-visible conformance).

*Refs:* `bridgeErasedThunkSelf` / `methodThunkErased` / `witnessInstanceErased` (`LLVMGenWitness.swift`).

### 171.3 — Erased-`T` GC typed-root gaps

Corners of the typed-root GC-trace mechanism (deferred in §100.4.3.6):

- 171.3.1 — **loop-carried / live-out composite.** A composite constructed in a loop whose buffer flows
  through a φ to a later iteration or past the loop is protected only within its construction iteration; the
  back-edge pop unwinds it and it is re-registered only at a construction site, so a collection in a later
  iteration while it is live sees it unregistered. Full coverage wants per-iteration nodes or φ-aware
  lifetime. (No worse than before, and no cycle — a correctness-under-churn gap, not a crash.)
- 171.3.2 — **nested composed enum field.** A nested composed **enum** field (e.g. `Wrap<Opt<T>>`): the
  active case (and so which payload is managed) is a runtime property, so only the top-level `makeEnum`,
  which knows its own case, registers its payload. A nested enum's payload is not walked.
- 171.3.3 — **non-scheduler run config.** No shadow walk runs without `NOMU_SCHED=nomu`; a non-POD erased `T`
  under a non-scheduler GC config has no typed-root coverage.

(The actor / covariant-`Self` half of the bounded non-POD path overlaps 171.2.)

*Refs:* the producer typed-root prologue/epilogue + `registerErasedComponents` (`SSAIRToLLVM.swift`);
`rtShadowPush`/`rtShadowPopTo`/`rtWalkShadow` (runtime).

### 171.4 — Generational write barrier for a non-POD erased field write

The erased-`T` field *write* (§100.4.3.10) emits a VWT-sized memcpy into the field. For a **non-POD** `T`
written into a heap (class) object, the memcpy writes the interior managed pointers but logs **no**
remembered-set entry — the write-barrier/store fuse is suppressed for erased stores, so the generational
logging barrier does not fire. Under a generational young-collection the old object holding the new
young-pointing `T` would be missed. The current test GC configs full-heap-scan, so none is lost under them;
this closes once a non-POD erased field write must survive a minor collection. A correct fix logs the object
(the barrier's object-remembering half) around the memcpy without routing the copy itself through
`storeField` (whose ABI assumes a single `p1` value).

*Refs:* the `.store` erased-memcpy + the fused-barrier suppression in `lowerBlock` (`SSAIRToLLVM.swift`);
`storeField` / `nomuWriteBarrier` (`src/llvmgen/LLVMGenRuntime.swift`).

### 171.5 — Semantic / diagnostic clarifications

Small correctness-of-diagnostics items, not miscompiles:

- 171.5.1 — **`let`-receiver mutating-call diagnostic for a generic instantiation.** The Sema mutation pass
  keys the un-stripped instantiation name (`origin@Box<Int>`), so a mutating method called on a `let`
  receiver of an imported generic type is not rejected (a missing error). The ssairgen self-ABI path already
  strips the suffix (§100.4.3.10); the Sema check wants the same.
- 171.5.2 — **computed-property *requirement* (conformance sense) on imported types.** §100.4.3.5.4 built
  computed-property *members*; a computed property that satisfies an **interface requirement** across the
  boundary is unaddressed.

### 171.6 — Gate erased generic-method emission to public-only

The producer emits the erased (compiled-once) copy of a generic type's methods for **all** generic types,
not just `public` ones (noted in §100.4.3.5.3.1). Only a public generic type's methods can be called across a
module boundary, so a non-public generic type's erased copy is dead weight — emitted and then dead-stripped.
Gating emission to public-only wants type visibility on `NOIRStruct` / `NOIREnum` (the visibility is on the
source decl but not carried to the NOIR type), so the erased-emission predicate can read it. A code-size /
compile-time refinement, not a correctness gap — the extra symbols are `weak_odr` and dead-strip out.

*Refs:* `Monomorphize` (the generic-type-method template + erased-emission gate);
`FunctionLowerer.lowerMethod` (the erased branch); `NOIRStruct` / `NOIREnum` (where a visibility field would
land).

### 171.7 — Erased bodies that call into other generics (surfaced by the specialization dial)

Two cases where a generic body's own compilation fails in the **producer**, under a plain erased build —
independent of `--mono`. The specialization dial ([100](100-modules.md) §100.5.4) can never reach them,
because a module must first compile its erased public generics (for `mono=none` consumers) before any
consumer specializes; specialization cannot exceed what the producer compiles. Both were found building the
§100.5.4 fixtures.

- 171.7.1 — **A public (erased) generic that calls a *private* generic.** The erased copy of the public
  generic emits a call to the private generic, but a private generic is monomorphized-only (never emitted
  erased), so the erased body has no callable target:

  ```
  fun echo<T>(x: T) -> T { return x }                 // private
  public fun relay<T>(x: T) -> T { return echo(x) }   // public → emitted erased
  ```
  → `error: 7.2.3: unknown call target 'echo'` at the producer. Either the private generic is also emitted
  erased when an erased body calls it (promote-to-erased on demand), or the erased body lowers the nested
  generic call through the witness ABI against a private-but-exported erased symbol (the §100.5.1
  "exported, interface-invisible" linkage effect). Until then, make a public erased body calling a private
  generic a clean diagnostic rather than a raw lowering error.

- 171.7.2 — **A generic body that calls a method on a generic-type local.** Constructing a generic type in
  a generic body and calling one of its methods fails SSAIR lowering:

  ```
  public struct Box<T> { let v: T   fun get() -> T { return v } }
  public fun unboxed<T>(x: T) -> T { let b = Box(v: x)   return b.get() }
  ```
  → `error: SSAIR lowering: unsupported method-call receiver` at the producer (`return b.get()`). The
  erased-method path (§100.4.3.5.3) handles a method call on an *imported* generic receiver and on a direct
  parameter, but not on a `Box<T>` value **constructed locally inside** an erased body. Wants the erased
  method-call receiver lowering to cover a locally-materialized generic-type value (buffer-materialize the
  receiver, thread the type-arg VWTs). The specialization path for generic-type *construction + field read*
  (§100.5.4) already works; this is the method-call corner.

*Refs:* `Monomorphize` (private-generic erased-emission gate, 171.7.1); `FunctionLowerer` erased
method-call lowering + the "unsupported method-call receiver" guard (171.7.2); the §100.5.4 probes
(`relay` → private `echo`; `unboxed` → `Box<T>.get`).

## Dependencies & triggers

- **Rides:** the erased witness/VWT machinery and the typed-root GC path (§100.4.3, present).
- **Blocks:** a fully general bounded-generic-class fixture (171.1); a non-POD erased field write surviving a
  minor GC (171.4); the specialization dial reaching a private generic callee or a generic-type method
  (171.7 — these fail in the producer's erased build, [100](100-modules.md) §100.5.4).
- **Interacts with:** [170](170-method-level-generics.md) (method-own type params — the adjacent axis);
  [118 associated types](118-associated-types.md) (covariant-`Self`, 171.2.2).

## Refs

[100](100-modules.md) §100.4.3 (where each edge landed and was deferred); `backend.md` §4 (the erased
witness ABI these edges extend).
