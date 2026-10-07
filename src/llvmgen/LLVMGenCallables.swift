import sema
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
    // The mangling qualifier for a symbol *defined* in this module (tasks 100.4 / 100.5.5). An
    // **origin-keyed** name (`lib@foo<Int>`) is a cross-module generic specialized locally: the producer
    // is already in the name, so it takes **no** consumer home-qualifier — every consumer that specializes
    // the same instance emits the identical producer-qualified symbol, which the weak-ODR fold collapses
    // (100.5.5). A prelude/runtime function keeps a bare name (its file is in `weakOriginFiles`); any other
    // definition carries the module's `homeQualifier`. The definition and every on-demand declaration of
    // the same function route through here, so they agree.
    func definitionQualifier(for name: String, file: String) -> String {
        if ExternalName.isEncoded(name) { return "" }
        return weakOriginFiles.contains(file) ? "" : homeQualifier
    }

    func declareFree(_ name: String) {
        let key = "f:\(name)"
        guard callables[key] == nil, let f = funcMap[name] else { return }
        declareCallable(key: key, llvmName: Mangle.free(name, qualifier: definitionQualifier(for: name, file: f.span.file)),
                        ir: f, selfType: nil, selfByPointer: false)
    }

    func declareMethod(_ typeName: String, _ method: String) {
        let key = "m:\(typeName):\(method)"
        guard callables[key] == nil else { return }
        guard let f = typeMethods(typeName).first(where: { $0.name == method }) else {
            fail("8.2.3: unknown method '\(typeName).\(method)'", Span(startOffset: -1, endOffset: -1, map: nil))
            return
        }
        // A class is a reference type: `self` is always the object pointer. A struct/enum passes
        // `self` by pointer only when the method mutates it.
        let byPointer = classMap[typeName] != nil || f.isMutating
        declareCallable(key: key, llvmName: Mangle.method(typeName, method, qualifier: definitionQualifier(for: typeName, file: f.span.file)),
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
        declareCallable(key: key, llvmName: Mangle.actorHandler(actorName, handler, qualifier: definitionQualifier(for: actorName, file: f.span.file)),
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
                                      debug: (f.name, f.span.begin.line))
        if LLVMGen.noInlineFns.contains(f.name) { addNoInline(fn) }
        callables[key] = Callable(fn: fn, ty: fnTy, ir: f, selfType: selfType,
                                  selfByPointer: selfByPointer)
        pending.append(key)
    }
}
