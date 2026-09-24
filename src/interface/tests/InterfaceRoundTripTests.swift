import XCTest
@testable import interface

final class InterfaceRoundTripTests: XCTestCase {
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
}
