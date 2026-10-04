import XCTest
import facts
@testable import interface

final class InterfaceRoundTripTests: XCTestCase {
    // The `.nmi` is sectioned (task 164.4.2): the ABI hash is a function of the ABI section alone, so a
    // perf-only change leaves it byte-identical — the §100.4.6 incremental-cache lever.
    func testAbiHashIndependentOfPerf() {
        let abi = ModuleInterface(package: "p", modulePath: [], types: [],
                                  functions: [InterfaceFunc(name: "f", params: [], ret: nil)])
        let f1 = parseNMI(serialize(abi, perf: InterfacePerf()))!
        let f2 = parseNMI(serialize(abi, perf: InterfacePerf(
            escape: ["f": EscapeSummary(params: [.escapes], ret: .fresh)])))!
        XCTAssertEqual(f1.abiHash, f2.abiHash, "a perf-only change leaves the ABI hash fixed")
        XCTAssertNotEqual(f1.perfHash, f2.perfHash, "the perf hash reflects the perf change")
    }

    // The sectioned form round-trips both sections and the version.
    func testSectionedRoundTrip() {
        let abi = ModuleInterface(package: "p", modulePath: [], types: [],
                                  functions: [InterfaceFunc(name: "f", params: [], ret: nil)])
        let perf = InterfacePerf(escape: ["f": EscapeSummary(params: [.noEscape], ret: .escaped)])
        let file = parseNMI(serialize(abi, perf: perf))!
        XCTAssertEqual(file.abi, abi)
        XCTAssertEqual(file.perf, perf)
        XCTAssertEqual(file.version, nmiFormatVersion)
    }
    // serialize → parse is the identity (task 100.4.2). Includes a function-typed parameter, whose
    // rendered type carries `) -> `, to confirm the JSON form has no line-grammar ambiguity.
    func testRoundTrip() {
        let iface = ModuleInterface(
            package: "demo",
            modulePath: ["util", "parse"],
            types: [
                InterfaceType(keyword: "struct", name: "Point", fields: [
                    InterfaceField(name: "x", type: "Int", isMutable: true),
                    InterfaceField(name: "y", type: "Int", isMutable: false),
                ]),
            ],
            functions: [
                InterfaceFunc(name: "apply",
                    params: [InterfaceParam(label: "f", name: "f", type: "(Int) -> Int"),
                             InterfaceParam(label: "to", name: "n", type: "Int")],
                    ret: "Int"),
                InterfaceFunc(name: "greet", params: [], ret: "Int"),
            ])

        let text = serialize(iface)
        let parsed = parseInterface(text)
        XCTAssertEqual(parsed, iface)
    }

    // Serialization is deterministic: the same interface yields identical bytes.
    func testDeterministic() {
        let iface = ModuleInterface(package: "p", modulePath: [], types: [], functions: [
            InterfaceFunc(name: "a", params: [], ret: nil),
        ])
        XCTAssertEqual(serialize(iface), serialize(iface))
    }

    // The full surface (task 100.4.1) round-trips: generic + method-bearing types, enums with labelled
    // payloads, interfaces with method/property requirements, and generic free functions with bounds.
    func testFullSurfaceRoundTrip() {
        let iface = ModuleInterface(
            package: "std",
            modulePath: ["std"],
            types: [
                InterfaceType(keyword: "class", name: "Box",
                    generics: [InterfaceGeneric(name: "T", bounds: ["Eq"], isShared: false)],
                    fields: [InterfaceField(name: "value", type: "T", isMutable: true)],
                    properties: [InterfaceProperty(name: "isEmpty", type: "Bool", isSettable: false)],
                    methods: [InterfaceFunc(name: "get", params: [], ret: "T"),
                              InterfaceFunc(name: "make", generics: [], params: [], ret: "Box<T>", isStatic: true)],
                    conformances: ["Eq"]),
            ],
            enums: [
                InterfaceEnum(name: "Option",
                    generics: [InterfaceGeneric(name: "T", bounds: [], isShared: false)],
                    cases: [InterfaceCase(name: "some", fields: [InterfaceField(name: "value", type: "T", isMutable: false)]),
                            InterfaceCase(name: "none", fields: [])],
                    methods: [InterfaceFunc(name: "isSome", params: [], ret: "Bool")]),
            ],
            interfaces: [
                InterfaceProtocol(name: "Eq", refines: ["Base"],
                    methods: [InterfaceMethodReq(name: "eq",
                        params: [InterfaceParam(label: "other", name: "other", type: "Self")],
                        ret: "Bool", isStatic: false, hasDefault: false)],
                    properties: [InterfaceProperty(name: "id", type: "Int", isSettable: true)]),
            ],
            functions: [
                InterfaceFunc(name: "map",
                    generics: [InterfaceGeneric(name: "U", bounds: ["Eq", "Ord"], isShared: true)],
                    params: [InterfaceParam(label: "x", name: "x", type: "U")], ret: "U"),
            ])

        let parsed = parseInterface(serialize(iface))
        XCTAssertEqual(parsed, iface)
        XCTAssertEqual(serialize(iface), serialize(iface))
    }
}
