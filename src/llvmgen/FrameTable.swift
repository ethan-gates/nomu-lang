import Foundation

// A module's frame table (task 104, "the runtime's unchecked call chains"): each defined function's frame
// size as LLVM laid it out, whether it checks its stack, its direct callees and whether it calls through a
// pointer, and the functions whose address the module takes. Code generation writes it beside the object
// (`<stem>.frames`), cached with it; the link merges the tables of every object it links and checks that
// each chain of unchecked frames below a checked function fits the stack reserve (`check`).
//
// Text, one entry a line, sorted, so a module's table is the same bytes on every build:
//   nomu-frames 1
//   f <size> <checked 0|1> <function>
//   c <caller> <callee>
//   i <function>            (calls through a pointer)
//   a <function>            (address taken)
//   e <function>            (an entry: its address taken by `Runtime.ofFunc`)
//   r                       (compiled against the runtime prelude)
//   w <body> <need> <wrapper>  (a large frame's body, its frame covered by its wrapper's check for `need`)
public struct FrameTable {
    public var defined: Set<String> = []
    public var checked: Set<String> = []
    public var sizes: [String: Int] = [:]
    public var calls: [String: Set<String>] = [:]
    public var indirect: Set<String> = []
    public var addressTaken: Set<String> = []
    // Functions whose address `Runtime.ofFunc` takes: where a thread, a fiber or a signal handler starts. Their
    // callers are the system, the fiber trampoline and `Runtime.callEntry`'s fiber start, at the base of a
    // stack, never below a checked frame, so an indirect call does not count them.
    public var entries: Set<String> = []
    // Compiled against the runtime prelude (`test.runtime_prelude`): a white-box test whose own checked code
    // calls runtime internals by name, the collector's included, which run off fiber stacks in a program
    // (on the collector's thread, or a carrier's stack) and may recurse. The link does not check a program
    // that links such a module.
    public var runtimePrelude = false
    // The bodies of functions whose frame is larger than the reserve holds (`nomuSplitLargeFrame`): each
    // runs below its wrapper, whose check made room for `need` bytes and the reserve, so the body's frame
    // is covered and its callees have the reserve below it, as a checked function's do.
    public var covered: [String: (need: Int, wrapper: String)] = [:]

    public init() {}

    // The stack reserve G: a checked function's check fails once its SP is within this many bytes of its
    // stack's low end. The runtime's `rtStackReserve` (`runtime/stackmove.nomu`) must be the same.
    public static let stackReserve = 1024
    // The largest frame a checked function may have: the reserve less the room the check's slow path needs
    // below the checking frame (256 bytes; the slow path itself is checked against it, `check`). A larger
    // frame is split behind a wrapper (`nomuSplitLargeFrame`).
    public static let frameLimit = stackReserve - 256

    static let header = "nomu-frames 1"

    // The table's path beside an object: `x.o` → `x.frames`.
    public static func path(forObject object: String) -> String {
        (object.hasSuffix(".o") ? String(object.dropLast(2)) : object) + ".frames"
    }

