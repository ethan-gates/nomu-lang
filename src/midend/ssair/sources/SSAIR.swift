import ast       // BinOp
import noir      // NOIRInterface / NOIRConformance / NOIRComposite — witness metadata reused unchanged
import support   // Type, Span, NamedKind

// SSAIR — Nomu's low-level, control-flow-explicit, SSA optimizer IR.
// Design: compiler.md §1a. Build plan: m7-spec.md §7.2.
//
// NOIR is structured (a nested tree that keeps `if`/`switch`/`while` as nodes). SSAIR is a CFG of
// basic blocks in SSA form, with **block arguments** (not φ): a merge block declares parameters and
// each incoming edge passes its values on the jump. It is the substrate for the four M7 passes
// (escape analysis, devirtualization, bounds-check elimination, inlining/specialization) and, once
// the NOIR→LLVM path is deleted at the end of 7.2, the single egress to LLVM. Nomu's MIR/SIL analog.
//
// Invariants every pass must hold (m7-spec.md §7.2 / §7.0.5):
//  • **Typed values** — an `SSAValue` carries its post-monomorphization `Type`.
//  • **Spans everywhere** — every instruction and terminator carries a source `Span`; debug info
//    threads through the tier (dropping a span is a bug).
//  • **GC precision** — a managed heap allocation is the explicit `alloc` op and a write barrier is
//    the explicit `writeBarrier` op, so escape analysis (rewriting `alloc`→stack) and barrier
//    elision are ordinary passes. Managed-ness is a per-value property (the pointer's provenance),
//    scoped to `addrspace(1)`; unmanaged pointers flow through as opaque non-roots.

// MARK: - Values

// A typed SSA value handle. `id` is unique within its `SSAFunction`; `type` is the value's
// post-mono `Type` (the "typed values" invariant). Defined by a function parameter, a block
// parameter, or an instruction result. Equality/hashing is by `id` (identity within the function),
// so passes can key side tables on a value.
public struct SSAValue: Hashable {
    public let id: Int
    public let type: Type

    public init(id: Int, type: Type) {
        self.id = id; self.type = type
    }

    public static func == (a: SSAValue, b: SSAValue) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - Instructions

// A straight-line instruction. `result` names the value it defines (its `id`/`type` echo the
// produced `SSAValue`); void ops (`store`, `writeBarrier`, `boundscheck`) leave it `nil`.
public struct SSAInst {
    public let result: SSAValue?   // the value this instruction defines; nil for void ops
    public let kind: SSAInstKind
    public let span: Span

