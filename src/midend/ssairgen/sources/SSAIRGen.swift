import ast
import noir
import ssair
import support

// Lowering-in: structured NOIR → SSAIR (ssair.md).
//
// Direct SSA construction (Braun et al., "Simple and Efficient Construction of Static Single
// Assignment Form"): as the structured tree lowers, the builder tracks the current SSA value of each
// variable per block, materializing block parameters at joins and sealing loop back-edges. Every
// local is an SSA candidate because Nomu has no address-of. Control flow (`if`/`while`/`break`/
// `continue`) flattens to blocks + terminators here — the one place the structured tree is flattened.
//
// Covered so far: scalars + control flow (7.2.2a); value aggregates (struct/enum) under the **slots**
// representation (Decided: Option B — a value aggregate lives in a stack slot, `stackAlloc` +
// `fieldAddr`/`load`/`store`; scalars and reference types stay pure SSA), class construction, field
// access/assignment, enum init + `switch`/match, and array literals (7.2.2b-i). Still ahead:
// type-method/actor-handler bodies + `self`, concrete method calls, closures + closure conversion,
// `box`/witness/indirect dispatch, actors + `actorSend`, and `spawn`.

public struct SSAGenResult {
    public let module: SSAModule
    public let diagnostics: DiagnosticSink
}

public func lowerToSSAIR(_ module: NOIRModule, subsetFuncs: Set<String> = []) -> SSAGenResult {
    let diags = DiagnosticSink()
    var structFields: [String: [NOIRField]] = [:]
    var classFields: [String: [NOIRField]] = [:]
    var enumCases: [String: [NOIREnumCase]] = [:]
    var methodsByType: [String: [NOIRFunc]] = [:]
    var actorFields: [String: [NOIRActorField]] = [:]
    for decl in module.decls {
        switch decl {
        case .structDecl(let s): structFields[s.name] = s.fields; methodsByType[s.name] = s.methods
        case .classDecl(let c):  classFields[c.name] = c.fields;  methodsByType[c.name] = c.methods
        case .enumDecl(let e):   enumCases[e.name] = e.cases;      methodsByType[e.name] = e.methods
        case .actorDecl(let a):  actorFields[a.name] = a.fields
        default: break
        }
    }
    var interfaceSlots: [String: Set<String>] = [:]
    for i in module.interfaces {
        var slots = Set(i.methods.map(\.name))
        for p in i.properties {
            slots.insert("\(p.name).get")
            if p.isSettable { slots.insert("\(p.name).set") }
        }
        interfaceSlots[i.name] = slots
    }
    let ctx = ModuleContext(structFields: structFields, classFields: classFields,
                            enumCases: enumCases, methodsByType: methodsByType, actorFields: actorFields,
                            opaqueUnderlyings: module.opaqueUnderlyings, interfaceSlots: interfaceSlots)

    let sink = ClosureSink()
    var functions: [SSAFunction] = []
    for decl in module.decls {
        switch decl {
        case .funcDecl(let f):
            let lowerer = FunctionLowerer(diags: diags, ctx: ctx, sink: sink, subsetFuncs: subsetFuncs)
            if let fn = lowerer.lower(f) { functions.append(fn) }
        case .structDecl(let s): lowerMethods(s.name, .struct_, s.methods, ctx, diags, sink, subsetFuncs, &functions)
        case .enumDecl(let e):   lowerMethods(e.name, .enum_, e.methods, ctx, diags, sink, subsetFuncs, &functions)
        case .classDecl(let c):  lowerMethods(c.name, .class_, c.methods, ctx, diags, sink, subsetFuncs, &functions)
        case .actorDecl(let a):
            // Each `on`-handler lowers like a mutating method with an actor (reference) `self`.
            let handlers = a.handlers.map { NOIRFunc(name: $0.name, params: $0.params, returnType: $0.returnType,
                                                     body: $0.body, isMutating: true, span: $0.span) }
            lowerMethods(a.name, .actor_, handlers, ctx, diags, sink, subsetFuncs, &functions)
        }
    }
    functions += sink.lifted   // the lifted closure bodies
    var aggregates = module.decls.compactMap { decl -> SSAAggregate? in
        switch decl {
        case .structDecl(let s): return SSAAggregate(name: s.name, kind: .struct_, fields: s.fields.map(field), span: s.span)
        case .classDecl(let c):  return SSAAggregate(name: c.name, kind: .class_, fields: c.fields.map(field), span: c.span)
        case .actorDecl(let a):  return SSAAggregate(name: a.name, kind: .actor_,
                                                     fields: a.fields.map { SSAField(name: $0.name, type: $0.type, isMutable: true) }, span: a.span)
        default: return nil
        }
    }
    aggregates += sink.envAggregates   // synthesized closure-environment layouts
    let enums = module.decls.compactMap { decl -> SSAEnum? in
        guard case .enumDecl(let e) = decl else { return nil }
        return SSAEnum(name: e.name,
                       cases: e.cases.map { SSAEnumCase(name: $0.name, fields: $0.fields.map(field), span: $0.span) },
                       span: e.span)
    }
    let ssa = SSAModule(functions: functions, aggregates: aggregates, enums: enums,
                        interfaces: module.interfaces, conformances: module.conformances,
                        composites: module.composites, opaqueUnderlyings: module.opaqueUnderlyings)
    return SSAGenResult(module: ssa, diagnostics: diags)
}

private func field(_ f: NOIRField) -> SSAField { SSAField(name: f.name, type: f.type, isMutable: f.isMutable) }

private func lowerMethods(_ typeName: String, _ kind: NamedKind, _ methods: [NOIRFunc],
                          _ ctx: ModuleContext, _ diags: DiagnosticSink, _ sink: ClosureSink,
                          _ subsetFuncs: Set<String>, _ out: inout [SSAFunction]) {
    for m in methods {
        let lowerer = FunctionLowerer(diags: diags, ctx: ctx, sink: sink, subsetFuncs: subsetFuncs)
        if let fn = lowerer.lowerMethod(typeName: typeName, kind: kind, m) { out.append(fn) }
    }
}

// MARK: - Per-function lowering + SSA construction