    public func encoded() -> String {
        var lines = [FrameTable.header]
        for f in defined.sorted() {
            lines.append("f \(sizes[f] ?? 0) \(checked.contains(f) ? 1 : 0) \(f)")
        }
        for caller in calls.keys.sorted() {
            for callee in calls[caller]!.sorted() { lines.append("c \(caller) \(callee)") }
        }
        for f in indirect.sorted() { lines.append("i \(f)") }
        for f in addressTaken.sorted() { lines.append("a \(f)") }
        for f in entries.sorted() { lines.append("e \(f)") }
        if runtimePrelude { lines.append("r") }
        for b in covered.keys.sorted() { lines.append("w \(b) \(covered[b]!.need) \(covered[b]!.wrapper)") }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func decode(_ text: String) -> FrameTable? {
        var t = FrameTable()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.first.map(String.init) == header else { return nil }
        for line in lines.dropFirst() {
            let p = line.split(separator: " ", maxSplits: 3).map(String.init)
            switch p.first {
            case "f" where p.count == 4:
                guard let size = Int(p[1]) else { return nil }
                t.defined.insert(p[3])
                t.sizes[p[3]] = size
                if p[2] == "1" { t.checked.insert(p[3]) }
            case "c" where p.count == 3: t.calls[p[1], default: []].insert(p[2])
            case "i" where p.count == 2: t.indirect.insert(p[1])
            case "a" where p.count == 2: t.addressTaken.insert(p[1])
            case "e" where p.count == 2: t.entries.insert(p[1])
            case "r" where p.count == 1: t.runtimePrelude = true
            case "w":
                let q = line.split(separator: " ").map(String.init)
                guard q.count == 4, let need = Int(q[2]) else { return nil }
                t.covered[q[1]] = (need, q[3])
            default: return nil
            }
        }
        return t
    }

    // Another object's table added to this one. A function defined in several objects (a weak copy) keeps
    // its largest frame.
    public mutating func merge(_ o: FrameTable) {
        defined.formUnion(o.defined)
        checked.formUnion(o.checked)
        for (f, s) in o.sizes { sizes[f] = max(sizes[f] ?? 0, s) }
        for (f, c) in o.calls { calls[f, default: []].formUnion(c) }
        indirect.formUnion(o.indirect)
        addressTaken.formUnion(o.addressTaken)
        entries.formUnion(o.entries)
        runtimePrelude = runtimePrelude || o.runtimePrelude
        for (b, c) in o.covered { covered[b] = c }
    }

    // The `NOMU_FRAME_SIZES` report `tools/frame-depth.py` reads.
    public func report() -> String {
        var out = ""
        for f in defined.sorted() {
            out += "frame-size \(sizes[f] ?? 0) \(checked.contains(f) ? "checked" : "unchecked") \(f)\n"
        }
        for caller in calls.keys.sorted() {
            for callee in calls[caller]!.sorted() { out += "frame-call \(caller) \(callee)\n" }
        }
        return out
    }

    // Functions defined outside Nomu's code that use no fiber stack: the asm floor's context switch and
    // fiber setup, its memory routines (straight-line, or switching to the carrier's stack), and the libc
    // stubs (`nomu_libc_<name>`), which run libc on the carrier's stack.
    static let noStack: Set<String> = [
        "rtSwitch", "rtFiberInit", "memcpy", "memmove", "memset", "bzero", "memcmp",
    ]
    static func usesNoStack(_ f: String) -> Bool { noStack.contains(f) || f.hasPrefix("nomu_libc_") }

    // The slow path a failed check calls (`nomuStackSlow`).
    static let slowPath = "__nomu_stack_slow"

    // The violations of the linked program's frame rules, empty when it holds them. With R the stack
    // reserve and L the largest checked frame (`LLVMGen.stackFrameLimit`):
    // - below a checked function, every chain of unchecked frames uses at most R, a checked callee
    //   counted with its frame and the slow path its check may call;
    // - the slow path uses at most R − L, the room a checked frame leaves it;
    // - unchecked code calls only functions with a known frame (Nomu's, or `noStack`), and no unchecked
    //   function reaches itself, which no bound would cover.
    // An indirect call counts as a call to every function whose address is taken, entries aside.
    public func check(reserve: Int, frameLimit: Int) -> [String] {
        var problems: [String] = []
        var memo: [String: (bytes: Int, chain: [String])] = [:]
        var onPath: [String] = []
        var reported: Set<String> = []
        let targets = addressTaken.filter { defined.contains($0) && !entries.contains($0) }.sorted()

        func callees(_ f: String) -> [String] {
            var out = Array(calls[f] ?? []).sorted()
            if indirect.contains(f) { out += targets }
            return out
        }
        // The deepest stack use from entering unchecked `f`: its frame plus its deepest callee.
        func depth(_ f: String) -> (bytes: Int, chain: [String]) {
            if let m = memo[f] { return m }
            if let at = onPath.firstIndex(of: f) {
                let cycle = (onPath[at...] + [f]).joined(separator: " -> ")
                if reported.insert("cycle " + cycle).inserted {
                    problems.append("unchecked recursion, which no stack bound covers: \(cycle)")
                }
                return (0, [f])
            }
            onPath.append(f)
            defer { onPath.removeLast() }
            var best: (bytes: Int, chain: [String]) = (0, [])
            for c in callees(f) {
                let d = contribution(c, from: f)
                if d.bytes > best.bytes { best = d }
            }
            let r = ((sizes[f] ?? 0) + best.bytes, [f] + best.chain)
            memo[f] = r
            return r
        }
        func contribution(_ c: String, from caller: String) -> (bytes: Int, chain: [String]) {
            if let cover = covered[c], cover.wrapper == caller {
                if (sizes[c] ?? 0) > cover.need, reported.insert("cover " + c).inserted {
                    problems.append("'\(c)' has a \(sizes[c] ?? 0)-byte frame, over the \(cover.need) its wrapper checks for")
                }
                return (0, [c + " (covered)"])
            }
            if checked.contains(c) {
                let slow: (bytes: Int, chain: [String]) = defined.contains(FrameTable.slowPath) ? depth(FrameTable.slowPath) : (0, [])
                return ((sizes[c] ?? 0) + slow.bytes, [c + " (checked)"] + slow.chain)
            }
            if defined.contains(c) { return depth(c) }
            if !FrameTable.usesNoStack(c), reported.insert("unknown " + c).inserted {
                problems.append("'\(caller)' calls '\(c)', whose stack use is not known")
            }
            return (0, [c])
        }

        if defined.contains(FrameTable.slowPath) {
            let slow = depth(FrameTable.slowPath)
            if slow.bytes > reserve - frameLimit {
                problems.append("the stack check's slow path uses \(slow.bytes) bytes, over the \(reserve - frameLimit) "
                                + "a checked frame leaves it: " + slow.chain.joined(separator: " -> "))
            }
        }
        for f in checked.union(covered.keys).sorted() {
            for c in callees(f) where !checked.contains(c) {
                let d = contribution(c, from: f)
                if d.bytes > reserve, reported.insert("deep " + c).inserted {
                    problems.append("\(d.bytes) bytes of unchecked frames below '\(f)', over the \(reserve)-byte "
                                    + "stack reserve: " + d.chain.joined(separator: " -> "))
                }
            }
        }
        return problems
    }
}