    public init(result: SSAValue?, kind: SSAInstKind, span: Span) {
        self.result = result; self.kind = kind; self.span = span
    }
}

public indirect enum SSAInstKind {
    // Constants.
    case constInt(Int)
    case constDouble(Double)
    case constBool(Bool)
    case constString(String)

    // Arithmetic / comparison (reuses the AST binary-op enum, as NOIR does).
    case binary(BinOp, SSAValue, SSAValue)

    // Memory + allocation — the EA/GC vocabulary. The result of `alloc` is a managed pointer
    // (`addrspace(1)`); escape analysis rewrites a non-escaping `alloc` to a stack slot (7.3).
    // `writeBarrier` is emitted before a `store` into a possibly-mature managed object; barrier
    // elision (7.3) deletes it where the store cannot create an untracked old→young reference.
    case alloc(Type)                                       // managed GC allocation; the EA site
    case stackAlloc(Type)                                  // a stack slot for a value aggregate (Option B); addrspace(0), never a GC root
    case load(SSAValue)                                    // *addr; result type = the loaded value's type
    case store(addr: SSAValue, value: SSAValue)            // *addr = value
    case writeBarrier(object: SSAValue, value: SSAValue)   // explicit pre-store barrier; elision is a pass
    case fieldAddr(base: SSAValue, fieldIndex: Int)        // GEP to a reference type's field slot
    case elementAddr(base: SSAValue, index: SSAValue)      // array element slot (guard with `boundscheck`)
    case arrayLen(SSAValue)                                // an array handle's length

    // Bounds check — an explicit op (Decided 2026-08-16, m7-spec.md §7.0.4) so BCE (7.5) is a pass
    // that proves it redundant and deletes it. The egress lowers a surviving `boundscheck` to the
    // trap form (compare `index UGE length` → `rt_bounds_trap` → `unreachable`).
    case boundscheck(index: SSAValue, length: SSAValue)

    // Dispatch — the call kind is explicit so devirt rewrites `witness`→`direct` and inlining keys
    // off `direct`.
    case call(SSACall)

    // Concurrency (runtime-coupled composites; the egress owns the mailbox / fiber ABI).
    case mailboxInit(SSAValue)                              // install a fresh mailbox in an actor object's reserved slot
    case actorSend(receiver: SSAValue, handler: String, args: [SSAValue])   // fire-and-forget message send (void)
    // `spawn let` — start `startFn(env)` on a fiber. Like a closure, the captured free variables ride
    // in `env`; `binding` keys the egress-owned fiber handle so `spawnJoin` can await it. Void: the
    // handle is not an SSA value (it is a raw runtime fiber pointer).
    case spawn(binding: Int, startFn: String, env: SSAValue?, resultType: Type)
    case spawnJoin(binding: Int, resultType: Type)         // await a spawned fiber and read its boxed result (idempotent)

    // By-value aggregates (struct / enum). These never heap-allocate, so escape analysis ignores
    // them; a value flows as a first-class SSA aggregate and its members are read by projection.
    // Heap-allocating construction (class / actor / `box` / array buffer) instead emits an explicit
    // `alloc` (above) so its allocation is visible to EA.
    case makeStruct(Type, fields: [SSAValue])
    case makeEnum(Type, caseIndex: Int, fields: [SSAValue])
    case extractField(base: SSAValue, fieldIndex: Int)                   // read a struct field
    case enumTag(SSAValue)                                               // read an enum discriminant
    case extractPayload(base: SSAValue, caseIndex: Int, fieldIndex: Int) // read an enum payload field

    // Existential boxing and array literals — runtime-coupled composites the egress lowers via the
    // existing witness / array-buffer helpers (`box` allocates a witness struct; `arrayLit`
    // allocates a buffer). Array-buffer escape is a 7.3 deferred-tail item.
    // `onStack` (7.3, EA output) stack-allocates a non-escaping box's witness struct; the payload
    // object stays heap (a class payload / a value-type payload boxed by `boxPayload`), stored into the
    // box's `p1` field either way — so no addrspace wall (unlike a closure env). Set only by
    // `StackPromotion`; ssairgen always emits `false`.
    case box(value: SSAValue, interfaces: [String], onStack: Bool)   // wrap a conformer as `any I` / `any A & B`
    case arrayLit(elements: [SSAValue], elem: Type)   // build an `Array<T>` from a literal

    // A closure value: a code pointer plus an explicit environment (closure conversion, 7.2.2, moves
    // the capture set into `env`). `env` is nil for a bare function reference. `onStack` is an EA
    // output (7.3): a non-escaping closure *object* is stack-allocated by the egress (the `env` object
    // itself stays heap this slice — a stack-promoted env hits the `p1` env-param addrspace wall, a
    // scoped follow-up like `spawn:N`). Set only by `StackPromotion`; ssairgen always emits `false`.
    case makeClosure(funcName: String, env: SSAValue?, onStack: Bool)
}

// A call site. `typeArgs` is non-empty only for a residual generic call the mono pass left dynamic.
public struct SSACall {
    public let kind: SSACallKind
    public let args: [SSAValue]
    public let typeArgs: [Type]

    public init(kind: SSACallKind, args: [SSAValue], typeArgs: [Type] = []) {
        self.kind = kind; self.args = args; self.typeArgs = typeArgs
    }
}

public enum SSACallKind {
    case direct(String)                                             // known target (named func / builtin)
    case witness(receiver: SSAValue, interface: String, method: String)   // through a witness slot — the devirt target
    case indirect(SSAValue)                                         // through a closure / function-pointer value
}

// MARK: - Blocks and terminators

// A basic block: block parameters (the join values arriving on incoming edges), a straight-line
// instruction list, and exactly one terminator.
public struct SSABlock {
    public let id: Int
    public var params: [SSAValue]     // block arguments
    public var insts: [SSAInst]
    public var terminator: SSATerm

    public init(id: Int, params: [SSAValue], insts: [SSAInst], terminator: SSATerm) {
        self.id = id; self.params = params; self.insts = insts; self.terminator = terminator
    }
}

// A terminator wrapped with its span (as NOIR nodes carry spans).
public struct SSATerm {
    public let kind: SSATermKind
    public let span: Span

