import inference
import ssair
import support

// The order a module's startup globals initialize in (globals design, `tasks/224-globals.md` item 3a):
// proven at compile time, following each initializer into the functions it calls (Go's rule), so every
// read sees the final value and needs no check.
//
// The fact is the set of this module's startup globals a function may read, directly or through its
// callees, solved on the interprocedural fixpoint engine. Edges: direct calls; a witness call to every
// method of that name in the module; a closure call to every closure and function address the module
// creates; a spawn to its routine and an actor send to every handler of that name, since either may run
// before startup ends; and a call into another module that passes a closure, an interface value or residual
// type arguments, to every closure and method in the module. Each initializer's summary names the globals it
// needs first; a depth-first walk over those in declaration order gives the order, and a cycle is an error.

struct GlobalReads: FactSummary {
    let names: Set<String>
    static var bottom: GlobalReads { GlobalReads(names: []) }
    func joined(with other: GlobalReads) -> GlobalReads { GlobalReads(names: names.union(other.names)) }
}

// `globals` in declaration order; returns them with the startup globals reordered into a proven
// initialization order (constant globals keep their places), or nil after reporting a cycle.
func orderStartupGlobals(_ globals: [SSAGlobal], functions: [SSAFunction], diags: DiagnosticSink) -> [SSAGlobal]? {
    let startup = globals.filter { !$0.isConstant }
    guard !startup.isEmpty else { return globals }
    let startupNames = Set(startup.map(\.name))

    let defined = Set(functions.map(\.name))
    var methodsByName: [String: [String]] = [:]
    for f in functions where f.name.hasPrefix("m:") {
        let rest = f.name.dropFirst(2)
        guard let colon = rest.firstIndex(of: ":") else { continue }
        methodsByName[String(rest[rest.index(after: colon)...]), default: []].append(f.name)
    }
    var addressTaken: [String] = []
    for f in functions {
        for blk in f.blocks {
            for inst in blk.insts {
                switch inst.kind {
                case .makeClosure(let name, _, _), .funcAddr(let name): addressTaken.append(name)
                default: break
                }
            }
        }
    }
    let allMethods = methodsByName.keys.sorted().flatMap { methodsByName[$0]! }

    var graph = CallGraph<String>()
    var reads: [String: Set<String>] = [:]
    for f in functions {
        graph.addNode(f.name)
        var own = Set<String>()
        for blk in f.blocks {
            for inst in blk.insts {
                var targets: [String] = []
                switch inst.kind {
                case .globalRead(let name) where startupNames.contains(name):
                    own.insert(name)
                case .call(let call):
                    switch call.kind {
                    case .direct(let callee):
                        targets.append(callee)
                        if !defined.contains(callee),
                           !call.typeArgs.isEmpty || call.args.contains(where: { passesCode($0.type) }) {
                            targets += addressTaken + allMethods
                        }
                    case .witness(_, _, let method): targets += methodsByName[method] ?? []
                    case .indirect: targets += addressTaken
                    }
                case .spawn(_, let startFn, _, _): targets.append(startFn)
                case .actorSend(_, let handler, _): targets += methodsByName[handler] ?? []
                default: break
                }
                for t in targets { graph.addEdge(from: f.name, to: t) }
            }
        }
        reads[f.name] = own
    }

    let solved = FixpointSolver<String, GlobalReads>(graph: graph) { node, lookup in
        var names = reads[node] ?? []
        for callee in graph.callees(of: node) { names.formUnion(lookup(callee).names) }
        return GlobalReads(names: names)
    }.solve()

    let byName = Dictionary(uniqueKeysWithValues: startup.map { ($0.name, $0) })
    let position = Dictionary(uniqueKeysWithValues: startup.enumerated().map { ($1.name, $0) })
    func needs(_ g: SSAGlobal) -> [String] {
        (solved[g.initFunction]?.names ?? []).filter { startupNames.contains($0) }.sorted { position[$0]! < position[$1]! }
    }

    // Depth-first, in declaration order: a global is placed after every global its initializer needs. A
    // global met again while still on the walk's path closes a cycle.
    var placed = Set<String>()
    var path: [String] = []
    var order: [SSAGlobal] = []
    func visit(_ name: String) -> Bool {
        if placed.contains(name) { return true }
        if let start = path.firstIndex(of: name) {
            reportCycle(Array(path[start...]), byName[path[start]]!.span, diags)
            return false
        }
        path.append(name)
        for d in needs(byName[name]!) where !visit(d) { return false }
        path.removeLast()
        placed.insert(name)
        order.append(byName[name]!)
        return true
    }
    for g in startup where !visit(g.name) { return nil }

    var next = order.makeIterator()
    return globals.map { $0.isConstant ? $0 : next.next()! }
}

// Whether a value of this type can carry code into another module: a closure, an interface value, or an
// array of either.
private func passesCode(_ t: Type) -> Bool {
    switch t {
    case .function, .existential, .composition: return true
    case .array(let e): return passesCode(e)
    default: return false
    }
}

private func reportCycle(_ cycle: [String], _ span: Span, _ diags: DiagnosticSink) {
    if cycle.count == 1 {
        diags.error("initialization cycle: global '\(cycle[0])' reads its own value through a call", at: span)
        return
    }
    let steps = cycle.indices.map { "'\(cycle[$0])' reads '\(cycle[($0 + 1) % cycle.count])'" }
    diags.error("initialization cycle: " + steps.dropLast().joined(separator: ", ") + ", and " + steps.last!, at: span)
}
