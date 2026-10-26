import Foundation
import XCTest
import mangle
import support

// Each family's symbol, and what the system demangler (`c++filt`, LLVM's) shows for it.
final class MangleTests: XCTestCase {
    let app: Mangle.Module = ["acme", "shop", "app"]
    let util: Mangle.Module = ["acme", "shop", "app", "util"]

    private func demangled(_ symbols: [String]) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/c++filt")
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(symbols.joined(separator: "\n").utf8 + [10]))
        input.fileHandleForWriting.closeFile()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.split(separator: "\n").map(String.init)
    }

    private func check(_ cases: [(symbol: String, mangled: String, demangled: String)], line: UInt = #line) throws {
        XCTAssertEqual(cases.map(\.symbol), cases.map(\.mangled), line: line)
        XCTAssertEqual(try demangled(cases.map(\.symbol)), cases.map(\.demangled), line: line)
    }

    func testFunctions() throws {
        try check([
            (Mangle.function("helper", home: util), "_RNvNmNmNmC4acme4shop3app4util6helper", "acme::shop::app::util::helper"),
            (Mangle.function("max<Int>", home: app), "_RINvNmNmC4acme4shop3app3maxxE", "acme::shop::app::max::<i64>"),
            (Mangle.function("acme/shop/lib@max<Node>", home: app),
             "_RINvNmNmC4acme4shop3lib3maxNtNmNmC4acme4shop3app4NodeE",
             "acme::shop::lib::max::<acme::shop::app::Node>"),
            (Mangle.function("clo:3", home: app), "_RNCNmNmC4acme4shop3apps1_0", "acme::shop::app::{closure#3}"),
            (Mangle.function("spawn:0", home: app), "_RNCNmNmC4acme4shop3app5spawn", "acme::shop::app::{closure:spawn#0}"),
        ])
    }

    func testFixedNames() {
        XCTAssertEqual(Mangle.function("main", home: app), "nomu_main")
        XCTAssertEqual(Mangle.function("rtTlabAlloc", home: []), "nomu_fn_rtTlabAlloc")
        XCTAssertEqual(Mangle.method("Sched", "run", home: []), "nomu_m_Sched_run")
    }

    func testMethods() throws {
        try check([
            (Mangle.method("Rect", "area", home: util), "_RNvNtNmNmNmC4acme4shop3app4util4Rect4area",
             "acme::shop::app::util::Rect::area"),
            (Mangle.method("String", "count.get", home: app), "_RNvNvNtNmNmC4acme4shop3app6String5count3get",
             "acme::shop::app::String::count::get"),
            (Mangle.method("Outer.Inner", "go", home: app), "_RNvNtNtNmNmC4acme4shop3app5Outer5Inner2go",
             "acme::shop::app::Outer::Inner::go"),
            (Mangle.method("acme/shop/lib@Box<Int>", "get", home: app), "_RNvINtNmNmC4acme4shop3lib3BoxxE3get",
             "acme::shop::lib::Box::<i64>::get"),
        ])
    }

    func testDescriptors() throws {
        let desc = Mangle.descriptor("desc", named: "Node", home: app)
        try check([
            (desc, "_RINdC4nomu4descNtNmNmC4acme4shop3app4NodeE", "nomu::desc::<acme::shop::app::Node>"),
            (Mangle.pointerMap(of: desc), "_RNdINdC4nomu4descNtNmNmC4acme4shop3app4NodeE6ptrmap",
             "nomu::desc::<acme::shop::app::Node>::ptrmap"),
            (Mangle.descriptor("arraybuf", [.array(.stringBase)], home: app), "_RINdC4nomu8arraybufSeE",
             "nomu::arraybuf::<[str]>"),
            (Mangle.descriptor("mailbox", home: app), "_RNdC4nomu7mailbox", "nomu::mailbox"),
            (Mangle.descriptor("val", [.function(params: [.int], ret: .bool)], home: app), "_RINdC4nomu3valFxEbE",
             "nomu::val::<fn(i64) -> bool>"),
        ])
    }

    // The collisions the old `_`-joined scheme had: a module boundary against an underscore, a module
    // against a type, and two modules' types of one name.
    func testFormerCollisionsDiffer() {
        XCTAssertNotEqual(Mangle.function("helper", home: ["acme", "shop", "app", "util"]),
                          Mangle.function("util_helper", home: ["acme", "shop", "app"]))
        XCTAssertNotEqual(Mangle.function("c", home: ["s", "w", "a_b"]), Mangle.function("c", home: ["s", "w", "a", "b"]))
        XCTAssertNotEqual(Mangle.function("area", home: ["acme", "shop", "app", "util", "Rect"]),
                          Mangle.method("Rect", "area", home: ["acme", "shop", "app", "util"]))
        XCTAssertNotEqual(Mangle.descriptor("desc", named: "Node", home: ["s", "w", "a"]),
                          Mangle.descriptor("desc", named: "Node", home: ["s", "w", "b"]))
        XCTAssertNotEqual(Mangle.function("s/w/lib@max<Node>", home: ["s", "w", "a"]),
                          Mangle.function("s/w/lib@max<Node>", home: ["s", "w", "b"]))
    }
}
