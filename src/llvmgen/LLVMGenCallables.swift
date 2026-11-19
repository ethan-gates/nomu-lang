import sema
import mangle
import noir
import ast
import support
import Foundation
import LLVM_C

// Callable declaration — computing an LLVM function signature from a NOIR `fun`/handler and caching
// it in `callables` (with the body queued in `pending`). The signature is ABI: the self-by-pointer
// rules, the addrspace of a reference receiver, and the name mangling must match across both egresses,
// so they live here in the shared emitter. Body definition (the tree-walk) stays on each egress —
// `NOIRToLLVM.defineBody` today, its SSAIR analog later.
extension LLVMGen {
    // The home module for mangling a symbol *defined* in this module (tasks 100.4 / 100.5.5). An
    // **origin-keyed** name (`lib@foo<Int>`) is a cross-module generic specialized locally: the producer is
    // in the name, so every consumer that specializes the same instance emits the identical
    // producer-qualified symbol, which the weak-ODR fold collapses (100.5.5); its type arguments still
    // resolve against this module. A prelude/runtime function keeps a bare name (its file is in
    // `weakOriginFiles`, an empty home). The definition and every on-demand declaration of the same function
    // route through here, so they agree.
    func definitionModule(for file: String) -> Mangle.Module {
        weakOriginFiles.contains(file) ? [] : homeModule
    }

    func declareFree(_ name: String) {
        let key = "f:\(name)"
        guard callables[key] == nil, let f = funcMap[name] else { return }
        declareCallable(key: key, llvmName: Mangle.function(name, home: definitionModule(for: f.span.file)),
                        ir: f, selfType: nil, selfByPointer: false)
    }

    // An imported type's methods have no bodies here, so a witness thunk for an imported conformer passes the
    // `requirement` the method satisfies, whose signature conformance checking matched against it, and the method is
    // declared from that. `Self` in the requirement, as the existential of the `any I` witness ABI or as the
    // compiled-once ABI keeps it, is the conformer itself.
    func declareMethod(_ typeName: String, _ method: String, requirement: (params: [Type], ret: Type)? = nil) {
        let key = "m:\(typeName):\(method)"
        guard callables[key] == nil else { return }
        if typeMethods(typeName).first(where: { $0.name == method }) == nil, let requirement,
           ExternalName.isEncoded(typeName) {
            let selfType = Type.named(typeName, namedKind(typeName))
            func concrete(_ t: Type) -> Type {
                if case .existential = t { return selfType }
                return withSelf(t, typeName)
            }
            let params = requirement.params.enumerated().map {
                NOIRParam(label: "_", name: "p\($0.offset)", type: concrete($0.element), span: zeroSpan)
            }
            let mutating = externalMutatingMethods.contains("\(typeName).\(method)")
            let byPointer = classMap[typeName] != nil || mutating
            let f = NOIRFunc(name: method, params: params, returnType: concrete(requirement.ret), body: [],
                             isMutating: mutating, span: zeroSpan)
            // The producer's symbol, declared without a body, as a direct call of an imported method declares it.
            guard let retTy = llvmType(f.returnType, zeroSpan), let st = selfLLVMType(typeName) else { return }
            var paramTys: [LLVMTypeRef] = [byPointer ? (classMap[typeName] != nil ? p1 : LLVMPointerType(st, 0)!) : st]
            for p in params { guard let t = llvmType(p.type, zeroSpan) else { return }; paramTys.append(t) }
            let symbol = Mangle.method(typeName, method, home: homeModule)
            let (fn, fnTy) = LLVMGetNamedFunction(mod, symbol).map { ($0, LLVMGlobalGetValueType($0)!) }
                ?? emitFunction(symbol, ret: retTy, params: paramTys)
            callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: typeName, selfByPointer: byPointer)
            return
        }
        guard let f = typeMethods(typeName).first(where: { $0.name == method }) else {
            fail("8.2.3: unknown method '\(typeName).\(method)'", Span(startOffset: -1, endOffset: -1, map: nil))
            return
        }
        // A class is a reference type: `self` is always the object pointer. A struct/enum passes
        // `self` by pointer only when the method mutates it.
        let byPointer = classMap[typeName] != nil || f.isMutating
        declareCallable(key: key, llvmName: Mangle.method(typeName, method, home: definitionModule(for: f.span.file)),
                        ir: f, selfType: typeName, selfByPointer: byPointer)
    }

    // An actor `on`-handler, declared on demand: `self` is the object pointer (a reference type,
    // like a class), the body mutex-serialized (defineBody brackets it with lock/unlock).
    func declareActorHandler(_ actorName: String, _ handler: String) {
        let key = "m:\(actorName):\(handler)"
        guard callables[key] == nil else { return }
        guard let h = actorMap[actorName]?.handlers.first(where: { $0.name == handler }) else {
            fail("8.2.6: unknown handler '\(actorName).\(handler)'", zeroSpan)
            return
        }
        let f = NOIRFunc(name: h.name, params: h.params, returnType: h.returnType,
                       body: h.body, isMutating: true, span: h.span)
        declareCallable(key: key, llvmName: Mangle.method(actorName, handler, home: definitionModule(for: f.span.file)),
                        ir: f, selfType: actorName, selfByPointer: true)
    }

    func declareCallable(key: String, llvmName: String, ir f: NOIRFunc,
                                 selfType: String?, selfByPointer: Bool) {
        guard let retTy = llvmType(f.returnType, f.span) else { return }
        var paramTys: [LLVMTypeRef] = []
        if let selfType = selfType {
            guard let st = selfLLVMType(selfType) else { return }
            if selfByPointer {
                // A class/actor receiver is the managed object pointer (addrspace 1). A struct/enum
                // mutating receiver is a pointer to the stack-resident value (addrspace 0).
                let isReference = classMap[selfType] != nil || actorMap[selfType] != nil
                paramTys.append(isReference ? p1 : LLVMPointerType(st, 0)!)
            } else {
                paramTys.append(st)
            }
        }
        for p in f.params {
            guard let t = llvmType(p.type, p.span) else { return }
            paramTys.append(t)
        }
        let (fn, fnTy) = emitFunction(llvmName, ret: retTy, params: paramTys,
                                      debug: (f.name, f.span.begin.line, f.span.debugFile))
        if LLVMGen.noInlineFns.contains(f.name) { addNoInline(fn) }
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType,
                                  selfByPointer: selfByPointer)
        pending.append(key)
    }
}
