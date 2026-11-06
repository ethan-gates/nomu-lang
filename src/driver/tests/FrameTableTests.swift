import XCTest
import Foundation
import LLVMBridge
@testable import driver

// The link's frame check (task 104, `FrameTable.check`): unchecked chains below a checked function against
// the stack reserve, the slow path against what a checked frame leaves it, unchecked recursion, callees of
// unknown stack use, and indirect calls; and the tables' text form and the link's reading of them.
final class FrameTableTests: XCTestCase {
    // A table from `f <size> <checked> <name>`-style tuples and call edges.
    private func table(_ fs: [(String, Int, Bool)], calls: [(String, String)] = [], indirect: [String] = [],
                       taken: [String] = [], entries: [String] = []) -> FrameTable {
        var t = FrameTable()
        for (name, size, checked) in fs {
            t.defined.insert(name)
            t.sizes[name] = size
            if checked { t.checked.insert(name) }
        }
        for (a, b) in calls { t.calls[a, default: []].insert(b) }
        t.indirect = Set(indirect)
        t.addressTaken = Set(taken)
        t.entries = Set(entries)
        return t
    }

    private func check(_ t: FrameTable) -> [String] { t.check(reserve: 1000, frameLimit: 800) }

    func testChainWithinTheReservePasses() {
        let t = table([("main", 100, true), ("park", 400, false), ("lock", 500, false)],
                      calls: [("main", "park"), ("park", "lock"), ("lock", "nomu_libc_write"), ("lock", "memcpy")])
        XCTAssertEqual(check(t), [])
    }

    func testChainOverTheReserveFails() {
        let t = table([("main", 100, true), ("park", 600, false), ("lock", 500, false)],
                      calls: [("main", "park"), ("park", "lock")])
        let p = check(t)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].contains("1100 bytes") && p[0].contains("park -> lock"), p[0])
    }

    func testCheckedCalleeCountsItsFrameAndTheSlowPath() {
        let t = table([("main", 100, true), ("shim", 200, false), ("user", 700, true),
                       ("__nomu_stack_slow", 150, false)],
                      calls: [("main", "shim"), ("shim", "user")])
        let p = check(t)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].contains("1050 bytes") && p[0].contains("user (checked) -> __nomu_stack_slow"), p[0])
    }

    func testSlowPathOverWhatACheckedFrameLeavesFails() {
        let t = table([("main", 100, true), ("__nomu_stack_slow", 150, false), ("grow", 100, false)],
                      calls: [("__nomu_stack_slow", "grow")])
        let p = check(t)
        XCTAssertEqual(p.count, 1)
        XCTAssertTrue(p[0].contains("slow path uses 250 bytes"), p[0])
    }

    func testUncheckedRecursionBelowACheckedFunctionFails() {
        let t = table([("main", 100, true), ("walk", 50, false)], calls: [("main", "walk"), ("walk", "walk")])
        XCTAssertTrue(check(t).contains { $0.contains("unchecked recursion") && $0.contains("walk -> walk") })
    }

    func testUncheckedRecursionNoCheckedFunctionReachesPasses() {
        let t = table([("main", 100, true), ("collect", 50, false)], calls: [("collect", "collect")])
        XCTAssertEqual(check(t), [])
    }

    func testCalleeOfUnknownStackUseFails() {
        let t = table([("main", 100, true), ("io", 50, false)], calls: [("main", "io"), ("io", "write")])
        XCTAssertTrue(check(t).contains { $0.contains("'io' calls 'write'") })
    }

    func testIndirectCallCountsAddressTakenFunctionsButNotEntries() {
        let base = [("main", 100, true), ("thunk", 300, false), ("deep", 950, false), ("carrier", 5000, false)]
        let reaches = table(base, calls: [("main", "thunk")], indirect: ["thunk"], taken: ["deep", "carrier"],
                            entries: ["carrier"])
        XCTAssertTrue(check(reaches).contains { $0.contains("thunk -> deep") })
        let entryOnly = table(base, calls: [("main", "thunk")], indirect: ["thunk"], taken: ["carrier"],
                              entries: ["carrier"])
        XCTAssertEqual(check(entryOnly), [])
    }

    func testCoveredBodyFitsBelowItsWrapper() {
        var t = table([("main", 100, true), ("wide", 32, true), ("wide.frame", 4000, false), ("leaf", 600, false)],
                      calls: [("main", "wide"), ("wide", "wide.frame"), ("wide.frame", "leaf")])
        t.covered["wide.frame"] = (need: 4096, wrapper: "wide")
        XCTAssertEqual(check(t), [])
        t.sizes["leaf"] = 1100
        XCTAssertTrue(check(t).contains { $0.contains("below 'wide.frame'") && $0.contains("1100 bytes") })
        t.sizes["leaf"] = 600
        t.sizes["wide.frame"] = 5000
        XCTAssertTrue(check(t).contains { $0.contains("over the 4096 its wrapper checks for") })
    }

    func testTextRoundTripsAndMerges() {
        var t = table([("main", 112, true), ("rt", 48, false)], calls: [("main", "rt")], indirect: ["rt"],
                      taken: ["main"], entries: ["rt"])
        t.runtimePrelude = true
        t.covered["rt.frame"] = (need: 2048, wrapper: "rt")
        let back = FrameTable.decode(t.encoded())
        XCTAssertEqual(back?.encoded(), t.encoded())
        var merged = table([("rt", 64, false)])
        merged.merge(back!)
        XCTAssertEqual(merged.sizes["rt"], 64)
        XCTAssertTrue(merged.runtimePrelude)
        XCTAssertNil(FrameTable.decode("not a table\n"))
    }

    func testTheLinkReadsTablesBesideObjectsAndSkipsWhiteBoxPrograms() throws {
        let tmp = (ProcessInfo.processInfo.environment["TEST_TMPDIR"] ?? NSTemporaryDirectory())
            + "/frames-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var deep = table([("main", 100, true), ("walk", 50, false)], calls: [("main", "walk"), ("walk", "walk")])
        try deep.encoded().write(toFile: tmp + "/app.frames", atomically: false, encoding: .utf8)
        XCTAssertFalse(checkFrameTables([tmp + "/app.o"]))
        deep.runtimePrelude = true
        try deep.encoded().write(toFile: tmp + "/app.frames", atomically: false, encoding: .utf8)
        XCTAssertTrue(checkFrameTables([tmp + "/app.o"]))
        XCTAssertFalse(checkFrameTables([tmp + "/missing.o"]))
    }
}
