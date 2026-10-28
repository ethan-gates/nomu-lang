import Foundation
import store
import LLVMBridge

// What a link reads (task 214), the inputs of its cache key: the objects in link order, the runtime archive, the
// settings object's values, the configuration record, how debug info is stored, the binary's name, which its
// code signature takes as its identifier, and the identities of the tools and SDK it runs (`Toolchain`). The workspace root is where the binary's debug map names objects from
// (`-oso_prefix`); it stays out of the key, and each object enters it by the path the debug map records.
struct LinkInputs {
    var objects: [String]
    var runtimeArchive: String
    var runtimeGlobals: [(symbol: String, value: RuntimeGlobal)]
    var record: String
    var debugInfoStorage: String
    var output: String
    var workspaceRoot: String
    // Every tool's identity, by name; the key takes those the link runs (`tools`).
    var toolchain: [String: String]

    // An object as the binary's debug map records it: relative to the workspace root, else as it is.
    func recorded(_ object: String) -> String {
        object.hasPrefix(workspaceRoot + "/") ? String(object.dropFirst(workspaceRoot.count + 1)) : object
    }

    var binaryName: String { (output as NSString).lastPathComponent }

    // The tools the link runs: `dsymutil` and `strip` only under `dsym`; `codesign` when the driver cannot rewrite
    // the linker's signature.
    var tools: [String] { ["cc", "ld", "codesign", "sdk"] + (debugInfoStorage == "dsym" ? ["dsymutil", "strip"] : []) }
}

// The link's fixed flags (`linkBinary`); with the steps after the link, the recipe its key names.
let linkFlags = ["-Wl,-dead_strip", "-Wl,-x"]
let linkRecipe = (["cc"] + linkFlags + ["ZERO_AR_DATE=1", "| frame-index", "| dsym: dsymutil, strip -S", "| sign"])
    .joined(separator: " ")

extension JobKeyer {
    // A link's key: the compiler's identity and the target, the recipe, and each input `LinkInputs` names, the
    // objects and the runtime archive by content hash.
    func key(_ link: LinkInputs) -> JobKey {
        var inputs: [String: String] = [
            "compiler": compilerIdentity,
            "target": target.triple,
            "target.cpu": target.cpu,
            "target.features": featuresHash,
            "link.recipe": linkRecipe,
            "link.debug-info-storage": link.debugInfoStorage,
            "binary.name": link.binaryName,
            "objects": link.objects.map(link.recorded).joined(separator: "\n"),
            "runtime-archive": fileHash(link.runtimeArchive),
            "config-record": ContentHash.of(Data(link.record.utf8)),
        ]
        for o in link.objects { inputs["object:" + link.recorded(o)] = fileHash(o) }
        for tool in link.tools { inputs["tool:" + tool] = link.toolchain[tool] ?? "absent" }
        for (symbol, value) in link.runtimeGlobals {
            switch value {
            case .int(let v): inputs["runtime-global:" + symbol] = "int \(v)"
            case .bool(let b): inputs["runtime-global:" + symbol] = "bool \(b)"
            case .string(let s): inputs["runtime-global:" + symbol] = "string \(s)"
            }
        }
        return JobKey(inputs: inputs)
    }
}
