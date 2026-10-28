import Foundation
import store
import LLVMBridge

// Link a binary into `dir`, under its own name (`link.output`'s last component, which its code signature takes as
// its identifier): the entry object, every dependency object, the settings object and the runtime archive. The
// settings object holds `runtimeGlobals`, the values the runtime reads (G14 of the build-configuration design);
// `record`, the configuration's short form, goes in the `__TEXT,__nomu_config` section (G13). Returns the names of
// the outputs within `dir` (the binary, and the dSYM's files under `dsym`), or nil on failure (message on stderr).
// Debug info stays path-independent either way (207.6): under `objects` the debug map names each object relative
// to the workspace root (`-oso_prefix`), and under `dsym` it is gathered into `<binary>.dSYM` and the debug map
// stripped, so the binary names no object.
func linkBinary(_ link: LinkInputs, into dir: String, timings: Timings) -> [String]? {
    let fm = FileManager.default
    // The link's own files go in `.work`, which no binary name can be.
    let work = dir + "/.work"
    guard (try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)) != nil else {
        fputs("error: cannot create '\(work)'\n", stderr)
        return nil
    }
    defer { try? fm.removeItem(atPath: work) }
    let name = link.binaryName
    let binary = dir + "/" + name, dsym = binary + ".dSYM"
    let settingsObject = work + "/settings.o", recordFile = work + "/config.yaml"
    if let error = timings.measure("link", "settings", { emitSettingsObject(link.runtimeGlobals, to: settingsObject) }) {
        fputs("error: settings object: \(error)\n", stderr)
        return nil
    }
    guard fm.createFile(atPath: recordFile, contents: Data(link.record.utf8)) else {
        fputs("error: cannot write '\(recordFile)'\n", stderr)
        return nil
    }
    // `-dead_strip` drops code unreachable from the program's entry, and `-x` strips local symbols.
    var linkArgs = ["-o", binary] + linkFlags + ["-Wl,-oso_prefix," + link.workspaceRoot + "/"]
        + link.objects + [settingsObject, link.runtimeArchive]
    linkArgs.append("-Wl,-sectcreate,__TEXT,__nomu_config,\(recordFile)")
    // The GC frame index (FrameIndex.swift): the link reserves its section and writes a link map; afterwards
    // the index is written into the binary and its signature's page hashes are redone (CodeSignature.swift).
    let reserveFile = work + "/frameidx.bin", mapFile = work + "/link.map"
    do {
        let size = try FrameIndex.reserveSize(objects: link.objects)
        guard fm.createFile(atPath: reserveFile, contents: Data(count: size)) else {
            fputs("error: cannot write '\(reserveFile)'\n", stderr)
            return nil
        }
    } catch {
        fputs("error: frame index: \(error)\n", stderr)
        return nil
    }
    linkArgs += ["-Wl,-sectcreate,\(FrameIndex.segment),\(FrameIndex.section),\(reserveFile)",
                 "-Wl,-map,\(mapFile)"]
    // `ZERO_AR_DATE` records zero for each object's time in the debug map (its `N_OSO` entries), which
    // otherwise reaches the binary's UUID and signature.
    let linkStatus = timings.measure("link", "cc") {
        runProcess("/usr/bin/cc", linkArgs, environment: ["ZERO_AR_DATE": "1"])
    }
    if linkStatus != 0 {
        fputs("error: link failed\n", stderr)
        return nil
    }
    let indexed = timings.measure("link", "frame index") { Result { try FrameIndex.write(binary: binary, linkMap: mapFile) } }
    if case .failure(let error) = indexed {
        fputs("error: frame index: \(error)\n", stderr)
        return nil
    }
    // `dsym`: gather the debug info into a dSYM beside the binary, then strip the debug map, before signing. The
    // debug map names objects relative to the workspace root, so `dsymutil` reads them from there. It runs in
    // `dir` and is given the binary by name, which the dSYM's relocation map records as the binary's path.
    if link.debugInfoStorage == "dsym" {
        let gathered = timings.measure("link", "dsymutil") {
            runProcess("/usr/bin/dsymutil", ["--oso-prepend-path=" + link.workspaceRoot, name, "-o", name + ".dSYM"],
                       in: dir)
        }
        guard gathered == 0 else {
            fputs("error: dsymutil failed for '\(link.output)'\n", stderr)
            return nil
        }
        guard timings.measure("link", "strip", { runProcess("/usr/bin/strip", ["-S", binary]) }) == 0 else {
            fputs("error: strip failed for '\(link.output)'\n", stderr)
            return nil
        }
    }
    let resigned = timings.measure("link", "sign") { Result { try CodeSignature.resign(binary: binary) } }
    switch resigned {
    case .failure(let error):
        fputs("error: signing: \(error)\n", stderr)
        return nil
    case .success(.signed):
        break
    case .success(.unsupported):
        // A signature in a form the driver does not rewrite: sign with `codesign`, under the same identifier.
        let signStatus = timings.measure("link", "codesign") {
            runProcess("/usr/bin/codesign", ["-s", "-", "-f", "-i", name, binary])
        }
        if signStatus != 0 {
            fputs("error: codesign failed for '\(link.output)'\n", stderr)
            return nil
        }
    }
    var names = [name]
    if link.debugInfoStorage == "dsym" {
        let bundle = name + ".dSYM"
        for rel in (fm.enumerator(atPath: dsym)?.allObjects as? [String]) ?? [] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dsym + "/" + rel, isDirectory: &isDir), !isDir.boolValue { names.append(bundle + "/" + rel) }
        }
    }
    return names
}

// Place a link's outputs at the binary's path: the binary, and its dSYM when the link wrote one. A dSYM from an
// earlier build would describe another binary, so any there is removed first. Each file appears complete in one
// step (`ArtifactStore.materialize`), so two builds of one program can share the output path.
func materializeLink(_ result: ActionResult, store: ArtifactStore, output: String) -> Bool {
    Layout.clearDirectory(at: output)
    try? FileManager.default.removeItem(atPath: output + ".dSYM")
    do { try store.materialize(result, into: (output as NSString).deletingLastPathComponent) } catch {
        fputs("error: \(error)\n", stderr)
        return false
    }
    return true
}