    public init(kind: SSATermKind, span: Span) {
        self.kind = kind; self.span = span
    }
}

public enum SSATermKind {
    case br(target: Int, args: [SSAValue])
    case condBr(cond: SSAValue,
                then: Int, thenArgs: [SSAValue],
                else: Int, elseArgs: [SSAValue])
    // Enum/integer dispatch: `scrutinee` is an integer value (e.g. an `enumTag` result). `cases`
    // maps a discriminant to a target; `defaultTarget` catches the rest (exhaustiveness is already
    // checked upstream, so a well-formed match's default is `unreachable`).
    case switchOn(scrutinee: SSAValue,
                  cases: [SSASwitchCase],
                  defaultTarget: Int, defaultArgs: [SSAValue])
    case ret(SSAValue?)
    case unreachable
}

public struct SSASwitchCase {
    public let value: Int
    public let target: Int
    public let args: [SSAValue]

    public init(value: Int, target: Int, args: [SSAValue]) {
        self.value = value; self.target = target; self.args = args
    }
}

// MARK: - Functions

// A lowered executable body: a free function, a type method, or an actor handler/synthesized init —
// each flattened to a CFG with a concrete post-mono name. `params` are the entry values (including an
// implicit `self` for a method and any residual witness-table parameters). `blocks[0]` is the entry.
public struct SSAFunction {
    public let name: String            // concrete, post-mono (mangled) name
    public let params: [SSAValue]
    public let returnType: Type
    public var blocks: [SSABlock]
    public let isMutating: Bool
    public let span: Span

    public init(name: String, params: [SSAValue], returnType: Type,
                blocks: [SSABlock], isMutating: Bool, span: Span) {
        self.name = name; self.params = params; self.returnType = returnType
        self.blocks = blocks; self.isMutating = isMutating; self.span = span
    }
}

// MARK: - Type layout

// A struct / class / actor storage layout (no method bodies — those become `SSAFunction`s). `kind`
// distinguishes value (struct) from reference (class/actor) semantics, which decides whether a
// construction heap-allocates and whether field access goes through `fieldAddr`/`load` (reference)
// or `extractField` (value).
public struct SSAAggregate {
    public let name: String
    public let kind: NamedKind
    public let fields: [SSAField]
    public let span: Span

    public init(name: String, kind: NamedKind, fields: [SSAField], span: Span) {
        self.name = name; self.kind = kind; self.fields = fields; self.span = span
    }
}

public struct SSAField {
    public let name: String
    public let type: Type
    public let isMutable: Bool

    public init(name: String, type: Type, isMutable: Bool) {
        self.name = name; self.type = type; self.isMutable = isMutable
    }
}

public struct SSAEnum {
    public let name: String
    public let cases: [SSAEnumCase]
    public let span: Span

    public init(name: String, cases: [SSAEnumCase], span: Span) {
        self.name = name; self.cases = cases; self.span = span
    }
}

public struct SSAEnumCase {
    public let name: String
    public let fields: [SSAField]
    public let span: Span

    public init(name: String, fields: [SSAField], span: Span) {
        self.name = name; self.fields = fields; self.span = span
    }
}

// MARK: - Module

// The unit the passes and egress consume. Function bodies are CFGs (`functions`); type-layout and
// witness metadata carry through from NOIR unchanged (the witness structs are reused directly, since
// they hold no executable bodies).
public struct SSAModule {
    public var functions: [SSAFunction]   // `var`: transform passes rewrite bodies in place (M7.3)
    public let aggregates: [SSAAggregate]           // struct / class / actor storage layout
    public let enums: [SSAEnum]                      // enum case layout
    public let interfaces: [NOIRInterface]           // drives witness-table type emission
    public let conformances: [NOIRConformance]       // drives witness-table instance emission
    public let composites: [NOIRComposite]           // composite (`any A & B`) witnesses to emit
    public let opaqueUnderlyings: [String: Type]     // opaque owner → hidden concrete underlying type

    public init(functions: [SSAFunction], aggregates: [SSAAggregate] = [], enums: [SSAEnum] = [],
                interfaces: [NOIRInterface] = [], conformances: [NOIRConformance] = [],
                composites: [NOIRComposite] = [], opaqueUnderlyings: [String: Type] = [:]) {
        self.functions = functions
        self.aggregates = aggregates
        self.enums = enums
        self.interfaces = interfaces
        self.conformances = conformances
        self.composites = composites
        self.opaqueUnderlyings = opaqueUnderlyings
    }
}
